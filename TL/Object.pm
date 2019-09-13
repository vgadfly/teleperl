package TL::Object;

use 5.012;

use warnings;
use strict;

use Carp qw/croak confess/;
use Scalar::Util qw/reftype/;

use Crypt::OpenSSL::Bignum;
use IO::Uncompress::Gunzip qw/gunzip/;

use Data::Dumper;

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
    confess("undefined value") unless defined $_[0];
    pack "l<", $_[0];
}

sub unpack_int
{
    my $stream = shift;
    unpack "l<", shift @$stream;
}

sub pack_nat
{
    confess("undefined value") unless defined $_[0];
    pack "L<", $_[0];
}

sub unpack_nat
{
    my $stream = shift;
    unpack "L<", shift @$stream;
}

sub pack_long
{
    confess ("undefined value") unless defined $_[0];
    local $_;
    $_ = pack "q<", $_[0];

    unpack "(a4)*";
}

sub unpack_long
{
    my $stream = shift;
    confess "bad stream" unless reftype($stream) eq 'ARRAY';

    my $lw = shift @$stream;
    my $hw = shift @$stream;
    unpack "q<", pack ("(a4)*", $lw, $hw);
}

sub pack_string
{
    confess("undefined value") unless defined $_[0];
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
    my $long = 0;
    if ($len == 254) {
        $long = 1;
        $len = unpack "L<", $str."\0";
        $str = '';
    }
    if ($len > 3) {
        my $tailnum = int( ($len + 3*$long) / 4 );
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
    confess("undefined value") unless defined $_[0];
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
    confess("undefined value") unless defined $_[0];
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

sub pack_double
{
    confess("undefined value") unless defined $_[0];
    local $_;
    $_ = pack "d", $_[0];

    unpack "(a4)*";
}

sub unpack_double
{
    my $stream = shift;
    confess "bad stream" unless reftype($stream) eq 'ARRAY';

    my $lw = shift @$stream;
    my $hw = shift @$stream;
    unpack "d", pack ("(a4)*", $lw, $hw);
}

sub unpack_obj
{
    use MTProto::ObjTable;
    use Telegram::ObjTable;
    my $stream = shift;
    
    # XXX: debug
    #warn "stream: ".join(",", map { sprintf("0x%x", $_ ) } map { unpack( "L<", $_ ) } @$stream);
    
    my $unpacked = $stream;
    my $hash = unpack( "L<", shift @$stream );
    confess "unexpected stream end" unless defined $hash;
    
    # Container msg, don't bother
    return undef if $hash == 0x73f1f8dc;

    # XXX: some results may be packed
    if ($hash == 0x3072cfa1) {
        #warn "zipped object";
        my $zdata = TL::Object::unpack_string($stream);
        my $objdata;
        gunzip( \$zdata => \$objdata ) or die "gunzip failure";
        
        my @str = unpack "(a4)*", $objdata;
        $hash = unpack( "L<", shift @str );
        $unpacked = \@str;
    }

    if (exists $MTProto::ObjTable::tl_type{$hash}) {
        my $pm = $MTProto::ObjTable::tl_type{$hash};
        #say "got $pm->{class}";
        require $pm->{file};
        return $pm->{class}->unpack($unpacked);
    }
    if (exists $Telegram::ObjTable::tl_type{$hash}) {
        my $pm = $Telegram::ObjTable::tl_type{$hash};
        #say "got $pm->{class}";
        require $pm->{file};
        my $obj = $pm->{class}->unpack($unpacked);
        #say "unpacked $pm->{class}";
        #warn "left: ".join(",", map { sprintf("0x%x", $_ ) } map { unpack( "L<", $_ ) } @$stream);
        return $obj;
    }
    return bless(do {\( my $v = 0 )}, 'TL::False') if ($hash == 0xbc799737); # boolFalse
    return bless(do {\( my $v = 1 )}, 'TL::True') if ($hash == 0x997275b5); # boolTrue

    warn "unknown object type: 0x".sprintf("%x", $hash);
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

sub pack_true
{
    return ();
}

sub unpack_true
{
    return 1;
}

package TL::False; sub TO_CBOR { do { bless \(my $o=1), Types::Serialiser::Boolean:: } }
package TL::True;  sub TO_CBOR { do { bless \(my $o=0), Types::Serialiser::Boolean:: } }

1;
