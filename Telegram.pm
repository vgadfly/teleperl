package Telegram;

=head1 SYNOPSYS

  Telegram API client

  Valid states: init, connecting, connected, idle, fatal

=cut

use Modern::Perl;
use Data::DPath 'dpath';
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
use Telegram::InvokeWithoutUpdates;
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
use fields qw( _filters
    _mt _dc _app _proxy _timer _first _req _lock _flood_timer _queue _upd 
    reconnect session tempkey authdc keepalive noupdate force_new_session
);

# args: DC, proxy and stuff
sub new
{
    my @args = qw( noupdate keepalive reconnect force_new_session session authdc tempkey );
    my ($class, %arg) = @_;
    my $self = fields::new( ref $class || $class );
    $self->SUPER::new( 
        init => undef,
        connecting => undef,
        sendtempkey => undef,
        waittempkey => undef,
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

    $self->{_filters} = { raw => [ { name => 'msg', filter => dpath('/') } ] };
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
            dcinstance => $self->{authdc}, 
    );
    $self->{_mt} = $mt;
    
    $mt->reg_cb( state => sub { 
            shift; AE::log debug => "MTP state @_";
            if ($_[0] eq 'session_ok') {
                $self->_state($self->{tempkey} ? 'sendtempkey' : 'connected');
            }
    } );
    $mt->reg_cb( fatal => sub { shift; AE::log warn => "MTP fatal @_" } );
    $mt->reg_cb( message => sub { shift; $self->_msg_cb(@_) } );
    $mt->reg_cb( error => sub { shift; $self->_error_cb(@_) } );

    $mt->reg_cb( bad_salt => sub {
            shift;
            AE::log debug => "requesting future salts";
            $self->{_mt}->invoke( [
                    MTProto::GetFutureSalts->new( num => 9 ),
                    # fire and forget, errors here are uncritical
            ] );
            $self->register_filter_event('raw',
                future_salts => "//.[isa('MTProto::FutureSalts')]"
            );
    } );

    $self->reg_cb( raw_future_salts => sub {
            shift;
            AE::log debug => "got future salts event";
            $self->{authdc}{future_salts} = $_[0];
    } );

    $mt->start_session;
}

sub _real_invoke
{
    my ( $self, $query, $cb, %param ) = @_;
    my $id_cb = delete $param{on_send};
    my $ack_cb = delete $param{on_ack};
    $self->{_mt}->invoke( [ $query, 
        sub {
            my ($req_id, $when) = @_;
            AE::log debug => "invoke ($when) $req_id for " . ref $query;
            if ($when eq 'push') {
                $self->{_req}{$req_id}{$_} = $param{$_} for keys %param;
                $self->{_req}{$req_id}{query} = $query;
                $self->{_req}{$req_id}{cb} = $cb if defined $cb;
                $self->event('raw_after_invoke', $req_id, $query, $cb, $id_cb, %param);
                $id_cb->($req_id) if defined $id_cb;
            }
            elsif ($when eq 'ack') {
                $self->event('raw_after_ack', $req_id, $query, $cb, $ack_cb);
                $ack_cb->($req_id) if defined $ack_cb;
            }
        } 
    ] );
}

## layer and other cranks wrapper

sub invoke
{
    my ($self, $query, $res_cb, %param) = @_;
    my $req_id;

    {   # argument check
        Carp::confess "empty query" unless defined $query;
        my $class = ref $query;
        my $tl_type = (grep {
            exists $_->{func} and $_->{class} eq $class
            } (values %Telegram::ObjTable::tl_type, values %MTProto::ObjTable::tl_type) # XXX disallow MTProto?
        )[0];
        Carp::confess "query of type $class is not amongst compiled schema functions"
            unless defined $tl_type;
        if ($query->isa('Telegram::Auth::BindTempAuthKey') or exists $tl_type->{bang}) {
            AE::log error => "%s TL API function can't be freely invoked by user, fix %s", $class, Carp::longmess;
            return;
        }
        AE::log info => "invoke: " . $class;
        AE::log trace => Dumper $query;
        # XXX crutch here if $tl_type->{returns} = Updates ?
    }

    # docs says:
    # The helper method invokeWithLayer can be used only together with initConnection
    # ....
    # initConnection must also be called after each auth.bindTempAuthKey
    # thus the latter is handled as sepaarte state, even before _first
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
                query => $inner,
                # TODO report proxy somewhere in future after MTProxy support...
        );
        $query = Telegram::InvokeWithLayer->new( layer => 91, query => $conn ); 
        $self->{_first} = 0;
    }
    elsif ( $self->{noupdate} || $param{noupdate} ) {
        $query = Telegram::InvokeWithoutUpdates->new( query => $query );
    }

    # GDPR export
    if (my $range = delete $param{with_range}) {
        $query = Telegram::InvokeWithMessagesRange->new( range => $range, query => $query );
    }
    if (my $takid = delete $param{with_takeout}) {
        $query = Telegram::InvokeWithTakeout->new( takeout_id => $takid, query => $query );
    }
    # XXX TODO what is the order of invokeWithTakeout / invokeWithMessagesRange
    # relative to AfterMsg(s) and each other? is it right?
    if (my $msg_id = delete $param{after_msg}) {
        $query = Telegram::InvokeAfterMsg->new( msg_id => $msg_id, query => $query );
    }
    elsif (my $msg_ids = delete $param{after_msgs}) {
        $query = Telegram::InvokeAfterMsgs->new( msg_ids => $msg_ids, query => $query );
    }

    # finally query is wrapped as needed
    if ($self->{_lock} and not $param{noqueue}) {
        $self->_enqueue( $query, $res_cb, %param );
    }
    else {
        $self->_real_invoke( $query, $res_cb, %param );
    }
}

sub _enqueue
{
    my $self = shift;
    AE::log debug => "session locked, enqueue";
    push @{$self->{_queue}}, [@_];
}

sub _dequeue
{
    my $self = shift;
    local $_;
    $self->_real_invoke(@$_) while ( $_ = shift @{$self->{_queue}} );
    $self->{_lock} = 0;
}

sub flush
{
    my $self = shift;
    $self->{_queue} = [];
    $self->_state('connected');
}

sub cancel
{
    my ($self, $req_id) = @_;
    AE::log debug => "Cancelling request $req_id";
    delete $self->{_req}{$req_id};
    $self->{_mt}->rpc_drop_answer($req_id);
}

sub _handle_rpc_result
{
    my ($self, $res) = @_;

    my $req_id = $res->{req_msg_id};
    my $defer = 0;
    AE::log debug => "Got result %s for $req_id", ref $res->{result};
    
    # Updates in result
    $self->event( update => $res->{result}, result_of => $self->{_req}{$req_id}{query} )
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
    if ( $err->{error_code} == 303 and not $err->{error_message} =~ /^FILE_/ ) {
        # migrate
        my $dc = $err->{error_message};
        $dc =~ s/^.*_MIGRATE_//;
        $defer = 1;
        $self->event(migrate => $dc, $self->{_req}{$req_id});
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
    AE::log trace => Dumper $msg->{object};

    $self->_run_filters(raw => $msg);

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
        $self->{_mt}->invoke( [ MTProto::Ping->new( ping_id => rand(2**31) ) ] ) 
            if $self->{keepalive};
    }
}

## process filters from specified table and emit events
sub _run_filters
{
    my ($self, $table, $data) = @_;

    for my $rule ($self->{_filters}{$table}) {
        if (my @res = $rule->{filter}->match($data)) {
            $self->event( $table . '_' . $rule->{name}, @res );
        }
    }
}

## allow user add new filters to table
sub register_filter_event {
    my ($self, $table, $evname, $expression) = @_;

    # XXX TODO support more tables?
    die "unsupported filter table" unless $table eq 'raw';

    push @{ $self->{_filters}{$table} }, +{
            name    => $evname,
            filter  => dpath($expression),
        };
}

1;

