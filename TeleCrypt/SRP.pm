package TeleCrypt::SRP;

use Crypt::OpenSSL::Bignum;
use Crypt::OpenSSL::RSA;
use Crypt::OpenSSL::Random;
use Crypt::OpenSSL::AES;
use Digest::SHA qw(sha256 hmac_sha512);
use PBKDF2::Tiny qw(derive);

sub tg_sh
{
    my ($data, $salt) = @_;
    return sha256( $salt . $data . $salt );
}

sub tg_ph1
{
    my ($pass, $salt1, $salt2) = @_;
    return tg_sh( tg_sh( $pass, $salt1 ), $salt2 );
}

sub tg_ph2
{
    my ($pass, $salt1, $salt2) = @_;

    my $pass = tg_ph1( $pass, $salt1, $salt2 );
    my $dk = derive( 'SHA-512', $pass, $salt1, 100000 );
    return tg_sh( $dk, $salt2 );
}

# bignum to 256 byte binary
sub bn2bin
{
    my $bn = shift;
    my $len = $bn->num_bytes;
    my $bin = $bn->to_bin;
    $bin = "\x0"x(256-$len) . $bin if $len < 256;
    return $bin;
}

sub side_a
{
    my ($p, $g, $g_b, $salt1, $salt2, $pass) = @_;

    my $bn_ctx = Crypt::OpenSSL::Bignum::CTX->new;
    
    my $p = Crypt::OpenSSL::Bignum->new_from_bin($p);
    my $g = Crypt::OpenSSL::Bignum->new_from_word($g);
    my $g_b = Crypt::OpenSSL::Bignum->new_from_bin($g_b);
    my $a = Crypt::OpenSSL::Bignum->new_from_bin(
        Crypt::OpenSSL::Random::random_pseudo_bytes( 256 )
    );
    
    my $g_a = $g->mod_exp( $a, $p, $bn_ctx );
    
    my $k = Crypt::OpenSSL::Bignum->new_from_bin( sha256( bn2bin($p) . bn2bin($g) ) );
    my $u = Crypt::OpenSSL::Bignum->new_from_bin( sha256( bn2bin($g_a) . bn2bin($g_b) ) );
    
    my $x = Crypt::OpenSSL::Bignum->new_from_bin( tg_ph2( $pass, $salt1, $salt2 ) );
    my $v = $g->mod_exp( $x, $p, $bn_ctx );
    my $k_v = $k->mod_mul( $v, $p, $bn_ctx );

    my $t = $g_b->sub($k_v);
    if ($t->cmp(Crypt::OpenSSL::Bignum->zero) == -1) {
        $t = $t->add($p);
    }
    
    my $exp = $u->mul($x, $bn_ctx);
    $exp = $exp->add($a);
    my $s_a = $t->mod_exp( $exp, $p, $bn_ctx );
    my $k_a = sha256( bn2bin($s_a) );

    # M1 := H(H(p) xor H(g) | H2(salt1) | H2(salt2) | g_a | g_b | k_a)
    my $input = sha256( bn2bin($p) ) ^ sha256( bn2bin($g) );
    $input .= sha256($salt1) . sha256($salt2) . bn2bin($g_a) . bn2bin($g_b) . $k_a;

    return ( bn2bin($g_a), sha256($input) );
}

1;

