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

use Data::Dumper;

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
        keepalive => 1,
        noupdate => 1,
        debug => 0
    );
    $tg->{on_update} = sub {$app->report_update(@_)};
    $tg->start;
    $tg->update;

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
        $term->{basic_word_break_characters} =~ s/@//g;
        $term->{completer_word_break_characters} =~ s/@//g;
        $term->event_loop(
                           sub {
                               my $data = shift;
                               $data->[0] = AE::cv();
                               $data->[0]->recv();
                           }, sub {
                               my $fh = shift;
 
                               # The data for AE are: the file event watcher (which
                               # cannot be garbage collected until we're done) and
                               # a placeholder for the condvar we're sharing between
                               # the AE::io callback created here and the wait
                               # callback above.
                               my $data = [];
                               $data->[1] = AE::io($fh, 0, sub { $data->[0]->send() });
                               $data;
                           }
                          );

    }
    $app->pre_prompt();

    # run event loop here
    my $cmd = $term->readline( $app->{_readline_prompt}, $app->{_readline_preput} );
    unless ( defined $cmd ) {
        @ARGV = $app->quit_signals();
        say "quittin..";
        my $tg = $app->cache->get('tg');
        store( $tg->{session}, 'session.dat' );
    }
    else {
        @ARGV = Text::ParseWords::shellwords( $cmd );
        $term->addhistory( $cmd )
            if $cmd =~ /\S/ and (!$term->Features->{autohistory} or !$term->MinLine);
    }
    return 1;
}

sub command_map
{
    message => 'Teleperl::Command::Message',
    debug => 'Teleperl::Command::Debug',
    dialogs => 'Teleperl::Command::Dialogs',
 
    # built-in commands:
    help    => 'CLI::Framework::Command::Help',
    list    => 'CLI::Framework::Command::List',
    tree    => 'CLI::Framework::Command::Tree',
    'dump'  => 'CLI::Framework::Command::Dump',
    console => 'CLI::Framework::Command::Console',
    alias   => 'CLI::Framework::Command::Alias',
}

sub command_alias
{
    m => 'message',
    msg => 'message'
}

sub report_update
{
    my ($self, $upd) = @_;
    my $tg = $self->cache->get('tg');

    if ($upd->isa('MTProto::RpcError')) {
        say "\rRpcError $upd->{error_code}: $upd->{error_message}";
    }
    if ($upd->isa('Telegram::Message')) {
        my $name = $tg->peer_name($upd->{from_id});
        my $to = $upd->{to_id};
        if ($to) {
            $to = $to->{channel_id} if $to->isa('Telegram::PeerChannel');
            $to = $to->{chat_id} if $to->isa('Telegram::PeerChat');
            $to = $tg->peer_name($to);
        }
        $to = $to ? " in $to" : '';
        say "\r$name$to: $upd->{message}";
        #say Dumper $upd;
    }
}

package Teleperl::Command::Message;
use base "CLI::Framework::Command";

use Encode qw/encode_utf8 decode_utf8/;
use Data::Dumper;

sub complete_arg
{
    my ($self, $lastopt, $argnum, $text, $attribs) = @_;

    my $tg = $self->cache->get('tg');

    if ($argnum == 1) {
        return ($tg->cached_nicknames(), $tg->cached_usernames());
    }

    return undef;

}

sub validate
{
    my ($self, $opts, @args) = @_;
    die "user/chat must be specified" unless defined $args[0];
    die "message text required" unless defined $args[1];
}

sub run
{
    my ($self, $opts, $peer, @msg) = @_;

    my $tg = $self->cache->get('tg');

    $peer = $tg->name_to_id($peer);

    return "unknown user/chat" unless defined $peer;

    $tg->send_text_message( to => $peer, message => join(' ', @msg) );
}

package Teleperl::Command::Debug;
use base "CLI::Framework::Command";

sub run
{
    my ($self, $opts, $val) = @_;

    my $tg = $self->cache->get('tg');
    $tg->{debug} = $val;

    return "debug is set to $val";
}

package Teleperl::Command::Dialogs;
use base "CLI::Framework::Command";

use Data::Dumper;
use Telegram::Messages::GetDialogs;
use Telegram::InputPeer;

sub run
{
    my $self = shift;
    my $tg = $self->cache->get('tg');

    $tg->invoke(
        Telegram::Messages::GetDialogs->new(
            offset_id => 0,
            offset_date => 0,
            offset_peer => Telegram::InputPeerEmpty->new,
            limit => -1
        )
    );
}
1;

