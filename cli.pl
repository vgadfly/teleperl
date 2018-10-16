#!/usr/bib/env perl5

use Modern::Perl;

use Telegram;

use Config::Tiny;
use Storable qw( store retrieve freeze thaw );

use AnyEvent::Impl::Perl;
use AnyEvent;

use Encode qw/encode_utf8 decode_utf8/;

use Data::Dumper;

use Telegram::Messages::GetDialogs;
use Telegram::InputPeer;

use Teleperl;

my $app = Teleperl->new;
$app->set_default_command('console');
$app->run;
die;

my $cond = AnyEvent->condvar;

my $session = retrieve( 'session.dat' );
my $conf = Config::Tiny->read("teleperl.conf");

$session = { mtproto => $session } unless $session->{mtproto};

my $tg = Telegram->new(
    dc => $conf->{dc},
    app => $conf->{app},
    proxy => $conf->{proxy},
    session => $session,
    reconnect => 1,
    debug => 0
);

$tg->{on_update} = sub
{
    say Dumper @_;
    my $m = shift;
    if ($m->isa('Telegram::Message')) {
        if (defined $m->{mentioned}) {
            if ($m->{message} =~ /жги/ or $m->{message} =~ /Жги/ ) {
                $tg->send_text_message(
                    message => anekdot(),
                    to => $m->{to_id} // $m->{from_id}
                );
            }
            else {
                $tg->send_text_message(
                    message => 'Ась?',
                    to => $m->{to_id} // $m->{from_id}
                );
            }
        }
    }
};

$tg->start;
$tg->update;

$tg->invoke(
    Telegram::Messages::GetDialogs->new(
        offset_date => 0,
        offset_id => 0,
        offset_peer => Telegram::InputPeerEmpty->new,
        limit => -1
    ), sub {
        say "Yay, Dialogs!";
        say Dumper @_;
    }
);

my $signal = AnyEvent->signal( signal => 'INT', cb => sub {
        say STDERR "INT recvd";
        store( $tg->{session}, 'session.dat');
        $cond->send;
    } );

$cond->recv;

