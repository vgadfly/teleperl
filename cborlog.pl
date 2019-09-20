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

use Telegram::ObjTable; # be independent if someone regens schema while we work
require $_ for map { $_->{file} } values %Telegram::ObjTable::tl_type;

use Data::Dumper;
use Scalar::Util qw(reftype);

sub option_spec {
    [ 'verbose|v!'  => 'be verbose, by default also influences logger'      ],
    [ 'noupdate!'   => 'pass noupdate to Telegram->new'                     ],
    [ 'debug|d:+'   => 'pass debug (2=trace) to Telegram->new & AE::log', {default=>0}],
    [ 'session=s'   => 'name of session data save file', { default => 'session.dat'} ],
    [ 'config|c=s'  => 'name of configuration file', { default => "teleperl.conf" } ],
    [ 'logfile|l=s' => 'path to log file', { default => "cborsave.log" }    ],
    [ 'prefix|p=s'  => 'directory where create files', { default => '.' }   ],
}

### initialization

my ($opts, $usage);

eval { ($opts, $usage) = describe_options( '%c %o ...', option_spec() ) };
die "Invalid opts: $@\nUsage: $usage\n" if $@;

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
AE::log fatal => "flag exists on start with $pid contents\n" if $pid;

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
    save_cbor() unless $mess =~ /CBOR|save_cbor/ms; # don't loose data if it's serv err
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
    debug => $opts->{debug},
    minutonline => 0,
);
$tg->{on_raw_msg} = \&one_message;
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

    _pack() if @clones > 254;   # one byte economy :)
};

# NOTE this doesn't make sense here in right this daemon - serves mostly
# an example for real app wishing to log
sub after_invoke {
    my ($req_id, $query, $res_cb) = @_;

    my $cbname;
    $cbname= eval {
        require Sub::Util;
        Sub::Util::subname($res_cb);
    } if defined $res_cb;

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

# to be redefined in customary versions e.g. specialized dumpers
sub get_fname {
    my $fname = POSIX::strftime("%Y.%m.%d_%H", localtime);
    $fname = "$opts->{prefix}/$fname.cbor";
}

sub save_cbor {
    _pack();
    return unless length $cbor_data > 3;

    my $fname = get_fname();

    $cbor_data = $CBOR::XS::MAGIC
               . $cbor->encode({    # what version decoder should use
                       time => time,
                       schema => $Telegram::ObjTable::GENERATED_FROM,
                   })
               . $cbor_data
        unless -e $fname;

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
    close FLG if $cbor_data;
    unlink $flag
        or AE::log error => "unlink: $!";

    return ($body || 'empty');
}

$tg->start;

# XXX socks5 crutch!
AnyEvent->_poll until defined $tg->{_mt};

# subscribe to updates by any high-level query
$tg->invoke(
    Telegram::Messages::GetDialogs->new(
        offset_date => 0,
        offset_id => 0,
        offset_peer => Telegram::InputPeerEmpty->new,
        limit => -1
    ), \&one_message
);

my $cond = AnyEvent->condvar;

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
if ($^O ne 'MSWin32') {
    $signal = AnyEvent->signal( signal => 'INT', cb => sub {
            AE::log note => "INT recvd";
            $cond->send;
        }
    );
}

AE::log note => "entering main loop";
$cond->recv;
save_cbor() if @clones;

AE::log note => "quittin..";
save_session();
