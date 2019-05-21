use Modern::Perl;
use utf8;

package Teleperl;
use base "CLI::Framework";

use Carp;
use Config::Tiny;
use Storable qw( store retrieve freeze thaw );
use Encode ':all';

use AnyEvent::Impl::Perl;
use AnyEvent;
use AnyEvent::Log;

use Telegram;

use Data::Dumper;

sub settable_opts {
    [ 'verbose|v!'  => 'be verbose, by default also influences logger'      ],
    [ 'debug|d:+'   => 'pass debug (2=trace) to Telegram->new & AE::log'    ],
    [ 'session=s'   => 'name of session data save file', { default => 'session.dat'} ],
}

sub option_spec {
    &settable_opts(),
    [ 'encoding=s'  => 'if your console is not in UTF-8'    ],
    [ 'noupdate!'   => 'pass noupdate to Telegram->new'     ],
    [ 'config|c=s'  => 'name of configuration file', { default => "teleperl.conf" } ],
}

sub init {
    my ($app, $opts) = @_;

    $app->set_current_command('help') if $opts->{help};

    $app->cache->set( 'verbose' => $opts->{verbose} );
    $app->cache->set( 'session' => $opts->{session} );
    $app->cache->set( 'debug'   => $opts->{debug} );

    # XXX do validate
    $app->cache->set('encoding' => Encode::find_encoding($opts->{encoding}))
        if $opts->{encoding};

    my $session = retrieve( $opts->session ) if -e $opts->session;
    my $conf = Config::Tiny->read($opts->config);
    
    $Data::Dumper::Indent = 1;
    $AnyEvent::Log::FILTER->level(
        $opts->{debug} ? ($opts->{debug}>1 ? "trace" : "debug") :
            $opts->{verbose} ? "info" : "note");
    $AnyEvent::Log::LOG->fmt_cb(sub {
        my ($time, $ctx, $lvl, $msg) = @_;

        my $ts = POSIX::strftime("%H:%M:%S", localtime $time)
               . sprintf ".%04d", 1e4 * ($time - int($time));

        # XXX we need just timestamp! but AE has no cb for just time..
        # XXX so copypaste rest from AnyEvent::Log
        my $ct = " ";
        my @res;

        for (split /\n/, sprintf "%-5s %s: %s", $AnyEvent::Log::LEVEL2STR[$_[2]], $_[1][0], $_[3]) {
            push @res, "$ts$ct$_\n";
            $ct = " + ";
        }

        join "", @res

    });

    # we can't just Carp::Always or Devel::Confess due to AnyEvent::Log 'warn' :(
    $SIG{__WARN__} = sub {
        scalar( grep /AnyEvent|log/, map { (caller($_))[0..3] } (1..4) )
            ? warn $_[0]
            : AE::log warn => &Carp::longmess;
    };
    # XXX workaround crutch of AE::log not handling utf8 & function name
    {
        no strict 'refs';
        no warnings 'redefine';
        *AnyEvent::log    = *AE::log    = sub ($$;@) {
            AnyEvent::Log::_log
              $AnyEvent::Log::CTX{ (caller)[0] } ||= AnyEvent::Log::_pkg_ctx +(caller)[0],
              $_[0],
              map { is_utf8($_) ? encode_utf8 $_ : $_ } (
                  ($opts->verbose
                      ? (split(/::/, (caller(1))[3]))[-1] . ':' . (caller(0))[2] . ": " . $_[1]
                      : $_[1]),
                   (@_ > 2 ? @_[2..$#_] : ())
              );
        };
        *AnyEvent::logger = *AE::logger = sub ($;$) {
            AnyEvent::Log::_logger
              $AnyEvent::Log::CTX{ (caller)[0] } ||= AnyEvent::Log::_pkg_ctx +(caller)[0],
              $_[0],
              map { is_utf8($_) ? encode_utf8 $_ : $_ } (
                  ($opts->verbose
                      ? (split(/::/, (caller(1))[3]))[-1] . ':' . (caller(0))[2] . ": " . $_[1]
                      : $_[1]),
                   (@_ > 2 ? @_[2..$#_] : ())
              );
        };
    }

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
    $tg->{on_update} = sub {
        $app->report_update(@_);
    };
    $tg->start;
    #$tg->update;

    $app->cache->set( 'conf' => $conf );
    $app->cache->set( 'tg' => $tg );
    $app->cache->set( 'argobject' => [] );

    $app->set_prompt('T> ');
    $app->ornaments('md,me,,');
    $app->event_loop(40);
    $app->with_readline_vars(sub {
        my %params = @_;

        $params{Attribs}->{basic_word_break_characters} =~ s/@//g;
        $params{Attribs}->{completer_word_break_characters} =~ s/@//g;
    });
}

sub command_map
{
    argobject   => 'Teleperl::Command::Argobject',
    chats       => 'Teleperl::Command::Chats',
    dialogs     => 'Teleperl::Command::Dialogs',
    history     => 'Teleperl::Command::History',
    invoke      => 'Teleperl::Command::Invoke',
    media       => 'Teleperl::Command::Media',
    message     => 'Teleperl::Command::Message',
    'read'      => 'Teleperl::Command::Read',
    sessions    => 'Teleperl::Command::Sessions',
    set         => 'Teleperl::Command::Set',
    updates     => 'Teleperl::Command::Updates',
    users       => 'Teleperl::Command::Users',
 
    # built-in commands:
    help    => 'CLI::Framework::Command::Help',
    list    => 'CLI::Framework::Command::List',
    tree    => 'CLI::Framework::Command::Tree',
    'dump'  => 'CLI::Framework::Command::Dump',
    console => 'CLI::Framework::Command::Console',
    alias   => 'CLI::Framework::Command::Alias',
}

sub command_alias
{
    m => 'message',
    msg => 'message',
    new => 'argobject',
    obj => 'argobject',
}

sub _format_time {
    my $ts = shift;

    # TODO take from app options/config
    return POSIX::strftime(
        (AE::now - $ts < 86400) ? "%H:%M:%S" : "%Y.%m.%d %H:%M",
        localtime $ts);
}

sub render {
    my ($app, $output) = @_;

    if (my $enc = $app->cache->get('encoding')) {
        # FIXME correctness checks & flags
        if (utf8::valid($output)) {
            utf8::decode($output);
            utf8::upgrade($output);
        }
        $output = $enc->encode($output, Encode::FB_PERLQQ);
    }

    $app->SUPER::render($output);
}

# XXX Template::Toolkit / Term::ANSIColor ?

sub render_msg {
    my $self = shift;
    #@type Telegram::Message
    my $msg = shift;

    my $tg = $self->cache->get('tg');
    my $v = $self->cache->get('verbose');

    my $name = defined $msg->{from_id} ? $tg->peer_name($msg->{from_id}, 1) : '(noid)';
    my $to = $msg->{to_id};
    my $ip = defined $msg->{from_id} ? $tg->peer_from_id($msg->{from_id}) : undef;
    if ($to) {
        if ($to->isa('Telegram::PeerChannel')) {
            $to = $to->{channel_id};
        }
        if ($to->isa('Telegram::PeerChat')) {
            $to = $to->{chat_id};
        }
        $ip = $tg->peer_from_id($to);
        $to = $tg->peer_name($to);
    }
    $to = $to ? " in $to" : '';

    # like telegram-cli/interface.c TODO more fields & maybe colors
    my $add = "";

    if ($msg->{fwd_from}) {
        $add .= "[fwd from ";
        my $fwh = $msg->{fwd_from};
        if ($fwh->isa('Telegram::MessageFwdHeader')) {
            $add .= $tg->peer_name($fwh->{from_id}, 1) if $fwh->{from_id};
            $add .= " in " . $tg->peer_name($fwh->{channel_id}, 1) if $fwh->{channel_id};
            if ($v) {
                $add .= " @ " . _format_time($fwh->{date});
                for (qw(channel_post post_author saved_from_msg_id)) {
                    $add .= "$_=" . $fwh->{$_} if $fwh->{$_};
                }
                # TODO saved_from_peer
            }
        }

        $add .= "] ";
    }
    $add .= "[reply to " . $msg->{reply_to_msg_id} . "] "           if $msg->{reply_to_msg_id};
    $add .= "[mention] "                                            if $msg->{mentioned};
    $add .= "[via " . $tg->peer_name($msg->{via_bot_id}, 1) . "] "  if $msg->{via_bot_id};
    $add .= "[edited " . _format_time($msg->{edit_date}) . "] "     if $msg->{edit_date};
    $add .= "[media] "                                              if $msg->{media};
    $add .= "[reply_markup] "                                       if $msg->{reply_markup};

    my @t = localtime;
    $self->render("\r[rcvd " . join(":", map {"0"x(2-length).$_} reverse @t[0..2]) . "] "
        . ($v ? "id=$msg->{id} ":"")
        . _format_time($msg->{date}) . " "
        . "$name$to: $add$msg->{message}\n"
    );
}

use Telegram::Messages::ForwardMessages;
use Telegram::InputPeer;

sub report_update
{
    my ($self, $upd) = @_;
    my $tg = $self->cache->get('tg');

    if ($upd->isa('MTProto::RpcError')) {
        $self->render("\rRpcError $upd->{error_code}: $upd->{error_message}");
    }
    if ($upd->isa('Telegram::Message')) {
        $self->render_msg($upd);

        #$tg->invoke(Telegram::Messages::ForwardMessages->new(
        #        id => [ $upd->{id} ],
        #        from_peer => $ip,
        #        to_peer => Telegram::InputPeerSelf->new,
        #        random_id => [ int(rand(65536)) ]
        #)) if defined $ip;
        #say Dumper $upd;
    }
    if ($upd->isa('Telegram::UpdateChatUserTyping')) {
        my $user = $tg->peer_name($upd->{user_id});
        my $chat = $tg->peer_name($upd->{chat_id});
        if (defined $user and defined $chat) {
            $self->render("\n$user is typing in $chat...");
        }
    }
}

package Teleperl::Command::Message;
use base "CLI::Framework::Command";

use Telegram::MessageEntity;
use Encode qw/encode_utf8 decode_utf8/;
use Data::Dumper;

# do long scan once
my $entpkgs = Class::Inspector->subclasses('Telegram::MessageEntityABC');
my @_opts;
for (grep(!/input/i, @$entpkgs)) {
    my $e = $_;
    no strict 'refs';
    my @keys = sort keys %{"$e\::FIELDS"};
    $e =~ s/Telegram::MessageEntity//;
    $e = lc $e;
    push @_opts, [ "entity-$e=s\@{".(scalar @keys).'}' => "required args @keys" ],
}

# XXX allow repeated like  '=s@{3}' here
sub getopt_conf { qw(no_bundling) }

sub option_spec {
    [ "no_webpage!"      => "same named API param, default false"  ],
    [ "silent!"          => "same named API param, default false"  ],
    [ "background!"      => "same named API param, default false"  ],
    [ "clear_draft!"     => "same named API param, default false"  ],
    [ "reply_to_msg_id=i"=> "same named API param, default none"   ],
    @_opts,
}

sub complete_arg
{
    my ($self, $lastopt, $argnum, $text, $attribs) = @_;

    my $tg = $self->cache->get('tg');

    if ($argnum == 1) {
        return ($tg->cached_nicknames(), $tg->cached_usernames());
    }

    return undef;
}

sub validate
{
    my ($self, $opts, @args) = @_;
    die "user/chat must be specified" unless defined $args[0];
    die "message text required" unless defined $args[1];
}

sub run
{
    my ($self, $opts, $idpeer, @msg) = @_;

    my $tg = $self->cache->get('tg');

    my $peer = $tg->name_to_id($idpeer);

    return "unknown user/chat" unless defined $peer;

    my @ents;
    for my $entkey (grep /^entit/, keys %$opts) {
        my @vals = @{ $opts->{$entkey} };
        $entkey =~ s/^entity.//;
        my $class = (grep { lc $_ eq lc "Telegram::MessageEntity$entkey" } @$entpkgs )[0];
        no strict 'refs';
        my @keys = sort keys %{"$class\::FIELDS"};

        die "invalid arg count" if scalar(@vals) % scalar(@keys) != 0;
        while (my @ent = splice @vals, 0, scalar(@keys)) {
            push @ents, $class->new(
                    map {
                        (shift @keys) => (shift @ent)
                    } (0 .. $#keys)
                );
        }
    }

    $tg->send_text_message(
        to => $peer,
        message => join(' ', @msg),
        (map {
            (defined $opts->{$_} ? ($_ => $opts->{$_}) : ())
        } qw(no_webpage silent background clear_draft reply_to_msg_id)),
        (@ents ? (entities => [@ents]) : ()),
    );
}

package Teleperl::Command::Set;
use base "CLI::Framework::Command::Meta";

*option_spec = \&Teleperl::settable_opts;

sub run
{
    my ($self, $opts, $val) = @_;

    my $ret = "";
    my $app = $self->get_app;
    my $tg = $self->cache->get('tg');

    if (exists $opts->{debug}) {
        $tg->{debug} = $opts->debug;
        $app->cache->set( 'debug'   => $opts->{debug} );
        $ret .= "debug is set to $opts->{debug}\n";
    }

    if (exists $opts->{verbose}) {
        $app->cache->set( 'verbose' => $opts->{verbose} );
        $ret .= "verbose is set to $opts->{verbose}\n";
    }

    if ($opts->{session} ne $app->cache->get('session')) {
        $app->cache->set( 'session' => $opts->{session} );
        $ret .= "session is set to $opts->{session}\n";
    }

    return $ret || "no opts changed";
}

package Teleperl::Command::Dialogs;
use base "CLI::Framework::Command::Meta";

use Data::Dumper;
use Telegram::Messages::GetDialogs;
use Telegram::InputPeer;

sub handle_dialogs
{
    my ($tg, $count, $say, $ds) = @_;

    my $out = sub {
        if ($count) {
            $say->(sprintf "%4d %-4s %-10d %6d %-23s %s", $count, @_);
        } else {
            $say->(sprintf "\ndlg# Type Id         Unread \@username               Display Name");
        }
    };

    if ($ds->isa('Telegram::Messages::DialogsABC')) {
        my %users;
        my %chats;
        my $ipeer;

        $tg->_cache_users(@{$ds->{users}});
        $tg->_cache_chats(@{$ds->{chats}});
        for my $u (@{$ds->{users}}) {
            $users{$u->{id}} = $u;
        }
        for my $c (@{$ds->{chats}}) {
            $chats{$c->{id}} = $c;
        }
        $out->() if $count == 0 && scalar @{$ds->{dialogs}};
        for my $d (@{$ds->{dialogs}}) {
            $count++;
            my $peer = $d->{peer};
            if ($peer->isa('Telegram::PeerUser')) {
                my $user_id = $peer->{user_id};
                $peer = $users{$user_id};
                $out->(
                    $peer->{bot} ? "bot" : "user",
                    $user_id,
                    $d->{unread_count},
                    $peer->{username} // "",
                    ($peer->{first_name}//"")." ".($peer->{last_name} // "")
                );
                $ipeer = Telegram::InputPeerUser->new(
                    user_id => $user_id,
                    access_hash => $peer->{access_hash}
                );
            }
            if ($peer->isa('Telegram::PeerChannel')) {
                my $chan_id = $peer->{channel_id};
                $peer = $chats{$chan_id};
                $ipeer = Telegram::InputPeerChannel->new(
                    channel_id => $chan_id,
                    access_hash => $peer->{access_hash}
                );
                $out->(
                    ($peer->{megagroup} ? 'sgrp' : '#') .
                    (ref $peer =~ /Forbidden/ ? 'ban' : ''),
                    $chan_id,
                    $d->{unread_count},
                    ($peer->{username} // "#chan with no name o_O"),
                    $peer->{title} // "",
                );
            }
            if ($peer->isa('Telegram::PeerChat')){
                my $chat_id = $peer->{chat_id};
                $peer = $chats{$chat_id};
                $ipeer = Telegram::InputPeerChat->new(
                    chat_id => $chat_id,
                );
                $out->(
                    ref $peer =~ /Forbidden/
                        ? 'frbd'
                        : 'chat',
                    $chat_id, $d->{unread_count}, "", $peer->{title} // ""
                );
            }
        }
        if ($ds->isa('Telegram::Messages::DialogsSlice')) {
            $tg->invoke(
                Telegram::Messages::GetDialogs->new(
                    offset_id => $ds->{messages}[-1]{id},
                    offset_date => $ds->{messages}[-1]{date},
                    offset_peer => Telegram::InputPeerEmpty->new,
                    #    offset_peer => $ipeer,
                    limit => -1
                ),
                sub { handle_dialogs($tg, $count, $say, @_) }
            ) if ($count < $ds->{count});
        }
    }
}

sub run
{
    my ($self, $opts, $offset, $limit) = @_;
    my $tg = $self->cache->get('tg');

    $tg->invoke(
        Telegram::Messages::GetDialogs->new(
            offset_id => $offset // 0,
            offset_date => 0,
            offset_peer => Telegram::InputPeerEmpty->new,
            limit => $limit // -1
        ),
        sub {
            handle_dialogs(
                $tg,
                0,
                sub { $self->get_app->render(join($,//"", @_) . "\n") },
                @_)
        }
    );
}

package Teleperl::Command::Media;
use base "CLI::Framework::Command";

use Telegram::Messages::SendMedia;
use Telegram::InputMedia;

sub run
{
    my ($self, $opts, $peer, $msg) = @_;
    my $tg = $self->cache->get('tg');

    $tg->invoke(
        Telegram::Messages::SendMedia->new(
            peer => $tg->peer($peer),
            media => Telegram::InputMediaDocumentExternal->new(
                url => $msg,
                caption => $msg
            ),
            random_id => int(rand(65536))
        )
    );
}

package Teleperl::Command::Users;
use base "CLI::Framework::Command";

use Data::Dumper;

sub run
{
    my ($self, $opts, $peer, $msg) = @_;
    my $tg = $self->cache->get('tg');

    return Dumper $tg->{session}{users};
}

package Teleperl::Command::Chats;
use base "CLI::Framework::Command";

use Data::Dumper;

sub run
{
    my ($self, $opts, $peer, $msg) = @_;
    my $tg = $self->cache->get('tg');

    return Dumper $tg->{session}{chats};
}

package Teleperl::Command::Updates;
use base "CLI::Framework::Command::Meta";

use Telegram::Updates::GetState;
use Data::Dumper;

sub run
{
    my ($self, $opts, $peer, $msg) = @_;
    my $tg = $self->cache->get('tg');

    $tg->invoke( Telegram::Updates::GetState->new, sub {
            $self->get_app->render(Dumper @_);
            $tg->{session}{update_state}{date} = $_[0]->{date};
            $tg->{session}{update_state}{pts} = $_[0]->{pts};
            $tg->{session}{update_state}{seq} = $_[0]->{seq};
        });
    
    #$tg->invoke( Telegram::Updates::GetDifference->new(
    #        date => $tg->{session}{update_state}{date},
    #        pts => $tg->{session}{update_state}{pts},
    #        qts => -1,
    #    ), sub {say Dumper @_});
}

package Teleperl::Command::History;
use base "CLI::Framework::Command::Meta";

use Telegram::InputPeer;
use Telegram::Messages::GetHistory;
use Data::Dumper;

sub option_spec {
    [ "offset_id=i"     => "same named API param, default 0"  ],
    [ "offset_date=i"   => "same named API param, default 0"  ],
    [ "add_offset=i"    => "same named API param, default 0"  ],
    [ "limit=i"         => "same named API param, default 10" ],
    [ "max_id=i"        => "same named API param, default 0"  ],
    [ "min_id=i"        => "same named API param, default 0"  ],
}

sub complete_arg
{
    my ($self, $lastopt, $argnum, $text, $attribs) = @_;

    my $tg = $self->cache->get('tg');

    if ($argnum == 1 && $text !~ /^-/) {
        return ($tg->cached_nicknames());
    }

    return undef;
}

sub validate
{
    my ($self, $opts, @args) = @_;
    die "user/chat must be specified" unless defined $args[0];
}

sub handle_history
{
    my ($self, $peer, $messages, $ptop, $opts) = @_;
    my $tg = $self->cache->get('tg');

    my $top = 0;
    $tg->_cache_users(@{$messages->{users}}) ;
    for my $upd (@{$messages->{messages}}) {
        $top = $upd->{id};
        $opts->{limit}-- if $opts->{limit};
        if ($upd->isa('Telegram::Message')) {
            $self->get_app->render_msg($upd);
            #say Dumper $upd;
        }
    }
    if ($ptop == 0 or $top < $ptop && $opts->{limit}) {
        $tg->invoke( Telegram::Messages::GetHistory->new(
                peer => $peer,
                offset_id => $top,
            offset_date	=> $opts->{offset_date} // 0,
            add_offset	=> $opts->{add_offset} // 0,
            limit	=> $opts->{limit} // 10,
            max_id	=> $opts->{max_id} // 0,
            min_id	=> $opts->{min_id} // 0,
                hash => 0
            ), sub {
                $self->handle_history($peer, $_[0], $top, $opts) if $_[0]->isa('Telegram::Messages::MessagesABC');
            } );
    }
}

sub run
{
    my ($self, $opts, $peer, @msg) = @_;

    my $tg = $self->cache->get('tg');

    if ($peer eq 'self') {
        $peer = Telegram::InputPeerSelf->new;
    }
    else {
        $peer = $tg->name_to_id($peer);
        $peer = $tg->peer_from_id($peer);
    }
    return "unknown user/chat" unless defined $peer;

    $tg->invoke( Telegram::Messages::GetHistory->new(
            peer => $peer,
            offset_id	=> $opts->{offset_id} // 0,
            offset_date	=> $opts->{offset_date} // 0,
            add_offset	=> $opts->{add_offset} // 0,
            limit	=> $opts->{limit} // 10,
            max_id	=> $opts->{max_id} // 0,
            min_id	=> $opts->{min_id} // 0,
            hash => 0
        ), sub {
            $self->handle_history($peer, $_[0], $opts) if $_[0]->isa('Telegram::Messages::MessagesABC');

        } );
}

package Teleperl::Command::Read;
use base "CLI::Framework::Command::Meta";

use Telegram::Messages::ReadHistory;
use Telegram::Channels::ReadHistory;
use Data::Dumper;

sub usage_text {
    q{
    read <peer> [<max_id>]: Mark dialog with <peer> as read, all
                            messages by default, or up to <max_id> in history
    }
}

sub complete_arg
{
    my ($self, $lastopt, $argnum, $text, $attribs) = @_;

    my $tg = $self->cache->get('tg');

    if ($argnum == 1) {
        return ($tg->cached_nicknames(), $tg->cached_usernames);
    }

    return undef;
}

sub validate
{
    my ($self, $opts, @args) = @_;
    die "user/chat must be specified" unless defined $args[0];
}

sub run
{
    my ($self, $opts, $peer, $max) = @_;

    my $tg = $self->cache->get('tg');

    $peer = $tg->name_to_id($peer);
    $peer = $tg->peer_from_id($peer);

    return "unknown user/chat" unless defined $peer;

    if ($peer->isa('Telegram::InputPeerChannel')) {
        $tg->invoke( Telegram::Channels::ReadHistory->new(
                channel => $peer,
                max_id => $max // 0,
        ), sub { $self->get_app->render(Dumper @_) } );
    }
    else {
        $tg->invoke( Telegram::Messages::ReadHistory->new(
                peer => $peer,
                max_id => $max // 0,
        ), sub { $self->get_app->render(Dumper @_) } );
    }
}

package Teleperl::Command::Sessions;
use base "CLI::Framework::Command::Meta";

use Telegram::Account::GetAuthorizations;
use Data::Dumper;

sub run
{
    my $self = shift;

    my $tg = $self->cache->get('tg');

    $tg->invoke( Telegram::Account::GetAuthorizations->new, sub { $self->get_app->render(Dumper @_) } );
}

package Teleperl::Command::Invoke;
use base "CLI::Framework::Command::Meta";

use Telegram::ObjTable;
use Data::Dumper;

our @cnames = map { $_->{class} } values %Telegram::ObjTable::tl_type;
our @fnames = map { $_->{func} } grep { exists $_->{func} and not exists $_->{bang} } values %Telegram::ObjTable::tl_type;
our $class = undef;

sub _func2class {
    for (values %Telegram::ObjTable::tl_type) {
        return $_->{class} if exists $_->{func} and $_->{func} eq $_[0];
    }
    return undef;
}

sub usage_text {
    q{
    invoke --class <name> [<options>]: do raw InvokeWithLayer with this query
    invoke --func <fname> [<options>]:    and then Data::Dumper response

    ARGUMENTS
        <name>          name of Telegram::* class to call ->new() upon
        <fname>         function from schema/docs - will guess --class
        $<number>       substitute instantiated slot from 'argobject' command

    OPTIONS
        Long form, corresponding to field name, e.g. '--date' if class
        has field 'date' - these will be arguments to new().

    *BUG*! You may need to erase and try opt again for autocomplete to work,
        and option may be non-recognized until completion tried.
    }
}

sub option_spec {
    my @opts = ([ "class=s", "which to instantiate" ],
                [ "func=s", "schema function/method to get class from" ]);
    if ($class) {
        require Class::Inspector->filename($class);
        no strict 'refs';
        push @opts, [ "$_=s", "" ] for keys %{"$class\::FIELDS"};
    }
    return @opts;
}

sub complete_arg
{
    my ($self, $lastopt, $argnum, $text, $attribs, $rawARGV) = @_;
#print "|$text,$lastopt,$argnum#".join(':',@args)."%".join('^',@$rawARGV)."|\n";
    # the trick is: we must change $class on the fly so option_spec()
    # will return class fields as options and they will be completed
    # by CLIF - not us! - on *next* iteration.
    if ($argnum == 1) {
        if ($lastopt =~ /^--class$/) {
            $class = $text if scalar grep { $_ eq $text } @cnames;
            return @cnames;
        } elsif ($lastopt =~ /^--func$/) {
            $class = _func2class($text) if scalar grep { $_ eq $text } @fnames;
            return @fnames;
        }
    }

    my @args = @$rawARGV;
    if (@args > 1) {
        for my $i (0..$#args-1) {
            if ($args[$i] eq '--class' and scalar grep { $_ eq $args[$i+1] } @cnames) {
                $class = $args[$i+1];
                last;
            }
            if ($args[$i] eq '--func' and scalar grep { $_ eq $args[$i+1] } @fnames) {
                $class = _func2class($args[$i+1]);
                last;
            }
        }
    }

    if ($text =~ /^\$/) {
        my $arr = $self->cache->get('argobject');
        my @slots;
        for (my $i = 0; $i < $#$arr; $i++) {
            push @slots, '$'.$i if defined $arr->[$i];
        }
        return @slots;
    }

    return undef;
}

sub validate
{
    my ($self, $opts, @args) = @_;
    die "Telegram::* subclass or schema.funcMethodName must be specified"
        unless defined $opts->{class} or defined $opts->{func};

    my $arr = $self->cache->get('argobject');
    for (@args) {
        if (/^\$[0-9]+$/) {
            die "slot $_ is unset" if not defined $arr->[substr $_, 1];
        }
    }
}

sub run
{
    my ($self, $opts) = @_;

    my $tg = $self->cache->get('tg');
    my $argo = $self->cache->get('argobject');

    my $obj = $class->new(
        map {
            my $v = $opts->{$_};
            $v = $argo->[substr $v, 1] if $v =~ /^\$[0-9]+$/;
            ($_ => $v);
        } grep {
            $_ ne 'class' &&
            $_ ne 'func' &&
            $_ ne 'flags'   # XXX what if in future scheme it will be renamed?
        } keys %$opts
    );
    $class = undef;
    my $retid;
    $retid = $tg->invoke($obj, sub {
            local $Data::Dumper::Varname = $retid . "#";
            $self->get_app->render(Dumper @_) 
        }
    );
}

package Teleperl::Command::Argobject;
use base "CLI::Framework::Command::Meta";

sub usage_text {
    q{
    argobject [<opt>] push --class <name> [<options>]
    argobject [<opt>] push [<list of builtin bare types>]
    argobject [<opt>] dump
    argobject [<opt>] delete <indexes>
    argobject [<opt>] pop
    argobject [<opt>] shift
    argobject [<opt>] inputpeer <self|empty|@username|@chatname|numericalid>

    OPTIONS
        --on-slot=N     do operation on sub-array in slot N instead of global

    ARGUMENTS (subcommands)
        push            add new slot w/class or bare types to end of (sub)array
        dump            print current (sub)array with Data::Dumper style 3
        delete          arguments are indexes of elements to delete
        pop             delete last element and dump it to screen
        shift           delete first element, dump it to screen and shift others
        inputPeer       as 'push' but for InputPeer only with proper completion

    ARGUMENTS in subcommands
        <cname>         name of Telegram::* class to call ->new() upon
        <indexes>       numbers - indexes of slots in (sub)array

    SUBCOMMAND OPTIONS
        Long form, corresponding to field name, e.g. '--date' if class
        has field 'date' - these will be arguments to new().

    *BUG*! You may need to erase and try opt again for autocomplete to work,
        and option may be non-recognized until completion tried.
    }
}

sub option_spec {
    [ "on-slot=i"       => "operate on slot N instead of whole array"  ],
}

sub subcommand_alias {
    'append'    => 'push',
    'add'       => 'push',
    'unset'     => 'delete',
}

sub notify_of_subcommand_dispatch {
    my ($self, $subcommand, $cmd_opts, @args) = @_;

    my $argobj = $self->cache->get('argobject');
    if (my $i = $cmd_opts->{"on_slot"}) {
        die "Invalid slot $i" unless $i < $#$argobj+2; # XXX really need this?

        $argobj->[$i] = [] unless ref $argobj->[$i] eq 'ARRAY';

        $argobj = $argobj->[$i];
    }

    $self->cache->set('_argobjarr' => $argobj);
}

package Teleperl::Command::Argobject::Push;
use base "Teleperl::Command::Argobject";

use Telegram::ObjTable;
use Data::Dumper;

our @cnames = map { $_->{class} } values %Telegram::ObjTable::tl_type;
our $class = undef;

sub option_spec {
    my @opts = ([ "class=s", "which to instantiate" ]);
    if ($class) {
        require Class::Inspector->filename($class);
        no strict 'refs';
        push @opts, [ "$_=s", "" ] for keys %{"$class\::FIELDS"};
    }
    return @opts;
}

sub complete_arg
{
    my ($self, $lastopt, $argnum, $text, $attribs, $rawARGV) = @_;
#print "|$text,$lastopt,$argnum#".join(':',@args)."%".join('^',@$rawARGV)."|\n";
    # the trick is: we must change $class on the fly so option_spec()
    # will return class fields as options and they will be completed
    # by CLIF - not us! - on *next* iteration.
    if ($argnum == 1) {
        if ($lastopt =~ /^--class$/) {
            $class = $text if scalar grep { $_ eq $text } @cnames;
            return @cnames;
        }
    }

    my @args = @$rawARGV;
    if (@args > 1) {
        for my $i (0..$#args-1) {
            if ($args[$i] eq '--class' and scalar grep { $_ eq $args[$i+1] } @cnames) {
                $class = $args[$i+1];
                last;
            }
        }
    }

    if ($text =~ /^\$/) {
        my $arr = $self->cache->get('argobject');   # XXX or _argobjarr ?
        my @slots;
        for (my $i = 0; $i < $#$arr; $i++) {
            push @slots, '$'.$i if defined $arr->[$i];
        }
        return @slots;
    }

    return undef;
}

sub validate
{
    my ($self, $opts, @args) = @_;
    die "Telegram::* subclass or bare args must be specified"
        unless defined $opts->{class} or @args;
}

sub run
{
    my ($self, $opts, @args) = @_;

    my $argo = $self->cache->get('_argobjarr');

    if ($opts->{class}) {
        my $obj = $class->new(
            map {
                my $v = $opts->{$_};
                $v = $argo->[substr $v, 1] if $v =~ /^\$[0-9]+$/;
                ($_ => $v);
            } grep {
                $_ ne 'class' &&
                $_ ne 'flags'   # XXX what if in future scheme it will be renamed?
            } keys %$opts
        );
        $class = undef;
        push @$argo, $obj;
    }
    elsif (@args) {
        push @$argo, $_ for @args;
    }
    # XXX check else?
    return $#$argo;
}

package Teleperl::Command::Argobject::InputPeer;
use base "Teleperl::Command::Argobject";

use Telegram::InputPeer;

sub complete_arg
{
    my ($self, $lastopt, $argnum, $text, $attribs) = @_;

    my $tg = $self->cache->get('tg');

    if ($argnum == 1) {
        return ('self', 'empty', $tg->cached_nicknames(), $tg->cached_usernames());
    }

    return undef;
}

sub validate
{
    my ($self, $opts, @args) = @_;
    die "Exactly one argument describing peer must be given"
        unless @args == 1;

    die "Invalid peer specification"
        unless $args[0] =~ /^(self|empty|@.+|-?[0-9]+)$/i;
}

sub run
{
    my ($self, $opts, $peer) = @_;

    my $tg = $self->cache->get('tg');
    my $argo = $self->cache->get('_argobjarr');

    if ($peer eq 'self') {
        $peer = Telegram::InputPeerSelf->new;
    }
    elsif ($peer eq 'empty') {
        $peer = Telegram::InputPeerEmpty->new;
    }
    else {
        $peer = $tg->name_to_id($peer);
        $peer = $tg->peer_from_id($peer);
    }
    die "unknown user/chat" unless defined $peer;

    push @$argo, $peer;
    return $#$argo;
}

package Teleperl::Command::Argobject::Delete;
use base "Teleperl::Command::Argobject";

sub validate
{
    my ($self, $opts, @args) = @_;

    die "Indexes must be given as arguments" unless @args;
    for (@args) {
        die "$_ is not an integer" unless /^[0-9]+$/;
    }
}

sub run {
    my ($self, $opts, @args) = @_;

    my $argo = $self->cache->get('_argobjarr');

    my $ret = "";
    for (@args) {
        if (defined $argo->[$_]) {
            $argo->[$_] = undef;
            $ret .= "$_ ";
        }
    }

    return "Deleted $ret";
}

package Teleperl::Command::Argobject::Dump;
use base "Teleperl::Command::Argobject";

use Data::Dumper;

sub run {
    my $self = shift;

    local $Data::Dumper::Indent = 3;
    return Dumper $self->cache->get('_argobjarr');
}

package Teleperl::Command::Argobject::Pop;
use base "Teleperl::Command::Argobject";

use Data::Dumper;

sub run {
    my $self = shift;

    my $argo = $self->cache->get('_argobjarr');
    local $Data::Dumper::Indent = 1;
    return Dumper(pop @$argo);
}

package Teleperl::Command::Argobject::Shift;
use base "Teleperl::Command::Argobject";

use Data::Dumper;

sub run {
    my $self = shift;

    my $argo = $self->cache->get('_argobjarr');
    local $Data::Dumper::Indent = 1;
    return Dumper(shift @$argo);
}

1;
