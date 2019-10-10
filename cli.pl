#!/usr/bin/env perl

use Modern::Perl;

use ClifTg;

my $app = CliTg->new;
$app->set_default_command('console');
$app->run or warn("non-clean exit, will not save session\n"), exit;

my $session = $app->cache->get('storage');
say "quittin.. saving session";
$session->save;

