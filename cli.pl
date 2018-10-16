#!/usr/bib/env perl5

use Modern::Perl;

use Teleperl;

my $app = Teleperl->new;
$app->set_default_command('console');
$app->run;


