use Modern::Perl;
use utf8;

package Teleperl;
use base "CLI::Framework";

use Config::Tiny;
use Storable qw( store retrieve freeze thaw );

use AnyEvent::Impl::Perl;
use AnyEvent;

use Text::ParseWords;
use Term::ReadLine;
use Telegram;

use Data::Dumper;

sub init {
    my ($app, $opts) = @_;

    $app->set_current_command('help') if $opts->{help};

    $app->cache->set( 'verbose' => $opts->{verbose} );

    my $session = retrieve( 'session.dat' ) if -e 'session.dat';
    my $conf = Config::Tiny->read("teleperl.conf");
    
    my $tg = Telegram->new(
        dc => $conf->{dc},
        app => $conf->{app},
        proxy => $conf->{proxy},
        session => $session,
        reconnect => 1,
        keepalive => 1,
        noupdate => 0,
        debug => 0
    );
    $tg->{on_update} = sub {
        $app->report_update(@_);
    };
    $tg->start;
    #$tg->update;

    $app->cache->set( 'conf' => $conf );
    $app->cache->set( 'tg' => $tg );

    $app->set_prompt('T> ');
    $app->ornaments('md,me,,');
}

sub read_cmd
{
    my $app = shift;

    my $term = $app->{_readline};
    unless ( $term ) {
        $term = $app->_init_interactive();
        $term->{basic_word_break_characters} =~ s/@//g;
        $term->{completer_word_break_characters} =~ s/@//g;
        $term->event_loop(
                           sub {
                               my $data = shift;
                               $data->[0] = AE::cv();
                               $data->[0]->recv();
                           }, sub {
                               my $fh = shift;
 
                               # The data for AE are: the file event watcher (which
                               # cannot be garbage collected until we're done) and
                               # a placeholder for the condvar we're sharing between
                               # the AE::io callback created here and the wait
                               # callback above.
                               my $data = [];
                               $data->[1] = AE::io($fh, 0, sub { $data->[0]->send() });
                               $data;
                           }
                          );

    }
    $app->pre_prompt();

    # run event loop here
    my $cmd = $term->readline( $app->{_readline_prompt}, $app->{_readline_preput} );
    unless ( defined $cmd ) {
        @ARGV = $app->quit_signals();
        say "quittin..";
        my $tg = $app->cache->get('tg');
        store( $tg->{session}, 'session.dat' );
    }
    else {
        @ARGV = Text::ParseWords::shellwords( $cmd );
        $term->addhistory( $cmd )
            if $cmd =~ /\S/ and (!$term->Features->{autohistory} or !$term->MinLine);
    }
    return 1;
}

sub command_map
{
    message => 'Teleperl::Command::Message',
    debug => 'Teleperl::Command::Debug',
    dialogs => 'Teleperl::Command::Dialogs',
    media => 'Teleperl::Command::Media',
    users => 'Teleperl::Command::Users',
    chats => 'Teleperl::Command::Chats',
    updates => 'Teleperl::Command::Updates',
    history => 'Teleperl::Command::History',
    'read' => 'Teleperl::Command::Read',
    sessions => 'Teleperl::Command::Sessions',
 
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
    msg => 'message'
}

use Telegram::Messages::ForwardMessages;
use Telegram::InputPeer;

sub report_update
{
    my ($self, $upd) = @_;
    my $tg = $self->cache->get('tg');

    if ($upd->isa('MTProto::RpcError')) {
        say "\rRpcError $upd->{error_code}: $upd->{error_message}";
    }
    if ($upd->isa('Telegram::Message')) {
        my $name = defined $upd->{from_id} ? $tg->peer_name($upd->{from_id}) : '';
        my $to = $upd->{to_id};
        my $ip = defined $upd->{from_id} ? $tg->peer_from_id($upd->{from_id}) : undef;
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

        #$tg->invoke(Telegram::Messages::ForwardMessages->new(
        #        id => [ $upd->{id} ],
        #        from_peer => $ip,
        #        to_peer => Telegram::InputPeerSelf->new,
        #        random_id => [ int(rand(65536)) ]
        #)) if defined $ip;

        my @t = localtime;
        print "\r[", join(":", map {"0"x(2-length).$_} reverse @t[0..2]), "] ";
        say "$name$to: $upd->{message}";
        #say Dumper $upd;
    }
    if ($upd->isa('Telegram::UpdateChatUserTyping')) {
        my $user = $tg->peer_name($upd->{user_id});
        my $chat = $tg->peer_name($upd->{chat_id});
        if (defined $user and defined $chat) {
            say "\n$user is typing in $chat...";
        }
    }
}

package Teleperl::Command::Message;
use base "CLI::Framework::Command";

use Encode qw/encode_utf8 decode_utf8/;
use Data::Dumper;

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
    unless (defined $peer) {
        $peer = $idpeer if $idpeer =~ /^\d+$/;
    }

    return "unknown user/chat" unless defined $peer;

    $tg->send_text_message( to => $peer, message => join(' ', @msg) );
}

package Teleperl::Command::Debug;
use base "CLI::Framework::Command";

sub run
{
    my ($self, $opts, $val) = @_;

    my $tg = $self->cache->get('tg');
    $tg->{debug} = $val;

    return "debug is set to $val";
}

package Teleperl::Command::Dialogs;
use base "CLI::Framework::Command";

use Data::Dumper;
use Telegram::Messages::GetDialogs;
use Telegram::InputPeer;

sub handle_dialogs
{
    my ($tg, $count, $ds) = @_;

    if ($ds->isa('Telegram::Messages::DialogsABC')) {
        my %users;
        my %chats;
        my $ipeer;

        for my $u (@{$ds->{users}}) {
            $users{$u->{id}} = $u;
        }
        for my $c (@{$ds->{chats}}) {
            $chats{$c->{id}} = $c;
        }
        for my $d (@{$ds->{dialogs}}) {
            $count++;
            my $peer = $d->{peer};
            if ($peer->isa('Telegram::PeerUser')) {
                my $user_id = $peer->{user_id};
                $peer = $users{$user_id};
                say "$peer->{first_name} ". ($peer->{username} // "");
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
                say "#" , ($peer->{username} // "channel with no name o_O");
            }
            if ($peer->isa('Telegram::PeerChat')){
                my $chat_id = $peer->{chat_id};
                $peer = $chats{$chat_id};
                $ipeer = Telegram::InputPeerChat->new(
                    chat_id => $chat_id,
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
                sub { handle_dialogs($tg, $count, @_) }
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
        sub { handle_dialogs($tg, 0, @_)}
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

    say Dumper $tg->{session}{users};
}

package Teleperl::Command::Chats;
use base "CLI::Framework::Command";

use Data::Dumper;

sub run
{
    my ($self, $opts, $peer, $msg) = @_;
    my $tg = $self->cache->get('tg');

    say Dumper $tg->{session}{chats};
}

package Teleperl::Command::Updates;
use base "CLI::Framework::Command";

use Telegram::Updates::GetState;
use Data::Dumper;

sub run
{
    my ($self, $opts, $peer, $msg) = @_;
    my $tg = $self->cache->get('tg');

    $tg->invoke( Telegram::Updates::GetState->new, sub {
            say Dumper @_;
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
use base "CLI::Framework::Command";

use Telegram::InputPeer;
use Telegram::Messages::GetHistory;
use Data::Dumper;

sub complete_arg
{
    my ($self, $lastopt, $argnum, $text, $attribs) = @_;

    my $tg = $self->cache->get('tg');

    if ($argnum == 1) {
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
    my ($self, $peer, $messages, $ptop) = @_;
    my $tg = $self->cache->get('tg');
    
    my $top = 0;
    $tg->_cache_users(@{$messages->{users}}) ;
    for my $upd (@{$messages->{messages}}) {
        $top = $upd->{id};
        if ($upd->isa('Telegram::Message')) {
            my $name = defined $upd->{from_id} ? $tg->peer_name($upd->{from_id}) : '';
            my $to = $upd->{to_id};
            my $ip = defined $upd->{from_id} ? $tg->peer_from_id($upd->{from_id}) : undef;
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

            my @t = localtime;
            print "\r[", join(":", map {"0"x(2-length).$_} reverse @t[0..2]), "] ";
            say "$name$to: $upd->{message}";
            #say Dumper $upd;
        }
    }
    if ($ptop == 0 or $top < $ptop) {
        $tg->invoke( Telegram::Messages::GetHistory->new(
                peer => $peer,
                offset_id => $top,
                offset_date => 0,
                add_offset => 0,
                limit => 10,
                max_id => 0,
                min_id => 0,
                hash => 0
            ), sub {
                $self->handle_history($peer, $_[0], $top) if $_[0]->isa('Telegram::Messages::MessagesABC');
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
            offset_id => 0,
            offset_date => 0,
            add_offset => 0,
            limit => 10,
            max_id => 0,
            min_id => 0,
            hash => 0
        ), sub {
            $self->handle_history($peer, $_[0], 0) if $_[0]->isa('Telegram::Messages::MessagesABC');

        } );
}

package Teleperl::Command::Read;
use base "CLI::Framework::Command";

use Telegram::Messages::ReadHistory;
use Telegram::Channels::ReadHistory;
use Data::Dumper;

sub complete_arg
{
    my ($self, $lastopt, $argnum, $text, $attribs) = @_;

    my $tg = $self->cache->get('tg');

    if ($argnum == 1) {
        return ($tg->cached_nicknames());
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
    my ($self, $opts, $peer, @msg) = @_;

    my $tg = $self->cache->get('tg');

    $peer = $tg->name_to_id($peer);
    $peer = $tg->peer_from_id($peer);

    return "unknown user/chat" unless defined $peer;

    if ($peer->isa('Telegram::InputPeerChannel')) {
        $tg->invoke( Telegram::Channels::ReadHistory->new(
                channel => $peer,
                max_id => 0,
        ), sub {say Dumper @_} );
    }
    else {
        $tg->invoke( Telegram::Messages::ReadHistory->new(
                peer => $peer,
                max_id => 0,
        ), sub {say Dumper @_} );
    }
}

package Teleperl::Command::Sessions;
use base "CLI::Framework::Command";

use Telegram::Account::GetAuthorizations;
use Data::Dumper;

sub run
{
    my $self = shift;

    my $tg = $self->cache->get('tg');

    $tg->invoke( Telegram::Account::GetAuthorizations->new, sub {say Dumper @_} );
}

1;

