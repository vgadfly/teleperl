#!/usr/bib/env perl5

use Modern::Perl;
use utf8;

use Config::Tiny;
use Storable qw( store retrieve freeze thaw );
use Getopt::Long::Descriptive;

use Tkx;

use AnyEvent;
use AnyEvent::Log;

push @AnyEvent::REGISTRY, [Tkx => AnyEvTkx::]; # XXX currently pure-perl only

use Telegram;

use Data::Dumper;

sub option_spec {
    [ 'verbose|v'   => 'be verbose'                         ],
    [ 'noupdate!'   => 'pass noupdate to Telegram->new'     ],
    [ 'debug!'      => 'pass debug to Telegram->new & AE'   ],
}

my ($opts, $usage);

eval { ($opts, $usage) = describe_options( '%c %o ...', option_spec() ) };
die "Invalid opts: $@\nUsage: $usage\n" if $@;

my $session = retrieve( 'session.dat' ) if -e 'session.dat';
my $conf = Config::Tiny->read("teleperl.conf");

$Data::Dumper::Indent = 1;
$AnyEvent::Log::FILTER->level(
    $opts->{debug} ? "trace" :
        $opts->{verbose} ? "info" : "note");
$AnyEvent::Log::LOG->fmt_cb(sub {
    my ($time, $ctx, $lvl, $msg) = @_;

    my $ts = POSIX::strftime("%H:%M:%S", localtime $time)
           . sprintf ".%04d", 1e4 * ($time - int($time));

    # XXX we need just timestamp! but AE has no cb for just time..
    # XXX so copypaste rest from AnyEvent::Log
    my $ct = " ";
    my @res;

    for (split /\n/, sprintf "%-5s %s: %s", $AnyEvent::Log::LEVEL2STR[$_[2]], $_[1][0], $_[3]) {
        push @res, "$ts$ct$_\n";
        $ct = " + ";
    }

    join "", @res

});

my $mw = Tkx::widget->new(".");

my $log = $mw->new_tk__text(-state => "disabled", -width => 99, -height => 43, -wrap => "none");
$log->g_grid;

sub writeToLog {
    my ($msg) = @_;
    my $numlines = $log->index("end - 1 line");
    $log->configure(-state => "normal");
    if ($numlines==43) {$log->delete("1.0", "2.0");}
    if ($log->index("end-1c")!="1.0") {$log->insert_end("\n");}
    $log->insert_end($msg);
    $log->configure(-state => "disabled");
}

my $tg = Telegram->new(
    dc => $conf->{dc},
    app => $conf->{app},
    proxy => $conf->{proxy},
    session => $session,
    reconnect => 1,
    keepalive => 1,
    noupdate => $opts->{noupdate},
    debug => $opts->{debug}
);
$tg->{on_update} = sub {
    report_update(@_);
};

sub _format_time {
    my $ts = shift;

    # TODO take from app options/config
    return POSIX::strftime(
        (AE::now - $ts < 86400) ? "%H:%M:%S" : "%Y.%m.%d %H:%M",
        localtime $ts);
}

sub render {
    writeToLog(@_);
}

sub report_update
{
    my ($upd) = @_;

    if ($upd->isa('MTProto::RpcError')) {
        render("\rRpcError $upd->{error_code}: $upd->{error_message}");
    }
    if ($upd->isa('Telegram::Message')) {
        render_msg($upd);
    }
    if ($upd->isa('Telegram::UpdateChatUserTyping')) {
        my $user = $tg->peer_name($upd->{user_id});
        my $chat = $tg->peer_name($upd->{chat_id});
        if (defined $user and defined $chat) {
            render("\n$user is typing in $chat...");
        }
    }
}

sub render_msg {
    #@type Telegram::Message
    my $msg = shift;

    my $v = $opts->{verbose};

    my $name = defined $msg->{from_id} ? $tg->peer_name($msg->{from_id}, 1) : '(noid)';
    my $to = $msg->{to_id};
    my $ip = defined $msg->{from_id} ? $tg->peer_from_id($msg->{from_id}) : undef;
    if ($to) {
        if ($to->isa('Telegram::PeerChannel')) {
            $to = $to->{channel_id};
        }
        if ($to->isa('Telegram::PeerChat')) {
            $to = $to->{chat_id};
        }
        $ip = $tg->peer_from_id($to);
        $to = $tg->peer_name($to);
    }
    $to = $to ? " in $to" : '';

    # like telegram-cli/interface.c TODO more fields & maybe colors
    my $add = "";

    if ($msg->{fwd_from}) {
        $add .= "[fwd from ";
        my $fwh = $msg->{fwd_from};
        if ($fwh->isa('Telegram::MessageFwdHeader')) {
            $add .= $tg->peer_name($fwh->{from_id}, 1) if $fwh->{from_id};
            $add .= " in " . $tg->peer_name($fwh->{channel_id}, 1) if $fwh->{channel_id};
            if ($v) {
                $add .= " @ " . _format_time($fwh->{date});
                for (qw(channel_post post_author saved_from_msg_id)) {
                    $add .= "$_=" . $fwh->{$_} if $fwh->{$_};
                }
                # TODO saved_from_peer
            }
        }
        
        $add .= "] ";
    }
    $add .= "[reply to " . $msg->{reply_to_msg_id} . "] "           if $msg->{reply_to_msg_id};
    $add .= "[mention] "                                            if $msg->{mentioned};
    $add .= "[via " . $tg->peer_name($msg->{via_bot_id}, 1) . "] "  if $msg->{via_bot_id};
    $add .= "[edited " . _format_time($msg->{edit_date}) . "] "     if $msg->{edit_date};
    $add .= "[media] "                                              if $msg->{media};
    $add .= "[reply_markup] "                                       if $msg->{reply_markup};

    my @t = localtime;
    render("\r[rcvd " . join(":", map {"0"x(2-length).$_} reverse @t[0..2]) . "] "
        . ($v ? "id=$msg->{id} ":"")
        . _format_time($msg->{date}) . " "
        . "$name$to: $add$msg->{message}\n"
    );
}

$AnyEvent::Log::LOG->log_cb(sub { writeToLog(@_); 1 });
$tg->start;

Tkx::after(3999, sub { writeToLog("it is " . AE::now) });
Tkx::after(4999, sub { writeToLog($AnyEvent::VERBOSE ." " . AE::now) });
Tkx::MainLoop();
say "quittin..";
store( $tg->{session}, 'session.dat' ); # not the best way to do it AFTER gui
