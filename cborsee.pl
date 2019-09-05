use Modern::Perl;

use CBOR::XS;
use Data::Dumper;
use POSIX;
use TL::Object;
use Telegram::ObjTable;
use MTProto::ObjTable;

require $_ for map { $_->{file} } values %Telegram::ObjTable::tl_type;
require $_ for map { $_->{file} } values %MTProto::ObjTable::tl_type;

use Data::DPath 'dpathr';
use Getopt::Long::Descriptive;

sub option_spec {
    [ 'filter|f=s'  => 'Data::DPath filter expression' ],
}

### initialization

my ($opts, $usage);

eval { ($opts, $usage) = describe_options( '%c %o ...', option_spec() ) };
die "Invalid opts: $@\nUsage: $usage\n" if $@;

die "Input filename(s) must be specified\n" unless @ARGV;

FILE: {
my $fname = shift;
last unless $fname;

open FH, "<", $fname
    or die "can't open '$fname': $!";
binmode FH;

my $cbor_data;

# slurp all file at once :)
{
    local $/ = undef;
    $cbor_data = <FH>;
    close FH;
}

my $cbor = CBOR::XS->new;

my ($rec, $octets, $filter);

local $Data::Dumper::Indent = 1;
local $Data::Dumper::Varname = $opts->filter ? 'filter' : '';
$| = 1;

$Data::DPath::USE_SAFE = 0; # or it will not see our classes O_o
$filter = dpathr($opts->filter) if $opts->filter;

my $cborlen = length $cbor_data;
my $tl_len = 0;

sub one_rec {
    my $obj = exists $_->{in} ? $_->{in} : $_->{out};
    $obj = $_->{data} unless $obj;
    $tl_len += 4*scalar($obj->pack);
    say POSIX::strftime("%Y.%m.%d %H:%M:%S ", localtime delete $_[0]->{time})
      . Dumper(defined $filter
          ? $filter->match($_[0])
          : $_[0]
      );
}

while (length $cbor_data) {
    ($rec, $octets) = $cbor->decode_prefix ($cbor_data);
#    print " octets=$octets ";
    substr($cbor_data, 0, $octets) = '';
    one_rec $_ for (ref $rec eq 'HASH' ? $rec : @$rec);
}

say "cborlen=$cborlen tl_len=$tl_len";

redo;
}
