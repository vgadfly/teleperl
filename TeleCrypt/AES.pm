package TeleCrypt::AES;

use Modern::Perl;
use base 'Exporter';

use Carp;

use Crypt::OpenSSL::AES;
use Digest::SHA qw(sha1 sha256);

our $VERSION     = 0.01;

our @EXPORT      = qw(aes_ige_enc aes_ige_dec);
our @EXPORT_OK   = qw(gen_msg_key gen_aes_key gen_aes_key_mt1);

# TODO put mtproxy-perl/Crypt/CTR.pm also here or still separate?

=pod

Plain old module with AES routines used in Telegram.

=cut

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
    my ($auth_key, $plain, $x) = @_;
    my $msg_key = substr( sha256(substr($auth_key, 88+$x, 32) . $plain), 8, 16 );
    return $msg_key;
}

sub gen_aes_key
{
    my ($auth_key, $msg_key, $x) = @_;
    my $sha_a = sha256( $msg_key . substr($auth_key, $x, 36) );
    my $sha_b = sha256( substr($auth_key, 40+$x, 36) . $msg_key );
    my $aes_key = substr($sha_a, 0, 8) . substr($sha_b, 8, 16) . substr($sha_a, 24, 8);
    my $aes_iv = substr($sha_b, 0, 8) . substr($sha_a, 8, 16) . substr($sha_b, 24, 8);
    return ($aes_key, $aes_iv);
}

# by AuthKey::prepareAES_oldmtp() from mtproto/auth_key.cpp
sub gen_aes_key_mt1
{
    my ($auth_key, $msg_key, $x) = @_;
    my $sha_a = sha1( $msg_key . substr($auth_key, $x, 32) );
    my $sha_b = sha1( substr($auth_key, 32+$x, 16) . $msg_key . substr($auth_key, 48+$x, 16) );
    my $sha_c = sha1( substr($auth_key, 64+$x, 32) . $msg_key );
    my $sha_d = sha1( $msg_key . substr($auth_key, 96+$x, 32) );
    my $aes_key = substr($sha_a, 0, 8) . substr($sha_b, 8, 12) . substr($sha_c, 4, 12);
    my $aes_iv = substr($sha_a, 8, 12) . substr($sha_b, 0, 8) . substr($sha_c, 16, 4) . substr($sha_d, 0, 8);
    return ($aes_key, $aes_iv);
}

1;
