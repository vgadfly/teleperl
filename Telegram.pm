package Telegram;

=head1 SYNOPSYS

  Telegram API client

=cut

use Modern::Perl;
use Data::Dumper;

use IO::Socket;
use Net::SOCKS;

use AnyEvent;

# This module should use MTProto for communication with telegram DCs

use MTProto;


## Telegram API

# Layer and Connection
use Telegram::InvokeWithLayer;
use Telegram::InitConnection;

# Auth
use Telegram::Auth::SendCode;
use Telegram::Auth::SentCode;
use Telegram::Auth::SignIn;

# Updates
use Telegram::Updates::GetState;

# Messages
use Telegram::Message;
use Telegram::Messages::GetMessages;
use Telegram::Messages::SendMessage;

# input
use Telegram::InputPeer;

use fields qw( _mt _dc _code_cb _app _proxy _timer reconnect session _first _code_hash on_update debug );

# args: DC, proxy and stuff
sub new
{
    my ($class, %arg) = @_;
    my $self = fields::new( ref $class || $class );
    
    $self->{_dc} = $arg{dc};
    $self->{_proxy} = $arg{proxy};
    $self->{_app} = $arg{app};
    $self->{_code_cb} = $arg{on_auth};
    $self->{on_update} = $arg{on_update};
    $self->{reconnect} = $arg{reconnect};
    $self->{debug} = $arg{debug};
    
    my $session = $arg{session};
    $session->{mtproto} = {} unless exists $session->{mtproto};
    $self->{session} = $session;
    $self->{_first} = 1;

    $self->{_timer} = AnyEvent->timer( after => 60, interval => 60, cb => $self->_get_timer_cb );

    return $self;
}

# connect, start session
sub start
{
    my $self = shift;

    my $sock;
    if (defined $self->{_proxy}) {
        my $proxy = new Net::SOCKS( 
            socks_addr => $self->{_proxy}{addr},
            socks_port => $self->{_proxy}{port}, 
            user_id => $self->{_proxy}{user},
            user_password => $self->{_proxy}{pass}, 
            protocol_version => 5,
        );

        # XXX: don't die
        $sock = $proxy->connect( 
            peer_addr => $self->{_dc}{addr}, 
            peer_port => $self->{_dc}{port} 
        ) or die;
    }
    else {
        $sock = IO::Socket::INET->new(
            PeerAddr => $self->{_dc}{addr}, 
            PeerPort => $self->{_dc}{port},
            Proto => 'tcp'
        ) or die;
    }
    
    $self->{_mt} = MTProto->new( socket => $sock, session => $self->{session}{mtproto},
            on_error => $self->_get_err_cb, on_message => $self->_get_msg_cb,
            debug => $self->{debug}
    );

}

## layer wrapper

sub invoke
{
    my ($self, $query) = @_;

    if ($self->{_first}) {
        
        # Wrapper conn
        my $conn = Telegram::InitConnection->new( 
                api_id => $self->{_app}{api_id},
                device_model => 'IBM PC/AT',
                system_version => 'DOS 6.22',
                app_version => '0.01',
                lang_code => 'en',
                query => $query
        );

        $self->{_mt}->invoke( Telegram::InvokeWithLayer->new( layer => 66, query => $conn ) );

        $self->{_first} = 0;
    }
    else {
        $self->{_mt}->invoke( $query );
    }
}

sub auth
{
    my ($self, %arg) = @_;

    unless ($arg{code}) {
        $self->{session}{phone} = $arg{phone};
        $self->invoke(
            Telegram::Auth::SendCode->new( 
                phone_number => $arg{phone},
                api_id => $self->{_app}{api_id},
                api_hash => $self->{_app}{api_hash},
                flags => 0
        ));
    }
    else {
        $self->invoke(
            Telegram::Auth::SignIn->new(
                phone_number => $self->{session}{phone},
                phone_code_hash => $self->{_code_hash},
                phone_code => $arg{code}
        ));
    }
}

sub update
{
    my $self = shift;

    $self->invoke( Telegram::Updates::GetState->new );
}

# XXX: not called
sub _get_err_cb
{
    my $self = shift;
    return sub {
            my %err = @_;
            # TODO: log
            print "Error: $err{message}" if ($err{message});
            print "Error: $err{code}" if ($err{code});

            if ($self->{reconnect}) {
                print "reconnecting" if $self->{debug};
                undef $self->{_mt};
                $self->start;
                $self->update;
            }
    }
}

sub _get_msg_cb
{
    my $self = shift;
    return sub {
        # most magic happens here
        my $msg = shift;
        say Dumper $msg->{object};

        # short spec updates
        if ( $msg->{object}->isa('Telegram::UpdateShortMessage') or
            $msg->{object}->isa('Telegram::UpdateShortChannelMessage') or
            $msg->{object}->isa('Telegram::UpdateShortChatMessage') )
        {
            my $in_msg = $self->message_from_update( $msg->{object} );
            &{$self->{on_update}}( $in_msg ) if $self->{on_update};
        }

        # regular updates
        if ( $msg->{object}->isa('Telegram::Updates') ) {
            $self->_cache_users( @{$msg->{object}{users}} );
            $self->_cache_chats( @{$msg->{object}{chats}} );

            for my $upd ( @{$msg->{object}{updates}} ) {
                if ( $upd->isa('Telegram::UpdateNewMessage') or
                    $upd->isa('Telegram::UpdateNewChannelMessage') or
                    $upd->isa('Telegram::UpdateChatMessage') ) 
                {
                    &{$self->{on_update}}($upd->{message}) if $self->{on_update};
                }
            } 
        }

        # short generic updates
        if ( $msg->{object}->isa('Telegram::UpdateShort') ) {
            my $upd = $msg->{object}{update};
            if ( $upd->isa('Telegram::UpdateNewMessage') or
                $upd->isa('Telegram::UpdateNewChannelMessage') or
                $upd->isa('Telegram::UpdateChatMessage') ) 
            {
                &{$self->{on_update}}($upd->{message}) if $self->{on_update};
            }
        }
    }
}

sub message_from_update
{
    my ($self, $upd) = @_;
    
    local $_;
    my %arg;

    for ( qw( out mentioned media_unread silent id fwd_from via_bot_id 
        reply_to_msg_id date message entities ) ) 
    {
        $arg{$_} = $upd->{$_};
    }
    # some updates have user_id, some from_id
    $arg{from_id} = $upd->{user_id} if (exists $upd->{user_id});
    $arg{from_id} = $upd->{from_id} if (exists $upd->{from_id});

    # chat_id
    $arg{to_id} = $upd->{chat_id} if (exists $upd->{chat_id});

    return Telegram::Message->new( %arg );
}

sub get_messages
{
    local $_;
    my $self = shift;
    my @input;
    for (@_) {
        push @input, Telegram::InputMessageID->new( id => $_ );
    }
    $self->invoke( Telegram::Messages::GetMessages->new( id => [@input] ) );
}

sub send_text_message
{
    my ($self, %arg) = @_;
    my $msg = Telegram::Messages::SendMessage->new;

    $msg->{message} = $arg{message};
    $msg->{random_id} = rand(65536);

    my $peer;
    if (exists $self->{session}{users}{$arg{to}}) {
        $peer = Telegram::InputPeerUser->new( 
            user_id => $arg{to}, 
            access_hash => $self->{session}{users}{$arg{to}}{access_hash}
        );
    }
    if (exists $self->{session}{chats}{$arg{to}}) {
        $peer = Telegram::InputPeerChannel->new( 
            channel_id => $arg{to}, 
            access_hash => $self->{session}{users}{$arg{to}}{access_hash}
        );
    }
    if ($arg{to}->isa('Telegram::PeerChannel')) {
        $peer = Telegram::InputPeerChannel->new( 
            channel_id => $arg{to}->{channel_id}, 
            access_hash => $self->{session}{chats}{$arg{to}->{channel_id}}{access_hash}
        );
    }
    unless (defined $peer) {
        $peer = Telegram::InputPeerChat->new( chat_id => $arg{to} );
    }

    $msg->{peer} = $peer;
    $self->invoke( $msg ) if defined $peer;
}

sub _cache_users
{
    my ($self, @users) = @_;
    
    for my $user (@users) {
        $self->{session}{users}{$user->{id}} = { 
            access_hash => $user->{access_hash},
            username => $user->{username},
            first_name => $user->{first_name},
            last_name => $user->{last_name}
        };
    }
}

sub _cache_chats
{
    my ($self, @chats) = @_;
    
    for my $chat (@chats) {
        # old regular chats don't have access_hash o_O
        if (exists $chat->{access_hash}) {
            $self->{session}{chats}{$chat->{id}} = {
                access_hash => $chat->{access_hash},
                username => $chat->{username},
                title => $chat->{title}
            };
        }
    }
}

sub _get_timer_cb
{
    my $self = shift;
    return sub {
        say "timer tick" if $self->{debug};
        $self->invoke( Telegram::Updates::GetState->new );
    }
}

1;

