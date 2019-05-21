package AnyEventSocks;

=head1 SYNOPSYS

  helper for SOCKS5 protocol on AnyEvent::Handle

=cut

use Modern::Perl;

use constant {
        TYPE_IP4 => 1,
        TYPE_IP6 => 4,
        TYPE_FQDN => 3,
         
        AUTH_ANON => 0,
        AUTH_GSSAPI => 1,
        AUTH_LOGIN => 2,
        AUTH_GTFO => 255,
         
        CMD_CONNECT => 1 ,
        CMD_BIND => 2, 
        CMD_UDP_ASSOC => 3,
};

use AnyEvent::Socket qw/format_ipv4 format_ipv6/;
use Socket qw(inet_pton inet_ntop inet_ntoa AF_INET AF_INET6);
use Data::Validate::IP qw(is_ipv4 is_ipv6);

sub new
{
    my $class = shift;

    return bless {@_}, ( ref $class || $class );
}

sub connect
{
    my ($self, $addr, $port) = @_;

    my $atype = TYPE_FQDN;
    $atype = TYPE_IP4 if is_ipv4($addr);
    $atype = TYPE_IP6 if is_ipv6($addr);

    $self->{atype} = $atype;
    $self->{host} = $addr;
    $self->{port} = $port;

    $self->handshake;
}

# from Protocol::SOCKS

sub pack_fqdn {
        my $self = shift;
        $self->pack_address(TYPE_FQDN, @_)
}
 
sub pack_ipv4 {
        my $self = shift;
        $self->pack_address(TYPE_IP4, @_)
}
 
sub pack_ipv6 {
        my $self = shift;
        $self->pack_address(TYPE_IP6, @_)
}
 
sub pack_address {
        my ($self, $type, $addr) = @_;
        if($type == TYPE_IP4) {
                return pack('C1', $type) . inet_pton(AF_INET, $addr);
        } elsif($type == TYPE_IP6) {
                return pack('C1', $type) . inet_pton(AF_INET6, $addr);
        } elsif($type == TYPE_FQDN) {
                return pack('C1C/a*', $type, $addr);
        } else {
            # XXX: don't die
                die sprintf 'unknown address type 0x%02x', $type;
        }
}

#sub extract_address {
#        my ($self, $buf) = @_;
#        return undef unless length($$buf) > 1;
# 
#        my ($type) = unpack 'C1', substr $$buf, 0, 1;
#        if($type == ATYPE_IPV4) {
#                return undef unless length($$buf) >= (1 + 4);
#                (undef, my $ip) = unpack 'C1A4', substr $$buf, 0, 1 + 4, '';
#                return '' unless $ip;
#                return inet_ntoa($ip);
#        } elsif($type == ATYPE_IPV6) {
#                return undef unless length($$buf) >= (1 + 16);
#                (undef, my $ip) = unpack 'C1A16', substr $$buf, 0, 1 + 16, '';
#                return inet_ntop(AF_INET6, $ip);
#        } elsif($type == ATYPE_FQDN) {
#                my ($len) = unpack 'C1', substr $$buf, 1, 1;
#                return undef unless length($$buf) >= (1 + 1 + $len);
#                (undef, my $host) = unpack 'C1C/a*', substr $$buf, 0, 1 + 1 + $len, '';
#                return $host;
#        } else {
#                die sprintf 'unknown address type 0x%02x', $type;
#        }
#}
 
# from AnyEvent::SOCKS::Client

sub handshake 
{
        my $self = shift;
         
        my @auth_methods = 0 ;
        if($self->{login} and $self->{password}){
                push @auth_methods, AUTH_LOGIN ;
        }
        $self->{hd}->push_write( 
                pack('CC', 5, scalar @auth_methods ) . join( "", map( pack( 'C', $_ ), @auth_methods ))
         );
          
         $self->{hd}->push_read( chunk => 2 , sub{ 
                        my $method = unpack( 'xC', $_[1] ); 
                        AE::log "debug" => "Server want auth method $method" ;
                        if($method == AUTH_GTFO ){
                                AE::log "error" => "Server: no suitable auth method";
                                undef $self ;
                                return  ;
                        }
                        $self->auth($method) ; 
         });
}
 
sub auth
{
        my( $self, $method ) = @_; 
         
        unless( $method ){
                $self->connect_cmd ;
                return ;
        }
         
        if( $method == AUTH_LOGIN and $self->{login} and $self->{password}){  
                $self->{hd}->push_write( 
                        pack('CC', 5, length $self->{login} ) . $self->{login} 
                        . pack('C', length $self->{password}) . $self->{password} 
                );              
                $self->{hd}->push_read( chunk => 2, sub{
                        my $status = unpack('xC', $_[1]) ; 
                        if( $status == 0 ){
                                $self->connect_cmd ;
                                return ;
                        }
                        AE::log "error" => "Bad login or password";
                });
                return ;
        }
         
        AE::log "error" => "Auth method $method not implemented!";
        undef $self; 
}
 
sub connect_cmd
{
        my( $self ) = @_ ; 
        
        my ($host, $port, $type) = ( $self->{host}, $self->{port}, $self->{atype} );

        $self->{hd}->push_write( 
                pack('CCC', 5, CMD_CONNECT, 0). $self->pack_address( $type, $host ) . pack( 'n', $port )
        );
         
        $self->{hd}->push_read( chunk => 4, sub{ 
                my( $status, $type ) = unpack( 'xCxC', $_[1] );
                unless( $status == 0 ){
                        AE::log "error" => "Connect cmd rejected: status is $status" ;
                        undef $self ;   
                        return ;
                }
                $self->connect_cmd_finalize( $type ); 
        });
}
 
sub connect_cmd_finalize
{ 
        my( $self, $type ) = @_ ;
         
        AE::log "debug" => "Connect cmd done, bind atype is $type"; 
         
        if($type == TYPE_IP4){
                $self->{hd}->push_read( chunk => 6, sub{
                        my( $host, $port) = unpack( "a4n", $_[1] );
                        $self->socks_connect_done( format_ipv4( $host ), $port );
                }); 
        }
        elsif($type == TYPE_IP6){
                $self->{hd}->push_read( chunk => 18, sub{
                        my( $host, $port) = unpack( "a16n", $_[1] );
                        $self->socks_connect_done( format_ipv6( $host ) , $port );
                }); 
        }
        elsif($type == TYPE_FQDN){
                #read 1 byte (fqdn len)
                # then read fqdn and port
                $self->{hd}->push_read( chunk => 1, sub{
                        my $fqdn_len = unpack( 'C', $_[1] ) ;
                        $self->{hd}->push_read( chunk => $fqdn_len + 2 , sub{
                                my $host = substr( $_[1], 0, $fqdn_len ) ;
                                my $port = unpack('n', substr( $_[1], -2) );
                                $self->socks_connect_done( $host, $port );
                        });
                });
        }
        else{
                AE::log "error" => "Unknown atype $type"; 
                undef $self ;
        }
}
 
sub socks_connect_done
{ 
        my( $self, $bind_host, $bind_port ) = @_; 
         
        AE::log "debug" => "Done with server $self->{host}:$self->{port} , bound to $bind_host:$bind_port";
         
        $self->{cb}->();
}
1;

