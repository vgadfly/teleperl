package MTProto;

use fields qw( socket session_id salt seq auth_key auth_key_id auth_key_aux );

use Time::HiRes qw( time );
use Crypt::OpenSSL::Bignum;
use Crypt::OpenSSL::RSA;
use Crypt::OpenSSL::Random;
use Crypt::OpenSSL::AES;
use Digest::SHA qw(sha1 sha256);

use Math::Prime::Util qw(factor);
use List::Util qw( min max );

use TL::Object;

use MTProto::ReqPqMulti;
use MTProto::ResPQ;
use MTProto::PQInnerData;
use MTProto::ReqDHParams;
use MTProto::SetClientDHParams;
use MTProto::ClientDHInnerData;

use Keys;

sub msg_id
{
    my $time = time;
    my $hi = int( $time );
    my $lo = int ( ( $time - $hi ) * 2**32 );
    return pack( "(LL)<", $lo, $hi );
}

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


sub new
{
    my $class = shift;
    my $self = fields::new( ref $class || $class );
    $self->{socket} = shift;
    return $self;
}

## generate auth key and shit
sub start_session
{
    my $self = shift;
    my (@stream, $data, $len, $enc_data, $pad);

#
# STEP 1: PQ Request
#

    my $nonce = Crypt::OpenSSL::Bignum->new_from_bin(
        Crypt::OpenSSL::Random::random_pseudo_bytes(16)
    );
    my $req_pq = MTProto::ReqPqMulti->new;
    $req_pq->{nonce} = $nonce;
    
    $self->send_plain( pack( "(a4)*", $req_pq->pack ) );
    @stream = unpack( "(a4)*", $self->recv_plain );

    my $res_pq = TL::Object::unpack_obj( \@stream );
    die unless $res_pq->isa("MTProto::ResPQ");

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

    $data = pack "(a4)*", $pq_inner->pack;
    $pad = Crypt::OpenSSL::Random::random_pseudo_bytes(255-20-length($data));
    $data = "\0". sha1($data) . $data . $pad;

    my @keys = grep {defined} map { Keys::get_key($_) } @{$res_pq->{server_public_key_fingerprints}};
    die "no suitable keys" unless (@keys);

    my $rsa = $keys[0];
    $rsa->use_no_padding;
    $enc_data = $rsa->encrypt($data);

    my $req_dh = MTProto::ReqDHParams->new;
    $req_dh->{nonce} = $nonce;
    $req_dh->{server_nonce} = $res_pq->{server_nonce};
    $req_dh->{p} = $pq_inner->{p};
    $req_dh->{q} = $pq_inner->{q};
    $req_dh->{public_key_fingerprint} = Keys::key_fingerprint($rsa);
    $req_dh->{encrypted_data} = $enc_data;

    $self->send_plain( pack( "(a4)*", $req_dh->pack ) );
    @stream = unpack( "(a4)*", $self->recv_plain );

    my $dh_params = TL::Object::unpack_obj( \@stream );
    die unless $dh_params->isa('MTProto::ServerDHParamsOk');

    my $tmp_key = sha1( $new_nonce->to_bin() . $res_pq->{server_nonce}->to_bin ).
            substr( sha1( $res_pq->{server_nonce}->to_bin() . $new_nonce->to_bin ), 0, 12 );

    my $tmp_iv = substr( sha1( $res_pq->{server_nonce}->to_bin() . $new_nonce->to_bin ), -8 ).
            sha1( $new_nonce->to_bin() . $new_nonce->to_bin() ).
            substr( $new_nonce->to_bin(), 0, 4 );

    my $dh_ans = aes_ige_dec( $dh_params->{encrypted_answer}, $tmp_key, $tmp_iv );
    my $digest = substr( $dh_ans, 0, 20 );
    my $ans = substr( $dh_ans, 20 );

    # ans with padding -> can't check digest
    @stream = unpack( "(a4)*", $ans );
    my $dh_inner = TL::Object::unpack_obj( \@stream );
    die unless $dh_inner->isa('MTProto::ServerDHInnerData');

    die "bad nonce" unless $dh_inner->{nonce}->equals( $nonce );
    die "bad server_nonce" unless $dh_inner->{server_nonce}->equals( $res_pq->{server_nonce} );

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
    $client_dh_inner->{server_nonce} = $res_pq->{server_nonce};
    $client_dh_inner->{retry_id} = 0;
    $client_dh_inner->{g_b} = $g_b->to_bin;

    $data = pack "(a4)*", $client_dh_inner->pack();
    $data = sha1($data) . $data;
    $len = (length($data) + 15 ) & 0xfffffff0;
    $pad = Crypt::OpenSSL::Random::random_pseudo_bytes($len - length($data));
    $data = $data . $pad;
    $enc_data = aes_ige_enc( $plain, $tmp_key, $tmp_iv );

    my $dh_par = MTProto::SetClientDHParams->new;
    $dh_par->{nonce} = $nonce;
    $dh_par->{server_nonce} = $res_pq->{server_nonce};
    $dh_par->{encrypted_data} = $enc_data;

    my $auth_key = $g_a->mod_exp( $b, $p, $bn_ctx )->to_bin;

    $self->send_plain( pack( "(a4)*", $dh_par->pack ) );
    @stream = unpack( "(a4)*", $self->recv_plain );

    my $result = TL::Object::unpack_obj( \@stream );
    die unless $result->isa('MTProto::DhGenOk');

    # check new_nonce_hash
    my $auth_key_aux_hash = substr(sha1($auth_key), 0, 8);
    my $auth_key_hash = substr(sha1($auth_key), -8);

    my $nnh = $new_nonce->to_bin . pack("C", 1) . $auth_key_aux_hash;
    $nnh = substr(sha1($nnh), -16);
    die "bad new_nonce_hash1" unless $result->{new_nonce_hash1}->to_bin eq $nnh;

    $self->{salt} = substr($new_nonce->to_bin, 0, 8) ^ substr($res_pq->{server_nonce}->to_bin, 0, 8);
    $self->{session_id} = Crypt::OpenSSL::Random::random_pseudo_bytes(8);
    $self->{auth_key} = $auth_key;
    $self->{auth_key_id} = $auth_key_hash;
    $self->{auth_key_aux} = $auth_key_aux_hash;
}

## load auth key and shit from file
sub load_session
{
    ...
}

## save auth key and shit to file
sub save_session
{
    ...
}

## send unencrypted message
sub send_plain
{
    my ($self, $data) = @_;
    my $datalen = length( $data );
    my $pkglen = $datalen + 20;

    $self->{socket}->send( 
        pack( "(LLL)", $pkglen, 0, 0 ) . msg_id() . pack( "L<", $datalen ) . $data, 0
    );

}

## send encrypted message
sub send
{
    ...
}

1;

