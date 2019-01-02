package Telegram;

=head1 SYNOPSYS

  Telegram API client

=cut

use Modern::Perl;
use Data::Dumper;
use Carp;

use IO::Socket;
use Net::SOCKS;

use AnyEvent;

# This module should use MTProto for communication with telegram DCs

use MTProto;
use MTProto::Ping;

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
use Telegram::Account::UpdateStatus;

# Messages
use Telegram::Message;
use Telegram::Messages::GetMessages;
use Telegram::Messages::SendMessage;

# input
use Telegram::InputPeer;

use fields qw( _mt _dc _code_cb _app _proxy _timer _first _code_hash _rpc_cbs 
    reconnect session on_update debug keepalive noupdate );

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
    $self->{keepalive} = $arg{keepalive};
    $self->{noupdate} = $arg{noupdate};
    
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
    my ($self, $query, $res_cb) = @_;
    my $req_id;

    say Dumper $query if $self->{debug};
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

        $req_id = $self->{_mt}->invoke( Telegram::InvokeWithLayer->new( layer => 66, query => $conn ) );

        $self->{_first} = 0;
    }
    else {
        $req_id = $self->{_mt}->invoke( $query );
    }

    # store handler for this query result
    $self->{_rpc_cbs}{$req_id} = $res_cb if defined $res_cb;
    return $req_id;
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

    $self->invoke( Telegram::Account::UpdateStatus->new( offline => 0 ) );
    $self->invoke( Telegram::Updates::GetState->new, sub {
            my $us = shift;
            if ($us->isa('Telegram::Updates::State')) {
                $self->{session}{update_state}{seq} = $us->{seq};
                $self->{session}{update_state}{pts} = $us->{pts};
                $self->{session}{update_state}{date} = $us->{date};
            }
        } );
}

sub _handle_update
{
    my ($self, $upd) = @_;

    if (exists $upd->{pts}) {
        if ($upd->isa('Telegram::UpdateNewChannelMessage')) {
            # channels seem to have own pts
            # no official doc on this
            my $ch_id = $upd->{message}{to_id}{channel_id};
            $self->{session}{update_state}{channel_pts}{$ch_id} = $upd->{pts};
        }
        else {
            $self->{session}{update_state}{pts} = $upd->{pts};
        }
    }
    if ( $upd->isa('Telegram::UpdateNewMessage') or
        $upd->isa('Telegram::UpdateNewChannelMessage') or
        $upd->isa('Telegram::UpdateChatMessage') ) 
    {
        &{$self->{on_update}}($upd->{message}) if $self->{on_update};
    }
    if ( $upd->isa('Telegram::UpdateChannelTooLong') ) {
        warn "UpdateChannelTooLong";
        say Dumper $upd;
    }
    # TODO: separate messages from other updates
    #if ( $upd->isa('Telegram::UpdateChatUserTyping') ) {
    #    &{$self->{on_update}}($upd) if $self->{on_update};
    #}
}

sub _handle_short_update
{
    my ($self, $upd) = @_;

    my $in_msg = $self->message_from_update( $upd );
    &{$self->{on_update}}( $in_msg ) if $self->{on_update};
}

sub _handle_upd_seq
{
    my ($self, $seq) = @_;
    if ($seq > 0) {
        if ($seq > $self->{session}{update_state}{seq} + 1) {
            # update hole
            warn "\rupdate hole\n";
        }
        $self->{session}{update_state}{seq} = $seq;
    }
}

sub _handle_rpc_result
{
    my ($self, $res) = @_;

    my $req_id = $res->{req_msg_id};
    say "Got result for $req_id" if $self->{debug};
    if (defined $self->{_rpc_cbs}{$req_id}) {
        &{$self->{_rpc_cbs}{$req_id}}( $res->{result} );
        delete $self->{_rpc_cbs}{$req_id};
    }
    if ($res->{result}->isa('MTProto::RpcError')) {
        # XXX: on_error
        &{$self->{on_update}}( $res->{result} ) if defined $self->{on_update};
    }
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
        say Dumper $msg->{object} if $self->{debug};

        # RpcResults
        $self->_handle_rpc_result( $msg->{object} )
        if ( $msg->{object}->isa('MTProto::RpcResult') );

        # short spec updates
        if ( $msg->{object}->isa('Telegram::UpdateShortMessage') or
            $msg->{object}->isa('Telegram::UpdateShortChannelMessage') or
            $msg->{object}->isa('Telegram::UpdateShortChatMessage') )
        {
            $self->_handle_short_update( $msg->{object} );
        }

        # regular updates
        if ( $msg->{object}->isa('Telegram::Updates') ) {
            $self->_cache_users( @{$msg->{object}{users}} );
            $self->_cache_chats( @{$msg->{object}{chats}} );
            $self->_handle_upd_seq( $msg->{object}{seq} );
            
            for my $upd ( @{$msg->{object}{updates}} ) {
                $self->_handle_update($upd);
            }
        }

        # short generic updates
        if ( $msg->{object}->isa('Telegram::UpdateShort') ) {
            $self->_handle_update( $msg->{object}{update} );
        }
        
        if ( $msg->{object}->isa('Telegram::UpdatesTooLong') ) {
            warn "UpdatesTooLong";
        }
    }
}

sub _handle_upd_diff
{
    my ($self, $diff) = @_;

    return unless $diff->isa('Telegram::Updates::Difference');

    my $upd_state = $diff->{state};
    $self->{session}{update_state}{seq} = $upd_state->{seq};
    $self->{session}{update_state}{date} = $upd_state->{date};
    $self->{session}{update_state}{pts} = $upd_state->{pts};

    $self->_cache_users(@{$diff->{users}});
    $self->_cache_chats(@{$diff->{chats}});
    
    for my $upd (@{$diff->{other_updates}}) {
        $self->_handle_update( $upd );
    }
    for my $msg (@{$diff->{new_messages}}) {
        &{$self->{on_update}}($msg) if $self->{on_update};
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
        $arg{$_} = $upd->{$_} if exists $upd->{$_};
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
    my $users = $self->{session}{users};
    my $chats = $self->{session}{chats};

    $msg->{message} = $arg{message};
    $msg->{random_id} = int(rand(65536));

    my $peer;
    if (exists $users->{$arg{to}}) {
        $peer = Telegram::InputPeerUser->new( 
            user_id => $arg{to}, 
            access_hash => $users->{$arg{to}}{access_hash}
        );
    }
    if (exists $chats->{$arg{to}}) {
        $peer = Telegram::InputPeerChannel->new( 
            channel_id => $arg{to}, 
            access_hash => $chats->{$arg{to}}{access_hash}
        );
    }

    if ($arg{to}->isa('Telegram::PeerChannel')) {
        $peer = Telegram::InputPeerChannel->new( 
            channel_id => $arg{to}->{channel_id}, 
            access_hash => $chats->{$arg{to}->{channel_id}}{access_hash}
        );
    }
    unless (defined $peer) {
        $peer = Telegram::InputPeerChat->new( chat_id => $arg{to} );
    }

    $msg->{peer} = $peer;

    say Dumper $msg if defined $self->{debug};
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
        if (exists $self->{session}{chats}{$chat->{id}}) {
            # old regular chats don't have access_hash o_O
            if (exists $chat->{access_hash}) {
                $self->{session}{chats}{$chat->{id}}{access_hash} = $chat->{access_hash};
                $self->{session}{chats}{$chat->{id}}{username} = $chat->{username};
                $self->{session}{chats}{$chat->{id}}{title} = $chat->{title};    
            }
            else {
                $self->{session}{chats}{$chat->{id}}{title} = $chat->{title};
            }

        }
        else {
            # old regular chats don't have access_hash o_O
            if (exists $chat->{access_hash}) {
                $self->{session}{chats}{$chat->{id}} = {
                    access_hash => $chat->{access_hash},
                    username => $chat->{username},
                    title => $chat->{title}
                };
            }
            else {
                $self->{session}{chats}{$chat->{id}} = {
                    title => $chat->{title}
                };
            }
        }
    }
}

sub cached_usernames
{
    my $self = shift;
    
    return map { ($_->{first_name} // '').' '.($_->{last_name} // '') } 
           grep { $_->{first_name} or $_->{last_name} } 
           values %{$self->{session}{users}};
}

sub cached_nicknames
{
    my $self = shift;

    my $users = $self->{session}{users};
    my $chats = $self->{session}{chats};
    
    return map { '@'.$_->{username} } grep { $_->{username} } 
          ( values %$users, values %$chats );
}

sub name_to_id
{
    my ($self, $nick) = @_;

    my $users = $self->{session}{users};
    my $chats = $self->{session}{chats};

    if ($nick =~ /^@/) {
        $nick =~ s/^@//;
        for my $uid (keys %$users) {
            return $uid if defined $users->{$uid}{username} and $users->{$uid}{username} eq $nick;
        }
        for my $uid (keys %$chats) {
            return $uid if defined $chats->{$uid}{username} and $chats->{$uid}{username} eq $nick;
        }
    }
    else {
        for my $uid (keys %$users) {
            return $uid if ($users->{$uid}{first_name} // '').' '.($users->{$uid}{last_name} // '') eq $nick;
        }
    }

    return undef;
}

sub peer
{
    my ($self, $nick) = @_;

    my $users = $self->{session}{users};
    my $chats = $self->{session}{chats};

    if ($nick =~ /^@/) {
        $nick =~ s/^@//;
        for my $uid (keys %$users) {
            return Telegram::InputPeerUser->new( 
                user_id => $uid, 
                access_hash => $users->{$uid}{access_hash}
            ) if defined $users->{$uid}{username} and $users->{$uid}{username} eq $nick;
        }
        for my $uid (keys %$chats) {
            return Telegram::InputPeerChat->new( 
                chat_id => $uid, 
                access_hash => $chats->{$uid}{access_hash}
            ) if defined $chats->{$uid}{username} and $chats->{$uid}{username} eq $nick;
        }
    }
    return undef;
}

sub peer_from_id
{
    my ($self, $id) = @_;
    croak unless defined $id;

    my $users = $self->{session}{users};
    my $chats = $self->{session}{chats};

    if (exists $users->{$id}) {
        return Telegram::InputPeerUser->new( 
            user_id => $id, 
            access_hash => $users->{$id}{access_hash}
        );
    }
    if (exists $chats->{$id}) {
        if (defined $chats->{$id}{access_hash}) {
            return Telegram::InputPeerChannel->new( 
                channel_id => $id, 
                access_hash => $chats->{$id}{access_hash}
            );
        }
        else {
            return Telegram::InputPeerChat->new( 
                chat_id => $id, 
            );
        }
    }
    return undef;
}

sub peer_name
{
    my ($self, $id) = @_;
    croak unless defined $id;

    my $users = $self->{session}{users};
    my $chats = $self->{session}{chats};

    if (exists $users->{$id}) {
        say "found user ", Dumper($users->{$id}) if $self->{debug};
        return ($users->{$id}{first_name} // '' ).' '.($users->{$id}{last_name} // '');
    }
    if (exists $chats->{$id}) {
        say "found chat ", Dumper($chats->{$id}) if $self->{debug};
        return ($chats->{$id}{title} // "chat $id");
    }
    return undef;
}

sub _get_timer_cb
{
    my $self = shift;
    return sub {
        say "timer tick" if $self->{debug};
        $self->invoke( Telegram::Account::UpdateStatus->new( offline => 0 ) );
        $self->invoke( Telegram::Updates::GetDifference->new( 
                    date => $self->{session}{update_state}{date},
                    pts => $self->{session}{update_state}{pts},
                    qts => -1,
            ), 
            sub {
                $self->_handle_upd_diff(@_);
            }) unless $self->{noupdate};
        #$self->invoke( Telegram::Updates::GetState->new ) unless $self->{noupdate};
        $self->{_mt}->invoke( MTProto::Ping->new( ping_id => rand(65536) ) ) if $self->{keepalive};
    }
}

1;

