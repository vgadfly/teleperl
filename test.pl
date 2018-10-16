#!/usr/bin/env perl

use Modern::Perl;

use IO::Socket;
use IO::Select;
use IO::Handle;
use Net::SOCKS;

#use EV;
use AnyEvent::Impl::Perl;
use AnyEvent;

use Config::Tiny;
use Storable qw( store retrieve freeze thaw );
use MTProto;

use Data::Dumper;

use constant { 
    TEST_DC => '149.154.167.40:443',
    TEST_DC_ADDR => '149.154.167.40',
    PROD_DC_ADDR => '149.154.167.51',
    TEST_DC_PORT => '443',
    PROD_DC_PORT => '443',
    PROXY_ADDR => '127.0.0.1',
    PROXY_PORT => 9050,
    PROXY_USER => '',
    PROXY_PASS => '',
};

my $cond = AnyEvent->condvar;

use Telegram::Help::GetConfig;
use MTProto::Ping;

# new connection
my $proxy = new Net::SOCKS( socks_addr => PROXY_ADDR,
    socks_port => PROXY_PORT, user_id => PROXY_USER,
    user_password => PROXY_PASS, protocol_version => 5,
);

my $sock = $proxy->connect( peer_addr => PROD_DC_ADDR, peer_port => 443 ) or die;
    
# this creates new MTProto session
my $mt = MTProto->new( socket => $sock, session => undef );

# this pushes write requests
$mt->invoke( Telegram::Help::GetConfig->new );
$mt->{on_message} = sub {
    my $msg = shift;
    if ($msg->{object}->isa('MTProto::NewSessionCreated')){
        say STDERR "session created";
    }
    else {
        say Dumper $msg->{object};
    }
};

my $signal = AnyEvent->signal( signal => 'INT', cb => sub {
        say STDERR "INT recvd";
        $cond->send;
    } );

$cond->recv;


