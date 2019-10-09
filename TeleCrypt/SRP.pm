package TeleCrypt::SRP;

use Crypt::OpenSSL::Bignum;
use Crypt::OpenSSL::RSA;
use Crypt::OpenSSL::Random;
use Crypt::OpenSSL::AES;
use Digest::SHA qw(sha1 sha256 sha512);


sub pbkdf2
{
    my ($pass, $salt, $hash, $iter, $len) = @_;

    my $tmp = $pass . $salt;
    while ($iter--) {
        $tmp = $hash->($tmp);
    }
    $tmp = substr($tmp, 0, $len) if defined $len;
    return $tmp;
}

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
    return tg_sh( pbkdf2( tg_ph1( $pass, $salt1, $salt2 ), $salt1, \&sha512, 100000) );
}

sub side_a
{
    my ($p, $g, $g_b, $salt1, $salt2, $pass) = @_;

    my $p = Crypt::OpenSSL::Bignum->new_from_bin($p);
    my $g = Crypt::OpenSSL::Bignum->new_from_word($g);
    my $g_b = Crypt::OpenSSL::Bignum->new_from_bin($g_b);
    my $a = Crypt::OpenSSL::Bignum->new_from_bin(
        Crypt::OpenSSL::Random::random_pseudo_bytes( 256 )
    );
    my $g_pad = $g->to_bin;
    $g_pad = $g_pad . "\x0"x(256 - length($g_pad));
    
    my $k = Crypt::OpenSSL::Bignum->new_from_bin( sha256( $p->to_bin . $g_pad ) );
    my $bn_ctx = Crypt::OpenSSL::Bignum::CTX->new;

    my $g_a = $g->mod_exp( $a, $p, $bn_ctx );
    my $u = Crypt::OpenSSL::Bignum->new_from_bin( sha256( $g_a->to_bin . $g_b->to_bin ) );

    my $x = Crypt::OpenSSL::Bignum->new_from_bin( tg_ph2( $pass, $salt1, $salt2 ) );
    my $v = $g->mod_exp( $x, $p, $bn_ctx );
    my $k_v = $k->mod_mul( $v, $p, $bn_ctx );

    my $t = $g_b->sub($k_v)->mod($p, $bn_ctx);
    my $s_a = $t->mod_exp( $a->add($u->mod_mul($x, $p, $bn_ctx))->mod($p, $bn_ctx), $p, $bn_ctx );
    my $k_a = sha256($s_a->to_bin);

    # M1 := H(H(p) xor H(g) | H2(salt1) | H2(salt2) | g_a | g_b | k_a)
    my $input = sha256($p->to_bin) ^ sha256($g_pad);
    $input .= sha256($salt1) . sha256($salt2) . $g_a->to_bin . $g_b->to_bin . $k_a;

    return ( $g_a->to_bin, sha256($input) );
}

1;

