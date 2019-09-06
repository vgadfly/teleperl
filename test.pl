use Modern::Perl;

use Teleperl;

use AnyEvent;

my $cv = AE::cv;
my $t = Teleperl->new;

$t->start;

$cv->recv;

