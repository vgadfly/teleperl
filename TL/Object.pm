package TL::Object;

use 5.012;

use warnings;
use strict;

use Carp qw/croak confess/;
use Scalar::Util qw/reftype/;

use Crypt::OpenSSL::Bignum;
use IO::Uncompress::Gunzip qw/gunzip/;

use Data::Dumper;

use Encode qw(/utf8/ :fallback_all);
use Params::Validate qw(!:DEFAULT :types validate_with);
use Types::Serialiser;

=head1 SYNOPSYS

  Provides bare types pack/unpack.

=cut

our $UTF8_STRINGS = 0;  # whether do UTF encoding/decoding by schema
our $VALIDATE = 0;      # bit 0 - on pack, bit 1 - on unpack
our $DEFAULT_NUMBERS = 0; # put default value (currently=0) if num field absent

sub new
{
    my ($self, %arg) = @_;
    @$self{ keys %arg } = @arg{ keys %arg };
    return $self;
}

sub _val_spec
{
    my $class = shift;
    my ($spec, %TYPES);

    {
        no strict 'refs';
        $spec = ${"$class\::_VALSPEC"};
        return $spec if defined $spec;
        %TYPES = %{"$class\::TYPES"};
    }

    $spec = { };

    # handle 'flags' XXX we don't handle multiple such though
    # they wasn't seen in real schemas
    my $optional = (map {
          exists $TYPES{$_}->{optional}
            ? (split(/\./, $TYPES{$_}->{optional}))[0]
            : ()
        } keys %TYPES)[0] // '';

    for my $name (keys %TYPES) {
        my %TYPE = %{ $TYPES{$name} };
        if ($name eq $optional or $TYPE{bang}) {
            $spec->{$name} = 0;
            next;
        }
        my $b = delete $TYPE{builtin};
        my $v = delete $TYPE{vector};
        # XXX alas, Params::Validate has no easy way for array element type
        if ($v) {
            $TYPE{type} = ARRAYREF;
        }
        elsif ($b) {
            my $t = delete $TYPE{type};
            if ($t eq 'true' or $t eq 'Bool') {
                $TYPE{type} = BOOLEAN | SCALARREF;
            }
            elsif ($t eq 'Object') {
                $TYPE{type} = OBJECT;
            }
            else {
                $TYPE{type} = SCALAR;
            }
            # XXX do more proper checks, mb by 'callbacks'
            my %valtype = (
                string => { },
                bytes  => { },
                int    => { regex => qr/^\s*[-+]?\d{1,10}\s*$/, $DEFAULT_NUMBERS ? (default => 0) : () },
                nat    => { regex => qr/^\s*\d+\s*$/          , $DEFAULT_NUMBERS ? (default => 0) : () },
                long   => { regex => qr/^\s*[-+]?\d{1,19}\s*$/, $DEFAULT_NUMBERS ? (default => 0) : () },
                int128 => { },   # XXX
                int256 => { },   # XXX
                double => {
                    regex => qr/^\s*[-+]?(\d+|\.\d+|\d+\.\d*)([eE][-+]?\d+)?\s*$/,
                    $DEFAULT_NUMBERS ? (default => 0) : ()
                },
                date   => { },   # XXX wat? haven't ever seen such in schema
                true   => { default => 0 },
                Bool   => { $DEFAULT_NUMBERS ? (default => 0) : () }, # XXX check if ref?
                Object => { isa => __PACKAGE__ },
            );
            %TYPE = ( %TYPE, %{ $valtype{$t} } );
        }
        else {
            my $baspkg = delete $TYPE{type};
            $TYPE{isa} = $baspkg . 'ABC';
        }

        $spec->{$name} = { %TYPE };
    }

    # done
    no strict 'refs';
    ${"$class\::_VALSPEC"} = $spec;
    return $spec;
}

sub validate
{
    my $self = shift;
    my $class = ref $self;

    my $spec = _val_spec($class);   # build new or get cached
    my %p = validate_with(  # for optimized path inside by 'params'
        params     => $self,
        spec       => $spec,
        stack_skip => 1,
        # on_fail     => sub { # default is 'confess', probably enough for us
    );
    $self->{$_} = $p{$_} for grep { ref $spec->{$_} && exists $spec->{$_}{default} } keys %$spec;
}

sub THAW
{
  my ($class, $serialiser, $val) = @_;
  die "unsupported deserialiser $serialiser" unless $serialiser eq 'CBOR';
  $class->new( %$val );
}

sub TO_CBOR
{
  my $self = shift;
  CBOR::XS::tag(26, [ ref $self,
    +{ (map { ($_ => $self->{$_}) } sort keys %$self) }
  ])
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

sub pack_bytes
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

sub unpack_bytes
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

sub pack_string
{
    my $b = $UTF8_STRINGS ? encode_utf8($_[0]) : $_[0];
    return pack_bytes($b);
}

sub unpack_string
{
    my $s = unpack_bytes(@_);
    return $UTF8_STRINGS ? decode_utf8($s, Encode::WARN_ON_ERR|Encode::FB_PERLQQ) : $s;
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
    return $Types::Serialiser::false if ($hash == 0xbc799737); # boolFalse
    return Types::Serialiser::true() if ($hash == 0x997275b5); # boolTrue

    warn "unknown object type: 0x".sprintf("%x", $hash);
    return undef;
}

sub pack_Bool
{
    return ( 0+$_[0] ? 0x997275b5 : 0xbc799737 );
}

sub unpack_Bool
{
    my $stream = shift;
    my $bool = unpack( "L<", shift @$stream );

    return ($bool == 0x997275b5 ? $Types::Serialiser::true : $Types::Serialiser::false);
}

sub pack_true
{
    return ();
}

sub unpack_true
{
    return $Types::Serialiser::true;
}

1;
