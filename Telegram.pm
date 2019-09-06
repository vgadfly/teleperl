package Telegram;

=head1 SYNOPSYS

  Telegram API client

  Valid states: init, connecting, connected, idle, fatal

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

# Layer and Connection
use Telegram::InvokeWithLayer;
use Telegram::InitConnection;

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
    _mt _dc _app _proxy _timer _first _req _lock _flood_timer
    _queue _upd reconnect session debug keepalive noupdate error
);

# args: DC, proxy and stuff
sub new
{
    my @args = qw( noupdate keepalive reconnect debug ); # dc, proxy, app, session
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

    @$self{@args} = @arg{@args};

    my $session = $arg{session};
    $self->{session} = $session;
    $self->{_first} = 1;
    $self->{_lock} = 1;

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

    # handle old mtp session
    if ($self->{session}{mtproto}{session_id}) {
        my $instance = {};
        my @instance_keys = qw(auth_key auth_key_id auth_key_aux salt);
        my $session = {};
        my $mts = $self->{session}{mtproto};

        @$instance{@instance_keys} = @$mts{@instance_keys};
        $session->{id} = $mts->{session_id};
        $session->{seq} = $mts->{seq};

        $self->{session}{mtproto}{instance} = $instance;
        $self->{session}{mtproto}{session} = $session;
    }

    my $mt = MTProto->new( socket => $aeh, session => $self->{session}{mtproto}{session},
            instance => $self->{session}{mtproto}{instance}, debug => $self->{debug}
    );
    $mt->reg_cb( state => sub { shift; AE::log debug => "MTP state @_" } );
    $mt->reg_cb( fatal => sub { shift; AE::log warn => "MTP fatal @_"; die } );
    $mt->reg_cb( message => sub { shift; $self->_msg_cb(@_) } );
    $mt->reg_cb( socket_error => sub { shift; $self->_socket_err_cb(@_) } );

    $mt->start_session;
    $self->{_mt} = $mt;
    $self->_state('connected');

    $self->_dequeue; # unlock

    $self->{_timer} = AE::timer 0, 45, $self->_get_timer_cb;
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
            $self->event('after_invoke', $req_id, $query, $cb);
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
        $self->event("banned");
        $self->_state('idle');
    }
    if ($err->{error_message} eq 'AUTH_KEY_UNREGISTERED') {
        $self->{_timer} = undef;
        $self->event('auth');
        $self->_state('idle');
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

    # RpcResults
    $self->_handle_rpc_result( $msg->{object} )
        if ( $msg->{object}->isa('MTProto::RpcResult') );

    # RpcErrors
    $self->_handle_rpc_error( $msg->{object} )
        if ( $msg->{object}->isa('MTProto::RpcError') );

    # Updates
    $self->event( update => $msg->{object} )
        if ( $msg->{object}->isa('Telegram::UpdatesABC') );

    # New session created, some updates can be missing
    if ( $msg->{object}->isa('MTProto::NewSessionCreated') ) {
        AE::log info => "new session created, but nothing done"
    }
}

sub _get_timer_cb
{
    my $self = shift;
    return sub {
        AE::log debug => "timer tick";
        $self->invoke( Telegram::Account::UpdateStatus->new( offline => 0 ) );
        $self->{_mt}->invoke( [ MTProto::Ping->new( ping_id => rand(2**31) ) ] ) if $self->{keepalive};
    }
}

1;

