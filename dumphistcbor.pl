#!/usr/bib/env perl5

my $VERSION = 0.02;

use Modern::Perl;
use utf8;

use Encode ':all';
use Carp;
use Config::Tiny;
use Storable qw(store retrieve freeze thaw dclone);
use Getopt::Long::Descriptive;

use CBOR::XS;

use AnyEvent;
use AnyEvent::Log;
eval "use Time::HiRes qw(time);";

use Telegram;

use Telegram::Messages::GetDialogs;
use Telegram::InputPeer;
use Telegram::Messages::GetHistory;
use Telegram::Users::GetFullUser;
use Telegram::Messages::GetFullChat;
use Telegram::Channels::GetFullChannel;
use Telegram::Channels::GetParticipants;
use Telegram::ChannelParticipantsFilter;

use Data::Dumper;
use Scalar::Util qw(reftype);

sub option_spec {
    [ 'verbose|v!'  => 'be verbose, by default also influences logger'      ],
    [ 'noupdate!'   => 'pass noupdate to Telegram->new', { default => 1 }   ],
    [ 'debug|d:+'   => 'pass debug (2=trace) to Telegram->new & AE::log', {default=>0}],
    [ 'session=s'   => 'name of session data save file', { default => 'session.dat'} ],
    [ 'config|c=s'  => 'name of configuration file', { default => "teleperl.conf" } ],
    [ 'logfile|l=s' => 'path to log file', { default => "$0.log" }          ],
    [ 'file|f=s'    => 'CBOR file name for dump', { required => 1  }        ],
    [ "offset_id=i"     => "same named API param, default 0"  ],
    [ "offset_date=i"   => "same named API param, default 0"  ],
    [ "add_offset=i"    => "same named API param, default 0"  ],
    [ "limit=i"         => "same named API param, default 10" ],
    [ "max_id=i"        => "same named API param, default 0"  ],
    [ "min_id=i"        => "same named API param, default 0"  ],
}

### initialization

my ($opts, $usage);

eval { ($opts, $usage) = describe_options( '%c %o <peer>', option_spec() ) };
die "Invalid opts: $@\nUsage: $usage\n" if $@;

die "user/chat must be specified" unless defined $ARGV[0];

my $session = retrieve( $opts->session ) if -e $opts->session;
my $conf = Config::Tiny->read($opts->config);

$Data::Dumper::Indent = 1;
$AnyEvent::Log::FILTER->level(
    $opts->debug > 1 ? "trace" :
        $opts->debug ? "debug" :
            $opts->verbose ? "info" : "note"
);
$AnyEvent::Log::LOG->log_to_path($opts->logfile) if $opts->{logfile}; # XXX path vs file

# XXX workaround crutch of AE::log not handling utf8 & function name
{
    no strict 'refs';
    no warnings 'redefine';
    *AnyEvent::log    = *AE::log    = sub ($$;@) {
        AnyEvent::Log::_log
          $AnyEvent::Log::CTX{ (caller)[0] } ||= AnyEvent::Log::_pkg_ctx +(caller)[0],
          $_[0],
          map { is_utf8($_) ? encode_utf8 $_ : $_ } (
               (split(/::/, (caller(1))[3]))[-1] . ':' . (caller(0))[2] . ": " . $_[1],
               (@_ > 2 ? @_[2..$#_] : ())
          );
    };
    *AnyEvent::logger = *AE::logger = sub ($;$) {
        AnyEvent::Log::_logger
          $AnyEvent::Log::CTX{ (caller)[0] } ||= AnyEvent::Log::_pkg_ctx +(caller)[0],
          $_[0],
          map { is_utf8($_) ? encode_utf8 $_ : $_ } (
               (split(/::/, (caller(1))[3]))[-1] . ':' . (caller(0))[2] . ": " . $_[1],
               (@_ > 2 ? @_[2..$#_] : ())
          );
    };
}

my $pid = &check_exit();
die "flag exists on start with $pid contents\n" if $pid;

# catch all non-our Perl's warns to log with stack trace
# we can't just Carp::Always or Devel::Confess due to AnyEvent::Log 'warn' :(
$SIG{__WARN__} = sub {
    scalar( grep /AnyEvent|\blog/, map { (caller($_))[0..3] } (1..3) )
        ? warn $_[0]
        : AE::log warn => &Carp::longmess;
};
$SIG{__DIE__} = sub {
    my $mess = &Carp::longmess;
#    $mess =~ s/( at .*?\n)\1/$1/s;    # Suppress duplicate tracebacks
    AE::log alert => $mess;
    die $mess;
};

my $tg = Telegram->new(
    dc => $conf->{dc},
    app => $conf->{app},
    proxy => $conf->{proxy},
    session => $session,
    reconnect => 1,
    keepalive => 1,
    noupdate => $opts->{noupdate},
    debug => $opts->{debug}
);
#$tg->{on_raw_msg} = \&one_message;
$tg->{after_invoke} = \&after_invoke;

my $cbor = CBOR::XS->new->pack_strings(1);
my $cbor_data;
my @clones;

# adapted from Hash::Util to process arrays
sub unlock_hashref_recurse {
    my $hash = shift;

    my $htype = reftype $hash;
    return unless defined $htype;
    if ($htype eq 'ARRAY') {
        foreach my $el (@$hash) {
            unlock_hashref_recurse($el)
                if defined reftype $el;
        }
        return;
    }

    foreach my $value (values %$hash) {
        my $type = reftype($value);
        if (defined($type) and ($type eq 'HASH' or $type eq 'ARRAY')) {
            unlock_hashref_recurse($value);
        }
        Internals::SvREADONLY($value,0);
    }
    Hash::Util::unlock_ref_keys($hash);
    return $hash;
}

sub one_message {
    my $mesg = shift;

    return if ref($mesg) =~ /MTProto::P.ng/ and not $opts->verbose;

    AE::log error => ">1 arg " . Dumper(@_) if @_;

    # XXX workaround of 'use fields' :(
    my $clone = dclone $mesg;
    AE::log trace => "$mesg $clone".Dumper($mesg, $clone);
    unlock_hashref_recurse($clone);

    push @clones, +{ time => time, in => $clone };

    _pack() if @clones > 512; # XXX what's balance b. often vs compress ratio?
};

# NOTE this doesn't make sense here in right this daemon - serves mostly
# an example for real app wishing to log
sub after_invoke {
    my ($req_id, $query, $res_cb) = @_;

    my $cbname = eval {
        require Sub::Util;
        Sub::Util::subname($res_cb);
    };

    # XXX workaround of 'use fields' :(
    my $clone = dclone $query;
    AE::log trace => "$req_id $clone".Dumper($req_id, $clone);
    unlock_hashref_recurse($clone);

    push @clones, +{
        time => time,
        out => $clone,
        req_id => $req_id,
        ($cbname ? (cb => $cbname) : ())
    };
    # don't pack here, request may be still on queue and not sent yet
}

sub _pack {
    return unless @clones;
    $cbor_data .= $cbor->encode(@clones > 1 ? \@clones : $clones[0]);
    @clones = ();
}

sub get_fname {
    return $opts->file;
}

sub save_cbor {
    _pack();
    return unless length $cbor_data > 3;

    my $fname = get_fname();

    $cbor_data = $CBOR::XS::MAGIC . $cbor_data unless -e $fname;

    sysopen my $fh, $fname, AnyEvent::IO::O_CREAT | AnyEvent::IO::O_WRONLY | AnyEvent::IO::O_APPEND, 0666
        or AE::log fatal => "can't open $fname: $!";
    binmode($fh);

    AE::log info => "length cbor=" . length $cbor_data;
    my ($n, $wrlen) = (0, 0);
    while ($wrlen < length $cbor_data) {
        $n = syswrite $fh, $cbor_data; #, $wrlen; # XXX bug with 3 arg on mswin O_o
        $n or AE::log fatal => "can't write $fname: $!";
        $n == length $cbor_data or AE::log fatal => "can't write $fname: short write $n"; 
        AE::log debug => "write returned $n";
        $wrlen += $n;
    }

    close $fh
        or AE::log fatal => "can't close $fname: $!";

    $cbor_data = '';
}

sub save_session {
    AE::log note => "saving session file";
    store( $tg->{session}, $opts->session );
}

sub check_exit {
    my $flag = $opts->{session} . ".exitflg";
    return 0 unless -e $flag;

    my $body = do {
        local $/ = undef;
        open FLG, "<$flag";
        <FLG>
    };
    unlink $flag;

    return ($body || 'empty');
}

$tg->start;

# XXX socks5 crutch!
AnyEvent->_poll until defined $tg->{_mt};

my $cond = AnyEvent->condvar;

# XXX FIXME make first request dummy 'coz error 32 possible :(
$tg->invoke(
    Telegram::Messages::GetDialogs->new(
        offset_date => 0,
        offset_id => 0,
        offset_peer => Telegram::InputPeerEmpty->new,
        limit => -1,
        hash => 0,
    ), sub { "noop" }
);

my $peer = $ARGV[0];

if ($peer eq 'self') {
    $peer = Telegram::InputPeerSelf->new;
}
else {
    $peer = $tg->name_to_id($peer);
    $peer = $tg->peer_from_id($peer);
}
die "unknown user/chat" unless defined $peer;

sub handle_history
{
    my ($peer, $messages, $ptop, $opts) = @_;

    AE::log debug => "ptop=%d %s", $ptop, ($ptop < 2 ? Dumper($messages) : ref $messages);
    my $top = 0;
    $tg->_cache_users(@{$messages->{users}}) ;
    for my $upd (@{$messages->{messages}}) {
        $top = $upd->{id};
        AE::log debug => "top=%d", $top;
        $opts->{limit}-- if $opts->{limit};
#        if ($upd->isa('Telegram::Message')) {
            one_message($upd);
#        }
    }
    $cond->send, return unless $top;    # if bottom reached, slice will be empty
    if ($ptop == 0 or $top < $ptop && ($opts->{limit} // 1)) {
        $tg->invoke( Telegram::Messages::GetHistory->new(
                peer => $peer,
                offset_id => $top,
                offset_date	=> $opts->{offset_date} // 0,
                add_offset	=> $opts->{add_offset} // 0,
                limit	=> $opts->{limit}  || 20,
                max_id	=> $opts->{max_id} || 0,
                min_id	=> $opts->{min_id} || 0,
                hash => 0
            ), sub {
                handle_history($peer, $_[0], $top, $opts) if $_[0]->isa('Telegram::Messages::MessagesABC');
            }
        );
    }
}

sub handle_chanparticipants {
    my ($reply, $offset) = @_;

    one_message($_[0]);

    unless ($reply->isa('Telegram::Channels::ChannelParticipants')) {
        AE::log warn => "not a Telegram::Channels::ChannelParticipants" . Dumper($reply);
        return;
    }
    AE::log debug => "offset=%d count=%d", $offset, $reply->{count};

    $offset += 20;  # XXX hardcode
    return if $offset > $reply->{count};

    $tg->invoke(
        Telegram::Channels::GetParticipants->new(
            channel => $peer,
            filter  => Telegram::ChannelParticipantsRecent->new(),
            offset  => $offset,
            limit   => 0,
            hash    => 0,

        ),
        sub {
            handle_chanparticipants($_[0], $offset);
        }
    );
}

# save info about peer in addition to history
sub mainreqs {
    if ($peer->isa('Telegram::InputPeerUser')) {
        # users.getFullUser
        $tg->invoke(
            Telegram::Users::GetFullUser->new(
                id  => $peer,
            ),
            \&one_message,
        );
    }
    elsif ($peer->isa('Telegram::InputPeerChat')) {
        # messages.getFullChat
        $tg->invoke(
            Telegram::Messages::GetFullChat->new(
                chat_id => $peer->{chat_id},
            ),
            sub {
                # TODO do request Telegram::UserFull for each?
                one_message($_[0]);
            }
        );

    }
    elsif ($peer->isa('Telegram::InputPeerChannel')) {
        # channels.getFullChannel
        $tg->invoke(
            Telegram::Channels::GetFullChannel->new(
                channel => $peer,
            ),
            \&one_message,
        );
        # channels.getParticipants
        $tg->invoke(
            Telegram::Channels::GetParticipants->new(
                channel => $peer,
                filter  => Telegram::ChannelParticipantsRecent->new(),
                offset  => 0,   # XXX ?
                limit   => 0,
                hash    => 0,

            ),
            sub {
                handle_chanparticipants($_[0], 0);
            }
        );
    }

    # then, history itself
    $tg->invoke(
        Telegram::Messages::GetHistory->new(
            peer => $peer,
            offset_id	=> $opts->{offset_id} // 0,
            offset_date	=> $opts->{offset_date} // 0,
            add_offset	=> $opts->{add_offset} // 0,
            limit	=> $opts->{limit} // 20,
            max_id	=> $opts->{max_id} // 0,
            min_id	=> $opts->{min_id} // 0,
            hash => 0
        ), sub {
            handle_history($peer, $_[0], 0, $opts) if $_[0]->isa('Telegram::Messages::MessagesABC');
        }
    );
}

# give a time for possible MTProto sync errors...
my $req = AnyEvent->timer(
    after => 3,
    cb => \&mainreqs,
);

my $save_i = 1;
my $watch = AnyEvent->timer(
    after => 2,
    interval => 1,
    cb => sub {
        save_cbor if $save_i % 60 == 0;
        $cond->send if &check_exit;
        save_session() if $save_i++ % 3600 == 0;
    },
);

my $signal;

$SIG{TERM} = sub {
    AE::log note => "INT recvd";
    $cond->send;
};
# XXX should work in console, not under wperl.exe
if ($^O ne 'MSWin32') {
    $signal = AnyEvent->signal( signal => 'INT', cb => $SIG{TERM}  );
}# else {
    $SIG{INT} = $SIG{TERM};


$cond->recv;
save_cbor() if @clones;

AE::log note => "quittin..";
save_session();
