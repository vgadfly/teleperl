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
    _mt _dc _app _proxy _timer _first _req _lock _flood_timer _queue _upd 
    reconnect session auth debug keepalive noupdate force_new_session
);

# args: DC, proxy and stuff
sub new
{
    my @args = qw( noupdate keepalive reconnect force_new_session session auth );
    my ($class, %arg) = @_;
    my $self = fields::new( ref $class || $class );
    $self->SUPER::new( 
        init => undef,
        connecting => undef,
        connected => [ 
            sub { 
                $self->_dequeue;
                $self->event('connected');
                $self->{_timer} = AE::timer 0, 45, $self->_get_timer_cb;
            }, 
            sub { 
                $self->{_lock} = 1; 
                $self->{_timer} = undef;
            } 
        ],
        idle => undef
    );
    $self->_state('init');
    
    $self->{_dc} = $arg{dc};
    $self->{_proxy} = $arg{proxy};
    $self->{_app} = $arg{app};

    @$self{@args} = @arg{@args};

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

    my $force_new = $self->{force_new_session} // 0;

    my $mt = MTProto->new( 
            socket => $aeh, 
            session => ( $force_new ? {} : $self->{session} ),
            instance => $self->{auth}, 
            debug => $self->{debug}
    );
    $self->{_mt} = $mt;
    
    $mt->reg_cb( state => sub { 
            shift; AE::log debug => "MTP state @_";
            if ($_[0] eq 'session_ok') {
                $self->_state('connected');
            }
    } );
    $mt->reg_cb( fatal => sub { shift; AE::log warn => "MTP fatal @_" } );
    $mt->reg_cb( message => sub { shift; $self->_msg_cb(@_) } );
    $mt->reg_cb( error => sub { shift; $self->_error_cb(@_) } );

    $mt->start_session;

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
    my ($self, $query, $res_cb, $service) = @_;
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
        $query = Telegram::InvokeWithLayer->new( layer => 91, query => $conn ); 
        $self->{_first} = 0;
    }
    if ($self->{_lock} and not $service) {
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

sub flush
{
    my $self = shift;
    $self->{_queue} = [];
    $self->_state('connected');
}

sub _handle_rpc_result
{
    my ($self, $res) = @_;

    my $req_id = $res->{req_msg_id};
    my $defer = 0;
    AE::log debug => "Got result %s for $req_id", ref $res->{result};
    
    # Updates in result
    $self->event( update => $res->{result} )
        if ( $res->{result}->isa('Telegram::UpdatesABC') );

    # Errors
    if ($res->{result}->isa('MTProto::RpcError')) {
        $defer = $self->_handle_rpc_error($res->{result}, $req_id);
    }
    # FLOOD_WAIT is handled here
    unless ($defer) {
        $self->{_req}{$req_id}{cb}->( $res->{result} )
            if defined $self->{_req}{$req_id}{cb};
        delete $self->{_req}{$req_id};
    }
}

sub _handle_rpc_error
{
    my ($self, $err, $req_id) = @_;
    my $defer = 0;

    #$self->event(error => $err);
    
    AE::log warn => "RPC error %d:%s on req %d", 
        $err->{error_code}, $err->{error_message}, $req_id;
    
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

sub _error_cb
{
    my ($self, $err) = @_;
    #say Dumper @_;
    AE::log warn => ref($err).": ".($err->{error_message} // $err->{error_code});

    if ( $err->isa('MTProto::SocketError') and $self->{reconnect} ) {
        undef $self->{_mt};
        $self->start;
    }
    else {
        #my $e = { error_message => $err };
        #$self->_handle_rpc_error(bless($e, 'MTProto::NetError'));
        $self->_state('fatal');
        delete $self->{_timer};
        # throw it again
        $self->event( error => $err );
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
    # NOT HERE
    $self->_handle_rpc_error( $msg->{object} )
        if ( $msg->{object}->isa('MTProto::RpcError') );

    # Updates
    $self->event( update => $msg->{object} )
        if ( $msg->{object}->isa('Telegram::UpdatesABC') );

    # New session created, some updates can be missing
    if ( $msg->{object}->isa('MTProto::NewSessionCreated') ) {
        $self->event('new_session');
    }
}

sub _get_timer_cb
{
    my $self = shift;
    return sub {
        local *__ANON__ = 'Telegram::_timer_cb';
        AE::log debug => "timer tick";
        $self->invoke( Telegram::Account::UpdateStatus->new( offline => 0 ) );
        $self->{_mt}->invoke( [ MTProto::Ping->new( ping_id => rand(2**31) ) ] ) 
            if $self->{keepalive};
    }
}

1;

