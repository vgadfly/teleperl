use Modern::Perl;

package MTProto::Message;

use fields qw( msg_id seq data object );

use TL::Object;
use Time::HiRes qw/time/;
use Carp;
use Scalar::Util qw/blessed/;

sub msg_id
{
    my $time = time;
    my $hi = int( $time );
    my $lo = int ( ( $time - $hi ) * 2**32 );
    return unpack( "Q<", pack( "(LL)<", $lo, $hi ) );
}

sub new
{
    my ($class, $seq, $data, $msg_id) = @_;
    my $self = fields::new( ref $class || $class );
    $self->{msg_id} = $msg_id // msg_id() + ($seq  << 2 ); # provides uniq ids when sending many msgs in short time
    $self->{seq} = $seq;
    if (blessed $data) {
        croak "not a TL object" unless $data->isa('TL::Object');
        $self->{object} = $data;
        $self->{data} = pack "(a4)*", $data->pack;
    }
    else {
        $self->{data} = $data;
    }
    return $self;
}

sub pack
{
    my $self = shift;
    return pack( "(QLL)<", $self->{msg_id}, $self->{seq}, length($self->{data}) ).$self->{data};
}

sub unpack
{
    my ($class, $stream) = @_;
    my $self = fields::new( ref $class || $class );
    my ($msg_id, $seq, $len) = unpack( "(QLL)<", $stream );
    $self->{data} = substr($stream, 16, $len);
    $self->{msg_id} = $msg_id;
    $self->{seq} = $seq;

    #    print "unpacked msg $seq:$msg_id with $len bytes of data\n";
    my @stream = unpack( "(a4)*", $self->{data} );
    eval { $self->{object} = TL::Object::unpack_obj(\@stream); };
    my ($package, $filename, $line) = caller;
    AE::log warn => "$@ (called from $filename:$line)" if $@;

    #print unpack "H*", $self->{data} unless (defined $self->{object});
    #print ref $self->{object} if (defined $self->{object});
    #print "\n";

    return $self;
}


package MTProto;

use Data::Dumper;

use base 'Class::Stateful';
use fields qw( 
    session instance noack _timeshift
    _lock _pending _tcp_first _aeh _pq _queue _wsz _rtt_ack _rtt _ma_pool 
);

use constant {
    MAX_WSZ => 16,
    START_RTT => 15,
    MA_INT => 4
};

use Time::HiRes qw/time/;

use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::Socket;
use Scalar::Util;

use Carp;
use IO::Socket;
use IO::Uncompress::Gunzip qw/gunzip/;
use Crypt::OpenSSL::Bignum;
use Crypt::OpenSSL::RSA;
use Crypt::OpenSSL::Random;
use Crypt::OpenSSL::AES;
use Digest::SHA qw(sha1 sha256);

use Math::Prime::Util qw/factor/;
use List::Util qw/min max/;

use TL::Object;

use MTProto::ReqPqMulti;
use MTProto::ResPQ;
use MTProto::PQInnerData;
use MTProto::ReqDHParams;
use MTProto::SetClientDHParams;
use MTProto::ClientDHInnerData;
use MTProto::MsgsAck;
use MTProto::DestroySession;

use Keys;

sub aes_ige_enc
{
    my ($plain, $key, $iv) = @_;
    my $aes = Crypt::OpenSSL::AES->new( $key );

    my $iv_c = substr( $iv, 0, 16 );
    my $iv_p = substr( $iv, 16, 16 );

    my $cypher = '';

    for (my $i = 0; $i < length($plain); $i += 16){
        my $m = substr($plain, $i, 16);
        my $c = $aes->encrypt( $iv_c ^ $m ) ^ $iv_p;

        $iv_p = $m;
        $iv_c = $c;

        $cypher .= $c;
    }

    return $cypher;
}

sub aes_ige_dec
{
    my ($cypher, $key, $iv) = @_;
    my $aes = Crypt::OpenSSL::AES->new( $key );

    my $iv_c = substr( $iv, 0, 16 );
    my $iv_p = substr( $iv, 16, 16 );

    my $plain = '';

    for (my $i = 0; $i < length($cypher); $i += 16){
        my $c = substr($cypher, $i, 16);
        my $m = $aes->decrypt( $iv_p ^ $c ) ^ $iv_c;

        $iv_p = $m;
        $iv_c = $c;

        $plain .= $m;
    }

    return $plain;
}

sub gen_msg_key
{
    my ($self, $plain, $x) = @_;
    my $msg_key = substr( sha256(substr($self->{instance}{auth_key}, 88+$x, 32) . $plain), 8, 16 );
    return $msg_key;
}

sub gen_aes_key
{
    my ($self, $msg_key, $x) = @_;
    my $sha_a = sha256( $msg_key . substr($self->{instance}{auth_key}, $x, 36) );
    my $sha_b = sha256( substr($self->{instance}{auth_key}, 40+$x, 36) . $msg_key );
    my $aes_key = substr($sha_a, 0, 8) . substr($sha_b, 8, 16) . substr($sha_a, 24, 8);
    my $aes_iv = substr($sha_b, 0, 8) . substr($sha_a, 8, 16) . substr($sha_b, 24, 8);
    return ($aes_key, $aes_iv);
}


sub new
{
    my @args = qw(instance session noack);
    my ($class, %arg) = @_;
    
    my $self = fields::new( ref $class || $class );
    $self->SUPER::new( 
        init => undef, 
        phase_one => undef,
        phase_two => undef,
        phase_three => undef,
        session_ok => undef
    );
   
    $self->{_timeshift} = 0;
    $self->{_tcp_first} = 1;
    $self->{_lock} = 0;
    $self->{_wsz} = 1;
    $self->{_rtt_ack} = 1;
    $self->{_rtt} = START_RTT;
    $self->{_ma_pool} = [ (START_RTT) x MA_INT ];
    $self->{_queue} = [];
    $self->_state('init');
    
    @$self{@args} = @arg{@args};

    # init AE socket wrap
    my $aeh = $arg{socket};
    $aeh->on_read( $self->_get_read_cb );
    $aeh->on_error( $self->_get_error_cb );
    $aeh->on_drain( $self->_get_write_cb );
    $self->{_aeh} = $aeh;
   
    return $self;
}

sub _get_read_cb
{
    my $self = shift;
    return sub {
        local *__ANON__ = 'MTProto::_read_cb';
        # all reads start with recving packet length
        $self->{_aeh}->unshift_read( chunk => 4, sub {
                my $len = unpack "L<", $_[1];
                if ($len < 16) {
                    # it is error
                    $_[0]->unshift_read( chunk => $len, sub {
                            my $error = $_[1];
                            $self->_handle_error(unpack("l<", $error));
                    } )
                } else {
                    $_[0]->unshift_read( chunk => $len, sub {
                            my $msg = $_[1];
                            $self->_recv_msg($msg);
                    } )
                }
        } );
    }
}

sub _get_error_cb
{
    my $self = shift;
    return sub {
        local *__ANON__ = 'MTProto::_error_cb';
        my ($hdl, $fatal, $msg) = @_;
        AE::log error => $!.':'.$msg;
        my $e = { error_message => $msg };
        $self->event( error => bless($e, 'MTProto::SocketError') );
        $hdl->destroy;
        $self->_state('fatal');
    }
}

sub _get_write_cb
{
    my $self = shift;
    return sub {
        $self->{_lock} = 0;
        $self->_dequeue;
    }
}

## generate auth key and shit
sub start_session
{
    my $self = shift;

    # generate new session id unless we continue old session
    unless (defined $self->{session}{id}) {
        $self->{session}{id} = Crypt::OpenSSL::Random::random_pseudo_bytes(8);
        $self->{session}{seq} = 0;
    }

    return $self->_state('session_ok') if defined $self->{instance}{auth_key};

    $self->_state('phase_one');

    AE::log debug => "starting new session\n" if $self->{debug};


#
# STEP 1: PQ Request
#

    my $nonce = Crypt::OpenSSL::Bignum->new_from_bin(
        Crypt::OpenSSL::Random::random_pseudo_bytes(16)
    );
    my $req_pq = MTProto::ReqPqMulti->new;
    $req_pq->{nonce} = $nonce;
    $self->{_pq}{nonce} = $nonce;

    $self->_send_plain( pack( "(a4)*", $req_pq->pack ) );
}

## STEP 1 reply parser
## handle ResPQ

sub _phase_one 
{
    my ($self, $data) = @_;
    my $nonce = $self->{_pq}{nonce};
    
    my $datalen = unpack "L<", substr($data, 16, 4);
    $data = substr($data, 20, $datalen);
    
    my @stream = unpack( "(a4)*", $data );
    return $self->_fatal('no data on phase one') unless @stream;

    my $res_pq = TL::Object::unpack_obj( \@stream );
    AE::log debug => Dumper $res_pq;
    return $self->_fatal('no ResPQ on phase one') 
        unless $res_pq->isa("MTProto::ResPQ");

    AE::log debug => "got ResPQ\n" if $self->{debug};

    my $pq = unpack "Q>", $res_pq->{pq};
    my @pq = factor($pq);

#
# STEP 2: DH exchange
#

    my $pq_inner = MTProto::PQInnerData->new;
    $pq_inner->{pq} = $res_pq->{pq};
    $pq_inner->{p} = pack "L>", min @pq;
    $pq_inner->{q} = pack "L>", max @pq;

    $pq_inner->{nonce} = $nonce;
    $pq_inner->{server_nonce} = $res_pq->{server_nonce};
    my $new_nonce = Crypt::OpenSSL::Bignum->new_from_bin(
        Crypt::OpenSSL::Random::random_pseudo_bytes(32)
    );
    $pq_inner->{new_nonce} = $new_nonce;
    $self->{_pq}{new_nonce} = $new_nonce;
    $self->{_pq}{server_nonce} = $res_pq->{server_nonce};

    $data = pack "(a4)*", $pq_inner->pack;
    my $pad = Crypt::OpenSSL::Random::random_pseudo_bytes(255-20-length($data));
    $data = "\0". sha1($data) . $data . $pad;

    my @keys = grep {defined} map { Keys::get_key($_) } @{$res_pq->{server_public_key_fingerprints}};
    return $self->_fatal("no suitable Keys on phase one") unless (@keys);

    my $rsa = $keys[0];
    $rsa->use_no_padding;
    my $enc_data = $rsa->encrypt($data);

    my $req_dh = MTProto::ReqDHParams->new;
    $req_dh->{nonce} = $nonce;
    $req_dh->{server_nonce} = $res_pq->{server_nonce};
    $req_dh->{p} = $pq_inner->{p};
    $req_dh->{q} = $pq_inner->{q};
    $req_dh->{public_key_fingerprint} = Keys::key_fingerprint($rsa);
    $req_dh->{encrypted_data} = $enc_data;

    $self->_state('phase_two');
    $self->_send_plain( pack( "(a4)*", $req_dh->pack ) );
}

## STEP 2 reply parser
## handle DH Params

sub _phase_two
{
    my ($self, $data) = @_;

    my $datalen = unpack "L<", substr($data, 16, 4);
    $data = substr($data, 20, $datalen);
    
    my $nonce = $self->{_pq}{nonce};
    my $new_nonce = $self->{_pq}{new_nonce};
    my $server_nonce = $self->{_pq}{server_nonce};

    my @stream = unpack( "(a4)*", $data );
    return $self->_fatal('no data on phase two') unless @stream;

    my $dh_params = TL::Object::unpack_obj( \@stream );
    return $self->_fatal('bad DH params: '.ref $dh_params)
        unless $dh_params->isa('MTProto::ServerDHParamsOk');

    AE::log debug => "got ServerDHParams";

    my $tmp_key = sha1( $new_nonce->to_bin() . $server_nonce->to_bin ).
            substr( sha1( $server_nonce->to_bin() . $new_nonce->to_bin ), 0, 12 );

    my $tmp_iv = substr( sha1( $server_nonce->to_bin() . $new_nonce->to_bin ), -8 ).
            sha1( $new_nonce->to_bin() . $new_nonce->to_bin() ).
            substr( $new_nonce->to_bin(), 0, 4 );

    my $dh_ans = aes_ige_dec( $dh_params->{encrypted_answer}, $tmp_key, $tmp_iv );
    my $digest = substr( $dh_ans, 0, 20 );
    my $ans = substr( $dh_ans, 20 );

    # ans with padding -> can't check digest
    @stream = unpack( "(a4)*", $ans );
    return $self->_fatal('no packed data in DH params') unless @stream;

    my $dh_inner = TL::Object::unpack_obj( \@stream );
    $self->_fatal('bad DHInnerData: '.ref $dh_inner) 
        unless $dh_inner->isa('MTProto::ServerDHInnerData');
    
    AE::log debug => "got ServerDHInnerData\n" if $self->{debug};

    return $self->_fatal("bad nonce") unless $dh_inner->{nonce}->equals( $nonce );
    return $self->_fatal("bad server_nonce") 
        unless $dh_inner->{server_nonce}->equals( $server_nonce );

#
# STEP 3: Complete DH
#

    my $bn_ctx = Crypt::OpenSSL::Bignum::CTX->new;
    my $p = Crypt::OpenSSL::Bignum->new_from_bin( $dh_inner->{dh_prime} );
    my $g_a = Crypt::OpenSSL::Bignum->new_from_bin( $dh_inner->{g_a} );
    my $g = Crypt::OpenSSL::Bignum->new_from_word( $dh_inner->{g} );
    my $b = Crypt::OpenSSL::Bignum->new_from_bin(
        Crypt::OpenSSL::Random::random_pseudo_bytes( 256 )
    );

    my $g_b = $g->mod_exp( $b, $p, $bn_ctx );

    my $client_dh_inner = MTProto::ClientDHInnerData->new;
    $client_dh_inner->{nonce} = $nonce;
    $client_dh_inner->{server_nonce} = $server_nonce;
    $client_dh_inner->{retry_id} = 0;
    $client_dh_inner->{g_b} = $g_b->to_bin;

    $data = pack "(a4)*", $client_dh_inner->pack();
    $data = sha1($data) . $data;
    my $len = (length($data) + 15 ) & 0xfffffff0;
    my $pad = Crypt::OpenSSL::Random::random_pseudo_bytes($len - length($data));
    $data = $data . $pad;
    my $enc_data = aes_ige_enc( $data, $tmp_key, $tmp_iv );

    my $dh_par = MTProto::SetClientDHParams->new;
    $dh_par->{nonce} = $nonce;
    $dh_par->{server_nonce} = $server_nonce;
    $dh_par->{encrypted_data} = $enc_data;

    # session auth key
    $self->{instance}{auth_key} = $g_a->mod_exp( $b, $p, $bn_ctx )->to_bin;

    $self->_state('phase_three');
    $self->_send_plain( pack( "(a4)*", $dh_par->pack ) );
}

## STEP 3 reply parser
## check reply to DH params

sub _phase_three
{
    my ($self, $data) = @_;

    my $datalen = unpack "L<", substr($data, 16, 4);
    $data = substr($data, 20, $datalen);
    
    my $nonce = $self->{_pq}{nonce};
    my $new_nonce = $self->{_pq}{new_nonce};
    my $server_nonce = $self->{_pq}{server_nonce};
    my $auth_key = $self->{instance}{auth_key};
    
    my @stream = unpack( "(a4)*", $data );
    return $self->_fatal('no data on phase three') unless @stream;

    my $result = TL::Object::unpack_obj( \@stream );
    return $self->_fatal('DH failed: '.ref $result) 
        unless $result->isa('MTProto::DhGenOk');

    AE::log debug => "DH OK";

    # check new_nonce_hash
    my $auth_key_aux_hash = substr(sha1($auth_key), 0, 8);
    my $auth_key_hash = substr(sha1($auth_key), -8);

    my $nnh = $new_nonce->to_bin . pack("C", 1) . $auth_key_aux_hash;
    $nnh = substr(sha1($nnh), -16);
    return $self->_fatal("bad new_nonce_hash1")
        unless $result->{new_nonce_hash1}->to_bin eq $nnh;

    AE::log debug => "session started";

    $self->{instance}{salt} = substr($new_nonce->to_bin, 0, 8) ^ substr($server_nonce->to_bin, 0, 8);
    $self->{instance}{auth_key_id} = $auth_key_hash;
    $self->{instance}{auth_key_aux} = $auth_key_aux_hash;
    
    # ecrypted connection established
    delete $self->{_pq};
    $self->_state('session_ok');
    # process message queue
    $self->_dequeue;
}

## recv message and handle according to current state

sub _recv_msg
{
    my $self = shift;
    $self->_stateful('_', @_);
}

sub _session_ok
{
    goto &_handle_encrypted;
}

## send unencrypted message
sub _send_plain
{
    my ($self, $data) = @_;
    my $datalen = length( $data );
    my $pkglen = $datalen + 20;

    # init tcp intermediate (no seq_no & crc)
    if ($self->{_tcp_first}) {
        $self->{_aeh}->push_write( pack("L", 0xeeeeeeee) );
        $self->{_tcp_first} = 0;
    }
    $self->{_aeh}->push_write( 
        pack( "(LQQL)<", $pkglen, 0, MTProto::Message::msg_id(), $datalen ) . $data
    );
}

sub _enqueue
{
    my ($self, $in_msg) = @_;
    
    AE::log debug => "EQ: pending ".scalar(keys %{$self->{_pending}}).
        ", in q ".scalar(@{$self->{_queue}})." w=$self->{_wsz}";
    
    push @{$self->{_queue}}, $in_msg;
}

sub _dequeue
{
    my $self = shift;
    local $_;

    # don't do anything if session is not yet espablished
    return unless $self->{_state} eq 'session_ok';

    $self->{_lock} = 0;

    AE::log debug => "DQ: pending ".scalar(keys %{$self->{_pending}}).
        ", in q ".scalar(@{$self->{_queue}})." w=$self->{_wsz}";

    while ( scalar(keys %{$self->{_pending}}) < $self->{_wsz} ) {
        $_ = shift @{$self->{_queue}};
        last unless $_;
        $self->_real_send($_);
    }
}

## send encrypted message(s)
##
## if send buffer is empty -- writes staight to socket
## else -- pushes to internal queue, which is then processed when socket 
## becomes ready
##
## multiple messages may be packed together
##
## each message is an array ref [ data, cb, is_service ]
##
## cb is a coderef, recvs message id, when it is acked
## service messages are not waiting to be acked
sub send
{
    my ($self, @msg) = @_;
    local $_;

    #AE::log info => "sending ".ref($_)." \n" for @msg;
    
    # check if session is ready
    unless ($self->{_state} eq 'session_ok') {
        AE::log debug => "session not ready, queueing\n" if $self->{debug};
        $self->_enqueue($_) for @msg;
        return;
    }
    if ( $self->{_lock} or scalar(keys %{$self->{_pending}}) >= $self->{_wsz} ) {
        $self->_enqueue($_) for @msg;
    }
    else {
        # XXX: pack multiple messages together
        $self->_real_send($_) for @msg;
    }
}

sub _real_send
{
    my ($self, $msg) = @_;
    
    $self->{_lock} = 1;
    my ($obj, $id_cb, $is_service) = @$msg;
    my $seq = $self->{session}{seq};
    $seq += 1 unless $is_service;
    my $msgid = MTProto::Message::msg_id() + $self->{_timeshift} + ($seq << 2);
    my $message = eval { MTProto::Message->new( $seq, $obj, $msgid) };
    if ($@) {
        my $e = bless( { error_message => $@ }, 'MTProto::PackException' );
        $self->event( error =>  $e );
        $self->_state('fatal');
        return;
    }
    $self->{session}{seq} += 2 unless $is_service;
    $self->{_pending}{$msgid} = $msg unless $is_service;

    # init tcp intermediate (no seq_no & crc)
    if ($self->{_tcp_first}) {
        $self->{_aeh}->push_write( pack( "L", 0xeeeeeeee ) );
        $self->{_tcp_first} = 0;
    }
    
    my $payload = eval { $message->pack };
    my $pad = Crypt::OpenSSL::Random::random_pseudo_bytes( 
        -(12+length($message->{data})) % 16 + 12 );

    my $plain = $self->{instance}{salt} . $self->{session}{id} . $payload . $pad;

    my $msg_key = $self->gen_msg_key( $plain, 0 );
    my ($aes_key, $aes_iv) = $self->gen_aes_key( $msg_key, 0 );
    my $enc_data = aes_ige_enc( $plain, $aes_key, $aes_iv );

    my $packet = $self->{instance}{auth_key_id} . $msg_key . $enc_data;

    AE::log debug => "sending $message->{seq}:$message->{msg_id} ".
        "(".ref($message->{object})."), ".
        length($packet). " bytes encrypted\n";
    $self->{_aeh}->push_write( pack("L<", length($packet)) . $packet );
    $msg->[3] = time;
    # XXX
    AnyEvent->now_update;
    $msg->[4] = AE::timer( $self->{_rtt} * 2, $self->{_rtt} * 2, sub {
            $self->_handle_rto($msgid) 
        } );
}

sub _handle_error
{
    my ($self, $error) = @_;

    $self->event( error => bless( {error_code => $error}, "MTProto::TransportError" ) );
    $self->_state('fatal');
}

sub _handle_nack
{
    my $self = shift;
    
    if ($self->{_wsz} > 1) {
        $self->{_wsz} /= 2;
        $self->{_rtt_ack} = $self->{_wsz};
    }
}

sub _handle_rto
{
    my ($self, $msgid) = @_;

    $self->_handle_nack;

    if (exists $self->{_pending}{$msgid}){
        my $time = time;
        my $pending = $self->{_pending}{$msgid}[3];

        # WTF
        if ( $time - $pending < $self->{_rtt} * 2 ) {
            AE::log debug => "premature RTO for %d (%f, %f, %f)", $msgid,
                $pending, $time, $time - $pending;
        }
        else {
            $self->send( $self->{_pending}{$msgid} );
            delete $self->{_pending}{$msgid};
        }
    }
}

sub _handle_ack
{
    my ($self, $msgid) = @_;

    if (exists $self->{_pending}{$msgid}) {
        my $last = shift @{$self->{_ma_pool}};
        my $now = time;
        my $pending = $self->{_pending}{$msgid}[3];
        my $current = $now - $pending;
        $self->{_rtt} += ( $current - $last ) / MA_INT;
        AE::log debug => "new RTT is $self->{_rtt}";
        push @{$self->{_ma_pool}}, $current;
    }

    if ( --$self->{_rtt_ack} == 0 and $self->{_wsz} < MAX_WSZ ) {
        $self->{_wsz} *= 2;
        $self->{_rtt_ack} = $self->{_wsz};
    }
    $self->{_pending}{$msgid}[1]->($msgid) if defined $self->{_pending}{$msgid}[1];
    delete $self->{_pending}{$msgid};

    $self->_dequeue;
}

sub _handle_msg
{
    my ($self, $msg, $in_container) = @_;
    local $_;

    AE::log debug => "handle_msg $msg->{seq},$msg->{msg_id}: " . ref $msg->{object};

    # unpack msg containers
    my $objid = unpack( "L<", substr($msg->{data}, 0, 4) );
    if ($objid == 0x73f1f8dc) {
        AE::log trace => "Container\n";

        my $data = $msg->{data};
        my $msg_count = unpack( "L<", substr($data, 4, 4) );
        my $pos = 8;
        
        AE::log debug => "msg container of size $msg_count\n";
        while ( $msg_count && $pos < length($data) ) {
            my $sub_len = unpack( "L<", substr($data, $pos+12, 4) );
            my $sub_msg = MTProto::Message->unpack( substr($data, $pos) );
            $self->_handle_msg( $sub_msg, 1 );
            #print "  ", unpack( "H*", $sub_msg ), "\n";
            $pos += 16 + $sub_len;
            $msg_count--;
        }
        AE::log warn => "msg container ended prematuraly" if $msg_count;
        # ack the container
        $self->_ack($msg->{msg_id});
    }
    # gzip
    elsif ($objid == 0x3072cfa1) {
        AE::log trace => "gzip\n";
        
        my @stream = unpack "(a4)*", substr($msg->{data}, 4);
        my $zdata = TL::Object::unpack_string(\@stream);
        my $objdata;
        gunzip( \$zdata => \$objdata ) or die "gunzip failure";
        
        @stream = unpack "(a4)*", $objdata;
        my $ret = TL::Object::unpack_obj(\@stream);
        
        #print "inflated: ", unpack ("H*", $objdata), "\n" if $self->{debug};
        #print ref $ret if defined $ret;
        $msg->{data} = $objdata;
        $msg->{object} = $ret;
        $self->_handle_msg( $msg, $in_container ) if defined $ret;
    }
    else {
    # service msg handlers
        my $m = $msg;
        $self->_handle_ack( $m->{object}{msg_id} ) if $m->{object}->isa('MTProto::Pong');

        if ($m->{object}->isa('MTProto::MsgsAck')) {
            $self->_handle_ack($_) for @{$m->{object}{msg_ids}};
        }
        elsif ($m->{object}->isa('MTProto::BadServerSalt')) {
            $self->{instance}{salt} = pack "Q<", $m->{object}{new_server_salt};
            $self->_resend($m->{object}{bad_msg_id});
        }
        elsif ($m->{object}->isa('MTProto::BadMsgNotification')) {
            # sesssion not in sync: destroy and make new
            my $ecode = $m->{object}{error_code};
            my $bad_msg = $m->{object}{bad_msg_id};
            AE::log warn => "error $ecode recvd for $bad_msg";
            if ( $ecode == 20 or $ecode == 32 or $ecode == 33 ) {
                # 20: message too old
                # 32: msg_seqno too low
                # 33: msg_seqno too high
                #
                # start new session
                if (exists $self->{_pending}{$bad_msg}) {
                    $self->{session}{id} = 
                        Crypt::OpenSSL::Random::random_pseudo_bytes(8);
                    $self->{session}{seq} = 0;
                    $self->_resend($bad_msg);
                }
            }
            elsif ( $ecode == 16 or $ecode == 17 ) {
                my $timeshift = ($m->{msg_id} >> 32) - ($m->{object}{bad_msg_id} >> 32);
                AE::log warn => "clock out of sync by %d, adjusting", $timeshift;
                $self->{_timeshift} = $timeshift * 2**32;
                if (exists $self->{_pending}{$bad_msg}) {
                    $self->{session}{id} = 
                        Crypt::OpenSSL::Random::random_pseudo_bytes(8);
                    $self->{session}{seq} = 0;
                    $self->_resend($bad_msg);
                }
            }
            else {
                # other errors, that cannot be fixed in runtime
                my $e = { error_code => $ecode };
                $self->event( error => bless($e, 'MTProto::Error') );
                $self->_state('fatal');
                return;
            }
        }
        elsif ($m->{object}->isa('MTProto::MsgDetailedInfoABC')) {
            $self->event( error => bless(
                { error_message =>"Unhandled MsgDetailedInfo" },
                'MTProto::Error'
                )
            );
            $self->_state('fatal');
            return;
        }
        else {
            if ($m->{object}->isa('MTProto::RpcResult')) {
                $self->_handle_ack( $m->{object}{req_msg_id} );
            }
            if (($m->{seq} & 1) and not $self->{noack} and not $in_container) {
                # ack content-related messages
                $self->_ack($m->{msg_id});
            }

            $self->event( message => $m );
        }
    }
}

sub _handle_encrypted
{
    my ($self, $data) = @_;
    my @ret;

    AE::log trace => "recvd ". length($data) ." bytes encrypted\n";

    #XXX: should be handled earlier
    if (length($data) == 4) {
        $self->_handle_error(unpack("l<", $data));
    }

    my $authkey = substr($data, 0, 8);
    my $msg_key = substr($data, 8, 16);
    my $enc_data = substr($data, 24);

    my ($aes_key, $aes_iv) = $self->gen_aes_key($msg_key, 8 );
    my $plain = aes_ige_dec( $enc_data, $aes_key, $aes_iv );
  
    my $in_salt = substr($plain, 0, 8);
    my $in_sid = substr($plain, 8, 8);
    $plain = substr($plain, 16);
    
    my $msg = MTProto::Message->unpack($plain);
    $self->_handle_msg($msg);
}

sub _ack
{
    my ($self, @msg_ids) = @_;
    my ($package, $filename, $line) = caller;
    AE::log trace => "ack " . join (",", @msg_ids);

    my $ack = MTProto::MsgsAck->new( msg_ids => \@msg_ids );
    #$ack->{msg_ids} = \@msg_ids;
    $self->_real_send( [$ack, undef, 1] );
}

## resend message by id, if it's pending (was not ACKed)
sub _resend
{
    my ($self, $id) = @_;

    if (exists $self->{_pending}{$id}){
        AE::log debug => "resending $id";
        $self->_real_send( $self->{_pending}{$id} );
        delete $self->{_pending}{$id};
    }
}

## pack object and send it; return msg_id
sub invoke
{
    goto &MTProto::send;
}

1;

