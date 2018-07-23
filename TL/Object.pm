package TL::Object;

use 5.012;

use warnings;
use strict;

use Carp qw/croak/;
use Scalar::Util qw/reftype/;

use Crypt::OpenSSL::Bignum;

=head1 SYNOPSYS

  Provides bare types pack/unpack.

=cut

sub new
{
    my ($self, %arg) = @_;
    @$self{ keys %arg } = @arg{ keys %arg };
    return $self;
}

sub pack_int
{
    pack "l<", $_[0];
}

sub unpack_int
{
    my $stream = shift;
    unpack "l<", shift @$stream;
}

sub pack_nat
{
    pack "L<", $_[0];
}

sub unpack_nat
{
    my $stream = shift;
    unpack "L<", shift @$stream;
}

sub pack_long
{
    local $_;
    $_ = pack "q<", $_[0];

    unpack "(a4)*";
}

sub unpack_long
{
    my $stream = shift;
    croak "bad stream" unless reftype($stream) eq 'ARRAY';

    my $lw = shift @$stream;
    my $hw = shift @$stream;
    unpack "q<", pack ("(a4)*", $lw, $hw);
}

sub pack_string
{
    local $_;
    my $len = length $_[0];
    
    if ($len < 254) {
        my $padded = (($len + 4) & 0xfffffffc) - 1;
        $_ = pack "C a$padded", $len, $_[0];
    }
    else {
        my $padded = (($len + 3) & 0xfffffffc);
        $_ = pack "L< a$padded", (($len << 8) | 254), $_[0];
    }

    unpack "(a4)*";
}

sub unpack_string
{
    my $stream = shift;
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
    $_ = $_[0]->to_bin();
    my $prepend = 16 - length $_;
    $_ = "\0"x$prepend . $_;
    unpack "(a4)*";
}

sub unpack_int128
{
    local $_;
    my $stream = shift;
    my @int128 = splice @$stream, 0, 4;
    return Crypt::OpenSSL::Bignum->new_from_bin( pack( "(a4)*", @int128 ) );
}

sub pack_int256
{
    local $_;
    $_ = $_[0]->to_bin();
    my $prepend = 32 - length $_;
    $_ = "\0"x$prepend . $_;
    unpack "(a4)*";
}

sub unpack_int256
{
    local $_;
    my $stream = shift;
    my @int256 = splice @$stream, 0, 8;
    return Crypt::OpenSSL::Bignum->new_from_bin( pack( "(a4)*", @int256 ) );
}

sub unpack_obj
{
    use MTProto::ObjTable;
    use Telegram::ObjTable;
    my $stream = shift;
    my $hash = unpack( "L<", shift @$stream );
    croak "unexpected stream end" unless defined $hash;

    if (exists $MTProto::ObjTable::tl_type{$hash}) {
        my $pm = $MTProto::ObjTable::tl_type{$hash};
        $pm =~ s/::/\//g;
        require $pm.".pm";
        return $MTProto::ObjTable::tl_type{$hash}->unpack($stream);
    }
    if (exists $Telegram::ObjTable::tl_type{$hash}) {
        my $pm = $Telegram::ObjTable::tl_type{$hash};
        $pm =~ s/::/\//g;
        require $pm.".pm";
        return $Telegram::ObjTable::tl_type{$hash}->unpack($stream);
    }
    return undef;
}

sub pack_Bool
{
    return ( $_[0] ? 0x997275b5 : 0xbc799737 );
}

sub unpack_Bool
{
    my $stream = shift;
    my $bool = unpack( "L<", shift @$stream );

    return ($bool == 0x997275b5);
}
1;
