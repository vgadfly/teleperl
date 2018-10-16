use Modern::Perl;
use utf8;

package Teleperl;
use base "CLI::Framework";

use Config::Tiny;
use Storable qw( store retrieve freeze thaw );

use AnyEvent::Impl::Perl;
use AnyEvent;

use Text::ParseWords;
use Term::ReadLine;
use Telegram;

sub init {
    my ($app, $opts) = @_;

    $app->set_current_command('help') if $opts->{help};

    $app->cache->set( 'verbose' => $opts->{verbose} );

    my $session = retrieve( 'session.dat' );
    my $conf = Config::Tiny->read("teleperl.conf");
    
    my $tg = Telegram->new(
        dc => $conf->{dc},
        app => $conf->{app},
        proxy => $conf->{proxy},
        session => $session,
        reconnect => 1,
        debug => 0
    );

    $app->cache->set( 'conf' => $conf );
    $app->cache->set( 'tg' => $tg );

    $app->set_prompt('T> ');
    $app->ornaments('md,me,,');
}

sub read_cmd
{
    my $app = shift;

    my $term = $app->{_readline};
    unless ( $term ) {
        $term = $app->_init_interactive();
    }
    $app->pre_prompt();

    # run event loop here
    my $cmd = $term->readline( $app->{_readline_prompt}, $app->{_readline_preput} );
    unless ( defined $cmd ) {
        @ARGV = $app->quit_signals();
        print "quittin..\n";
    }
    else {
        @ARGV = Text::ParseWords::shellwords( $cmd );
        $term->addhistory( $cmd )
            if $cmd =~ /\S/ and (!$term->Features->{autohistory} or !$term->MinLine);
    }
    return 1;
}

1;
