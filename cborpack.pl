use Modern::Perl;

use CBOR::XS;
use Data::Dumper;
use Teleperl::Util qw(unlock_hashref_recurse);
use Telegram::ObjTable;
use MTProto::ObjTable;
use File::Find;
use Storable qw(dclone);
use Getopt::Long::Descriptive;

require $_ for map { $_->{file} } values %Telegram::ObjTable::tl_type;
require $_ for map { $_->{file} } values %MTProto::ObjTable::tl_type;

sub option_spec {
    [ 'daily=s'     => 'regexp, $1_$2.cbor to $1.cbor, e.g. 24 hour files to one per-day' ],
    [ 'mtime=i'     => 'analogous to find -mtime, for use with --daily' ],
    [ 'prefix|p=s'  => 'prefix path for output files' ],
    [ 'dry|n'       => 'do no action, just print file names' ],
    [ 'verbose|v:+' => 'more twitting about actions', { default => 0} ],
}

### initialization

my ($opts, $usage);

eval { ($opts, $usage) = describe_options( '%c %o ...', option_spec() ) };
die "Invalid opts: $@\nUsage: $usage\n" if $@;

### pack sub

my $cbor_data;

my $cbor  = CBOR::XS->new;
my $cborp = CBOR::XS->new->pack_strings(1);

my ($rec, $octets, @all);

sub output_file {
    my $outfname = shift;
    say "starting output file $outfname";
    while (my $infname = shift) {
        say "\tinput file $infname" if $opts->verbose;
        next if $opts->dry;
        my $mtime = (stat($infname))[9];
        push @all, { infname => $infname, mtime => $mtime };
        open FH, "<", $infname
            or die "can't open '$infname': $!";

        binmode FH;

        # slurp all file at once :)
        {
            local $/ = undef;
            $cbor_data = <FH>;
            close FH;
        }

        while (my $left = length $cbor_data) {
            last if $left == 3 and $cbor_data eq $CBOR::XS::MAGIC;
            ($rec, $octets) = $cbor->decode_prefix ($cbor_data);
            substr($cbor_data, 0, $octets) = '';
            my $one_rec = sub {
                my $rec = shift;
                my $clone = dclone $rec;
                if (exists $clone->{schema}) {
                    $clone->{marktime} = delete $clone->{time};
                }
                push @all, unlock_hashref_recurse($clone);
            };
            $one_rec->($_) for (ref $rec eq 'HASH' ? $rec : @$rec);

        }
    }
    return if $opts->dry;

    my $packed = $CBOR::XS::MAGIC 
               . $cborp->encode({    # what version decoder should use
                       packtime => time,
                       schema => $Telegram::ObjTable::GENERATED_FROM,
                   })
               . $cborp->encode(\@all);

    open OUT, ">", $outfname
        or die "can't open '$outfname': $!";

    binmode OUT;
    $\ = undef;

    print OUT $packed;

    close OUT;
    @all = ();
}

## main work
$opts->{verbose}++ if $opts->dry;
$opts->{prefix} = "." unless $opts->prefix;
$opts->{prefix} .= "/" unless $opts->{prefix} =~ /\/$/;

if (my $pat = $opts->daily) {
    die "need directory arg" unless -d $ARGV[0];
    my %list;
    my $mtime = $opts->mtime || 0;
    my ($dev, $ino, $mode, $nlink, $uid, $gid, $rdev);
    say "daily: start searching" if $opts->verbose;
    find(sub {
            my $match = 0;
            say "find wanted on $_" if $opts->verbose > 1;
            /$pat/s &&
            (($dev, $ino, $mode, $nlink, $uid, $gid, $rdev) = lstat($_)) &&
            ($match = 1);
            if ($mtime) {
                $match = 0 unless int(-M _) > $mtime;
            }
            return unless $match;
            # final action
            $list{"$1.cbor"} = [] unless exists $list{"$1.cbor"};
            push @{ $list{"$1.cbor"} }, $File::Find::name ; 
        },
        $ARGV[0],
    );
    say "file list built, beginning to pack" if $opts->verbose or $opts->dry;
    output_file($opts->{prefix}.$_, sort @{ $list{$_} }) for sort keys %list;
}
else {
    my $fname = "$ARGV[0]";
    $fname =~ s/cbor$/packcbor/
        or $fname = "$ARGV[0].pack";
    output_file($fname, $ARGV[0]);
}
