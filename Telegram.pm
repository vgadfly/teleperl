package Telegram;

=head1 SYNOPSYS

  Telegram API client

  Handles connects, sessions, updates, files, entity cache

=cut

use Modern::Perl;
use Data::Dumper;
use Carp;

use IO::Socket;
use IO::Socket::Socks;
use AnyEventSocks;
#use IO::Socket::Socks::Wrapper;

use AnyEvent;

# This module should use MTProto for communication with telegram DCs

use MTProto;
use MTProto::Ping;

## Telegram API

use TeleUpd;

# Layer and Connection
use Telegram::InvokeWithLayer;
use Telegram::InitConnection;

# Auth
use Telegram::Auth::SendCode;
use Telegram::Auth::SentCode;
use Telegram::Auth::SignIn;

use Telegram::ChannelMessagesFilter;
use Telegram::Account::UpdateStatus;

# Messages
use Telegram::Message;
use Telegram::Messages::GetMessages;
use Telegram::Messages::SendMessage;

# input
use Telegram::InputPeer;

use base 'Class::Stateful';
use fields qw(
    _mt _dc _code_cb _app _proxy _timer _first _code_hash _req _lock _flood_timer
    _queue _upd reconnect session debug keepalive noupdate error
    on_update on_error on_raw_msg after_invoke
);

# args: DC, proxy and stuff
sub new
{
    my @args = qw( on_update on_error on_raw_msg after_invoke noupdate debug keepalive reconnect );
    my ($class, %arg) = @_;
    my $self = fields::new( ref $class || $class );
    $self->SUPER::new( 
        init => undef,
        connecting => undef,
        connected => [ sub { $self->_dequeue }, sub { $self->{_lock} = 1 } ],
        idle => undef
    );
    $self->_state('init');
    
    $self->{_dc} = $arg{dc};
    $self->{_proxy} = $arg{proxy};
    $self->{_app} = $arg{app};
    $self->{_code_cb} = $arg{on_auth};

    @$self{@args} = @arg{@args};

    # XXX: handle old session files
    my $session = $arg{session};
    $session->{mtproto} = {} unless exists $session->{mtproto};
    $self->{session} = $session;
    $self->{_first} = 1;
    $self->{_lock} = 1;

    $self->{_upd} = TeleUpd->new($session->{update_state}, $self);

    return $self;
}

# connect, start session
sub start
{
    my $self = shift;
    my $aeh;

    $self->_state('connecting');

    if (defined $self->{_proxy}) {
        AE::log info => "using proxy %s:%d", map { $self->{_proxy}{$_} } qw/addr port/;
        $aeh = AnyEvent::Handle->new( 
            connect => [ map{ $self->{_proxy}{$_}} qw/addr port/ ],
            on_connect_error => sub { $self->_fatal("Connection error") },
            on_connect => sub {
                my $socks = AnyEventSocks->new(
                    hd => $aeh, 
                    login => $self->{_proxy}{user},
                    password => $self->{_proxy}{pass},
                    cb => sub { $self->_mt($aeh) }
                );
                $socks->connect( map{ $self->{_dc}{$_} } qw/addr port/ );
            }
        );
    }
    else {
        AE::log info => "not using proxy: %s:%d", map{ $self->{_dc}{$_}} qw/addr port/;
        $aeh = AnyEvent::Handle->new( 
            connect => [ map{ $self->{_dc}{$_}} qw/addr port/ ],
            on_connect_error => sub { $self->_fatal("Connection error") },
            on_connect => sub { $self->_mt($aeh) }
        );
    }
}

sub _mt
{    
    my( $self, $aeh ) = @_;

    my $mt = MTProto->new( socket => $aeh, session => $self->{session}{mtproto},
            debug => $self->{debug}
    );
    $mt->reg_cb( state => sub { shift; AE::log debug => "MTP state @_" } );
    $mt->reg_cb( fatal => sub { shift; AE::log warn => "MTP fatal @_"; die } );
    $mt->reg_cb( message => sub { shift; $self->_msg_cb(@_) } );
    $mt->reg_cb( socket_error => sub { shift; $self->_socket_err_cb(@_) } );

    $mt->start_session;
    $self->{_mt} = $mt;
    $self->_state('connected');

    $self->run_updates unless $self->{noupdate};
    $self->_dequeue; # unlock
}

sub run_updates {
    my $self = shift;

    $self->{_timer} = AnyEvent->timer( after => 45, interval => 45, cb => $self->_get_timer_cb );
    $self->{_upd}->sync; 
}

sub _real_invoke
{
    my ( $self, $query, $cb ) = @_;
    $self->{_mt}->invoke( [ $query, 
        sub {
            my $req_id = shift;
            $self->{_req}{$req_id}{query} = $query;
            $self->{_req}{$req_id}{cb} = $cb if defined $cb;
            AE::log debug => "invoked $req_id for " . ref $query;
            &{$self->{after_invoke}}($req_id, $query, $cb) if defined $self->{after_invoke};
        } 
    ] );
}

## layer wrapper

sub invoke
{
    my ($self, $query, $res_cb) = @_;
    my $req_id;

    die unless defined $query;
    AE::log info => "invoke: " . ref $query;
    AE::log trace => Dumper $query if $self->{debug};
    if ($self->{_first}) {
        AE::log debug => "first, using wrapper";
        my $inner = $query;
        
        # Wrapper conn
        my $conn = Telegram::InitConnection->new( 
                api_id => $self->{_app}{api_id},
                device_model => $self->{_app}{device} // 'IBM PC/AT',
                system_version => $self->{_app}{sys_ver} // 'DOS 6.22',
                app_version => $self->{_app}{version} // '0.01',
                system_lang_code => 'en',
                lang_pack => '',
                lang_code => 'en',
                query => $inner
        );
        $query = Telegram::InvokeWithLayer->new( layer => 82, query => $conn ); 
        $self->{_first} = 0;
    }
    if ($self->{_lock}) {
        $self->_enqueue( $query, $res_cb );
    }
    else {
        $self->_real_invoke( $query, $res_cb );
    }
}

sub _enqueue
{
    my ($self, $query, $cb) = @_;
    AE::log debug => "session locked, enqueue";
    push @{$self->{_queue}}, [$query, $cb];
}

sub _dequeue
{
    my $self = shift;
    local $_;
    $self->_real_invoke($_->[0], $_->[1]) while ( $_ = shift @{$self->{_queue}} );
    $self->{_lock} = 0;
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

sub _handle_rpc_result
{
    my ($self, $res) = @_;

    my $req_id = $res->{req_msg_id};
    my $defer = 0;
    AE::log debug => "Got result %s for $req_id", ref $res->{result} if $self->{debug};
    if ($res->{result}->isa('MTProto::RpcError')) {
        $defer = $self->_handle_rpc_error($res->{result}, $req_id);
    }
    if (defined $self->{_req}{$req_id}{cb}) {
        &{$self->{_req}{$req_id}{cb}}( $res->{result} );
    }
    delete $self->{_req}{$req_id} unless $defer;;
}

sub _handle_rpc_error
{
    my ($self, $err, $req_id) = @_;
    my $defer = 0;

    &{$self->{on_error}}($err) if defined $self->{on_error};
    $self->{error} = $err;

    AE::log warn => "RPC error %s on req %d", $err->{error_message}, $req_id;
    if ($err->{error_message} eq 'USER_DEACTIVATED') {
        $self->{_timer} = undef;
    }
    if ($err->{error_message} eq 'AUTH_KEY_UNREGISTERED') {
        $self->{_timer} = undef;
    }
    if ($err->{error_message} =~ /^FLOOD_WAIT_/) {
        my $to = $err->{error_message};
        $to =~ s/FLOOD_WAIT_//;
        
        AE::log error => "chill for $to sec";
        $defer = 1;
        $self->_state('idle');
        my $q = $self->{_req}{$req_id}{query};
        my $cb = $self->{_req}{$req_id}{cb}; 
        # requeue the query
        $self->invoke( $q, $cb);
        delete $self->{_req}{$req_id}; 
        $self->{_flood_timer} = AE::timer($to, 0, sub {
                AE::log warn => "resend $req_id";
                $self->_state('connected');
        });
    }
    return $defer;
}

sub _socket_err_cb
{
    my ($self, $err) = shift;
    AE::log warn => "Socket error: $err";

    if ($self->{reconnect}) {
        undef $self->{_mt};
        $self->start;
    }
    else {
        my $e = { error_message => $err };
        $self->_handle_rpc_error(bless($e, 'MTProto::NetError'));
        $self->_state('idle');
    }
}

sub _msg_cb
{
    my $self = shift;
    my $msg = shift;
    AE::log info => "%s %s", ref $msg, (exists $msg->{object} ? ref($msg->{object}) : '');
    AE::log trace => Dumper $msg->{object} if $self->{debug};
    &{$self->{on_raw_msg}}( $msg->{object} ) if $self->{on_raw_msg};

    # RpcResults
    $self->_handle_rpc_result( $msg->{object} )
        if ( $msg->{object}->isa('MTProto::RpcResult') );

    # RpcErrors
    $self->_handle_rpc_error( $msg->{object} )
        if ( $msg->{object}->isa('MTProto::RpcError') );

    # Updates
    $self->{_upd}->handle_updates( $msg->{object} )
        if ( $msg->{object}->isa('Telegram::UpdatesABC') );

    # New session created, some updates can be missing
    if ( $msg->{object}->isa('MTProto::NewSessionCreated') ) {

    }
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

    my $msg = Telegram::Messages::SendMessage->new(
        map {
            $arg{$_} ? ( $_ => $arg{$_} ) : ()
        } qw(no_webpage silent background clear_draft reply_to_msg_id entities)
    );
    my $users = $self->{session}{users};
    my $chats = $self->{session}{chats};

    $msg->{message} = $arg{message};    # TODO check utf8
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
        ) if defined $chats->{$arg{to}}{access_hash};
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

    AE::log trace => Dumper $msg if defined $self->{debug};
    $self->invoke( $msg ) if defined $peer;
}

sub _get_timer_cb
{
    my $self = shift;
    return sub {
        AE::log debug => "timer tick" if $self->{debug};
        $self->invoke( Telegram::Account::UpdateStatus->new( offline => 0 ) );
        $self->{_mt}->invoke( [ MTProto::Ping->new( ping_id => rand(2**31) ) ] ) if $self->{keepalive};
    }
}

1;

