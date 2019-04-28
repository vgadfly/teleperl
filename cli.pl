#!/usr/bib/env perl5

use Modern::Perl;

use Storable qw(store);
use Teleperl;

my $app = Teleperl->new;
$app->set_default_command('console');
$app->run;

say "quittin..";
my $tg = $app->cache->get('tg');
store( $tg->{session}, 'session.dat' );

