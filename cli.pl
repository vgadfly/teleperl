#!/usr/bin/env perl

use Modern::Perl;

use Storable qw(store);
use ClifTg;

my $app = CliTg->new;
$app->set_default_command('console');
$app->run or warn("non-clean exit, will not save session\n"), exit;

my $sessfile = $app->cache->get('session');
my $tg = $app->cache->get('tg');
say "quittin.. saving to $sessfile";
store( $tg->{session}, $sessfile );
