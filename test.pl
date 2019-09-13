use Modern::Perl;

use Teleperl;

use AnyEvent;

my $cv = AE::cv;
my $t = Teleperl->new( force_new_session => 1 );
$t->reg_cb( error => sub { $cv->send } );
$t->start;
$cv->recv;

