package TLObject;

use 5.012;

use warnings;
use strict;

use Crypt::OpenSSL::Bignum;

sub pack_int
{
    pack "L<", $_[1];
}

sub unpack_int
{
    my ($self, $stream) = @_;
    unpack "L<", shift @$stream;
}

sub pack_long
{
    local $_;
    $_ = pack "Q<", $_[1];

    unpack "(a4)*";
}

sub unpack_long
{
    my ($self, $stream) = @_;
    my $lw = shift @$stream;
    my $hw = shift @$stream;
    unpack "Q<", pack ("(a4)*", $lw, $hw);
}

sub pack_string
{
    local $_;
    my $len = length $_[1];
    
    if ($len < 254) {
        my $padded = (($len + 4) & 0xfffffffc) - 1;
        $_ = pack "C a$padded", $len, $_[1];
    }
    else {
        my $padded = (($len + 3) & 0xfffffffc);
        $_ = pack "L< a$padded", (($len << 8) | 254), $_[1];
    }

    unpack "(a4)*";
}

sub unpack_string
{
    my ($self, $stream) = @_;
    my $head = shift @$stream;
    my ($len, $str) = unpack "C a3", $head;
    if ($len == 254) {
        $len = unpack "L<", $str."\0";
        $str = '';
    }
    if ($len > 3) {
        my $tailnum = $len / 4;
        my @tail = splice( @$stream, 0, $tailnum );
        $str = $str . pack( "(a4)*", @tail );
    }
    return substr( $str, 0, $len );
}

sub pack_bytes
{
    return pack_string(@_);
}

sub unpack_bytes
{
    return unpack_string(@_);
}

sub pack_int128
{
    local $_;
    $_ = $_[1]->to_bin();
    my $prepend = 16 - length $_;
    $_ = "\0"x$prepend . $_;
    unpack "(a4)*";
}

sub unpack_int128
{
    local $_;
    my ($self, $stream) = @_;
    my @int128 = splice @$stream, 0, 4;
    return Crypt::OpenSSL::Bignum->new_from_bin( pack( "(a4)*", @int128 ) );
}

sub pack_int256
{
    local $_;
    $_ = $_[1]->to_bin();
    my $prepend = 32 - length $_;
    $_ = "\0"x$prepend . $_;
    unpack "(a4)*";
}

sub unpack_int256
{
    local $_;
    my ($self, $stream) = @_;
    my @int256 = splice @$stream, 0, 8;
    return Crypt::OpenSSL::Bignum->new_from_bin( pack( "(a4)*", @int256 ) );
}

1;
