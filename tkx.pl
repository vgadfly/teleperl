#!/usr/bib/env perl5

my $VERSION = 0.01;

use Modern::Perl;
use utf8;

use Encode ':all';
use Carp;
use List::Util qw(pairs pairkeys pairvalues);
use Config::Tiny;
use Storable qw( store retrieve freeze thaw );
use Getopt::Long::Descriptive;

use Tkx;

use AnyEvent;
use AnyEvent::Log;

push @AnyEvent::REGISTRY, [Tkx => AnyEvTkx::]; # XXX currently pure-perl only

use Telegram;

use Telegram::Messages::GetDialogs;
use Telegram::InputPeer;
use Telegram::Messages::GetHistory;

use Data::Dumper;

sub option_spec {
    [ 'verbose|v!'  => 'be verbose, by default also influences logger'      ],
    [ 'noupdate!'   => 'pass noupdate to Telegram->new'                     ],
    [ 'debug|d:+'   => 'pass debug (2=trace) to Telegram->new & AE::log'    ],
    [ 'session=s'   => 'name of session data save file', { default => 'session.dat'} ],
    [ 'config|c=s'  => 'name of configuration file', { default => "teleperl.conf" } ],
    [ 'logfile|l=s' => 'path to log file', { default => "tkx.log" }         ],
}

### initialization

my ($opts, $usage);

eval { ($opts, $usage) = describe_options( '%c %o ...', option_spec() ) };
die "Invalid opts: $@\nUsage: $usage\n" if $@;

my $session = retrieve( $opts->session ) if -e $opts->session;
my $conf = Config::Tiny->read($opts->config);

$Data::Dumper::Indent = 1;
$AnyEvent::Log::FILTER->level(
    $opts->{debug} > 0 ? "trace" :
        $opts->{debug} ? "debug" :
            $opts->{verbose} ? "info" : "note"
);
$AnyEvent::Log::LOG->log_to_path($opts->logfile) if $opts->{logfile}; # XXX path vs file

# XXX workaround crutch of AE::log not handling utf8 & function name
{
    no strict 'refs';
    no warnings 'redefine';
    *AnyEvent::log    = *AE::log    = sub ($$;@) {
        AnyEvent::Log::_log
          $AnyEvent::Log::CTX{ (caller)[0] } ||= AnyEvent::Log::_pkg_ctx +(caller)[0],
          $_[0],
          map { is_utf8($_) ? encode_utf8 $_ : $_ } (
              ($opts->verbose
                  ? (split(/::/, (caller(1))[3]))[-1] . ':' . (caller(0))[2] . ": " . $_[1]
                  : $_[1]),
               (@_ > 2 ? @_[2..$#_] : ())
          );
    };
    *AnyEvent::logger = *AE::logger = sub ($;$) {
        AnyEvent::Log::_logger
          $AnyEvent::Log::CTX{ (caller)[0] } ||= AnyEvent::Log::_pkg_ctx +(caller)[0],
          $_[0],
          map { is_utf8($_) ? encode_utf8 $_ : $_ } (
              ($opts->verbose
                  ? (split(/::/, (caller(1))[3]))[-1] . ':' . (caller(0))[2] . ": " . $_[1]
                  : $_[1]),
               (@_ > 2 ? @_[2..$#_] : ())
          );
    };
}

# catch all non-our Perl's warns to log with stack trace
# we can't just Carp::Always or Devel::Confess due to AnyEvent::Log 'warn' :(
$SIG{__WARN__} = sub {
    scalar( grep /AnyEvent|log/, map { (caller($_))[0..3] } (1..3) )
        ? warn $_[0]
        : AE::log warn => &Carp::longmess;
};
$SIG{__DIE__} = sub {
    my $mess = &Carp::longmess;
#    $mess =~ s/( at .*?\n)\1/$1/s;    # Suppress duplicate tracebacks
    AE::log alert => $mess;
    die $mess;
};

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

### create GUI widgets & it's callbacks

Tkx::package_require("style");  # able to look modern
#Tkx::style__use("as", -priority => 70); # TODO what is it? discover later
Tkx::option_add("*tearOff", 0); # disable detachable GTK/Motif menus
# use available in ActivePerl's tkkit.dll packages, but not all for now
# e.g.: json ico img::xpm - do we need these?
Tkx::package_require($_)
    for qw(Tclx BWidget Tktable treectrl img::jpeg img::png);
Tkx::package_require($_) for qw(ctext tooltip widget);# other available in tklib

## global vars
my %UI;                 # container for all Tk widgets
my $statusText = 'This is somewhat like a status bar';
my $cbReplyTo  = 0;     # value of 'Reply to selected msg' checkbox
my $pbValue    = 0;     # current value of progress bar
my $sbLimit    = 10;    # value of Limit spinbox
my $msgToSend = '';     # text in entry
my $curNicklistId = 0;  # id of what is selected in listbox
my $curSelMsgId = 0;    # id of selected msg in TreeView, for MarkRead
my $lboxNicks = '{Surprised to see nick list on right?} LOL {This is old tradition in IRC and Jabber}';
my $logScrollEnd = 1;   # keep scrolling on adding
my %messageStore;       # XXX refactor me!

## create widgets
$UI{mw}         = Tkx::widget->new("."); # main window

# top and bottom labels & btns
$UI{lblToolbar} = $UI{mw}->new_ttk__label( -text => "Here planned to be toolbar :)");
$UI{sbLimit}    = $UI{mw}->new_tk__spinbox(-from => 1, -to => 9999, -width => 4, -textvariable => \$sbLimit);
$UI{btGetHistor}= $UI{mw}->new_ttk__button(-text => "Get History", -command => \&btGetHistor);
$UI{btGetDlgs}  = $UI{mw}->new_ttk__button(-text => "Get dialogs", -command => \&btGetDlgs);
$UI{btCachUsers}= $UI{mw}->new_ttk__button(-text => "Cached users", -command => \&btCachUsers);
$UI{btCachChats}= $UI{mw}->new_ttk__button(-text => "Cached Chats", -command => \&btCachChats);
$UI{cbReplyTo}  = $UI{mw}->new_ttk__checkbutton(-variable => \$cbReplyTo, -onvalue => 1, -offvalue => 0,
                        -text => "Reply to selected message");
$UI{pbCountDone}= $UI{mw}->new_ttk__progressbar(-length => 200, -mode => 'determinate', -variable => \$pbValue);
$UI{lblSendMsg} = $UI{mw}->new_ttk__label( -text => "Enter message:");
$UI{enSendMsg}  = $UI{mw}->new_ttk__entry(-width => 80, -textvariable => \$msgToSend);
$UI{btSendMsg}  = $UI{mw}->new_ttk__button(-text => "Send message", -command => \&btSendMsg);
$UI{lblStatus}  = $UI{mw}->new_ttk__label(-width => 170, -textvariable => \$statusText, -anchor => "w");
$UI{sizeGrip}   = $UI{mw}->new_ttk__sizegrip;

# parts in frames
$UI{panw}       = $UI{mw}->new_ttk__panedwindow(-orient => 'horizontal');
$UI{frmNicklist}= $UI{panw}->new_ttk__frame();
$UI{frmUpdates} = $UI{panw}->new_ttk__frame();
$UI{panMessages}= $UI{panw}->new_ttk__panedwindow(-orient => 'vertical');
$UI{frmMsgList} = $UI{panMessages}->new_ttk__frame();
$UI{frmMessage} = $UI{panMessages}->new_ttk__frame();
$UI{tvMsgList}  = $UI{frmMsgList}->new_ttk__treeview(-selectmode => "browse"); # setup others later
$UI{sbhMsgList} = $UI{frmMsgList}->new_ttk__scrollbar(-command => [$UI{tvMsgList}, "xview"], -orient => "horizontal");
$UI{sbvMsgList} = $UI{frmMsgList}->new_ttk__scrollbar(-command => [$UI{tvMsgList}, "yview"], -orient => "vertical");
$UI{txtUpdates} = $UI{frmUpdates}->new_tk__text(-state => "disabled", -width => 39, -height => 43, -wrap => "char");
$UI{sbhUpdates} = $UI{frmUpdates}->new_ttk__scrollbar(-command => [$UI{txtUpdates}, "xview"], -orient => "horizontal");
$UI{sbvUpdates} = $UI{frmUpdates}->new_ttk__scrollbar(-command => [$UI{txtUpdates}, "yview"], -orient => "vertical");
$UI{txtMessage} = $UI{frmMessage}->new_tk__text(-state => "disabled", -width => 80, -height => 24, -wrap => "word", -font => 'TkTextFont');
$UI{sbvMessage} = $UI{frmMessage}->new_ttk__scrollbar(-command => [$UI{txtMessage}, "yview"], -orient => "vertical");
$UI{lbNicklist} = $UI{frmNicklist}->new_tk__listbox(-listvariable => \$lboxNicks, -height => 43);
$UI{sbhNicklist}= $UI{frmNicklist}->new_ttk__scrollbar(-command => [$UI{lbNicklist}, "xview"], -orient => "horizontal");
$UI{sbvNicklist}= $UI{frmNicklist}->new_ttk__scrollbar(-command => [$UI{lbNicklist}, "yview"], -orient => "vertical");
$UI{panw}->add($UI{frmUpdates}, -weight => 2);
$UI{panw}->add($UI{panMessages}, -weight => 4);
$UI{panw}->add($UI{frmNicklist}, -weight => 3);
$UI{panMessages}->add($UI{frmMsgList}, -weight => 4);
$UI{panMessages}->add($UI{frmMessage}, -weight => 3);
$UI{tvMsgList}->configure(-xscrollcommand => [$UI{sbhMsgList}, 'set'],  -yscrollcommand => [$UI{sbvMsgList}, 'set']);
$UI{txtUpdates}->configure(-xscrollcommand => [$UI{sbhUpdates}, 'set'],  -yscrollcommand => [$UI{sbvUpdates}, 'set']);
$UI{txtMessage}->configure(-yscrollcommand => [$UI{sbvMessage}, 'set']);
$UI{lbNicklist}->configure(-xscrollcommand => [$UI{sbhNicklist}, 'set'], -yscrollcommand => [$UI{sbvNicklist}, 'set']);

## place widgets / set up entire look

# main window
$UI{mw}->g_wm_title("Teleperl Tk GUI");
$UI{mw}->g_wm_minsize(500, 200);

$UI{lblToolbar}->g_grid( -column => 0, -row => 0, -columnspan => 2, -sticky => "nwes", -pady => 5, -padx => 5);
$UI{sbLimit}->g_grid(    -column => 2, -row => 0, -sticky => "nes",  -pady => 5, -padx => 5);
$UI{btGetHistor}->g_grid(-column => 3, -row => 0, -sticky => "nwes", -pady => 5, -padx => 5);
$UI{btCachUsers}->g_grid(-column => 4, -row => 0, -sticky => "nwes", -pady => 5, -padx => 5);
$UI{btCachChats}->g_grid(-column => 5, -row => 0, -sticky => "nwes", -pady => 5, -padx => 5);
$UI{btGetDlgs}->g_grid(  -column => 6, -row => 0, -sticky => "nwes", -pady => 5, -padx => 5);
$UI{cbReplyTo}->g_grid(  -column => 0, -row => 2, -columnspan => 2, -sticky => "nwes", -pady => 1, -padx => 5);
$UI{pbCountDone}->g_grid(-column => 3, -row => 2, -columnspan => 4, -sticky => "nes",  -pady => 1, -padx => 5);
$UI{lblSendMsg}->g_grid( -column => 0, -row => 3, -columnspan => 1, -sticky => "nwes", -pady => 5, -padx => 5);
$UI{enSendMsg}->g_grid(  -column => 1, -row => 3, -columnspan => 5, -sticky => "nwes", -pady => 5, -padx => 5);
$UI{btSendMsg}->g_grid(  -column => 6, -row => 3, -sticky => "nwes", -pady => 5, -padx => 5);

$UI{panw}->g_grid(       -column => 0, -row => 1, -columnspan => 8, -sticky => "nwes", -pady => 1, -padx => 5);

$UI{lblStatus}->g_grid(  -column => 0, -row => 4, -columnspan => 8, -sticky => "nwes", -padx => 1);
$UI{sizeGrip}->g_grid(   -column => 7, -row => 4, -sticky => "es");

# inside Updates frame
$UI{txtUpdates}->g_grid( -column => 0, -row => 0, -sticky => "nwes");
$UI{sbhUpdates}->g_grid( -column => 0, -row => 1, -sticky => "ews");
$UI{sbvUpdates}->g_grid( -column => 1, -row => 0, -sticky => "ens");
$UI{frmUpdates}->g_grid_columnconfigure(0, -weight => 1);
$UI{frmUpdates}->g_grid_rowconfigure(0, -weight => 1);

# inside Messages pane
$UI{tvMsgList}->g_grid( -column => 0, -row => 0, -sticky => "nwes");
$UI{sbhMsgList}->g_grid( -column => 0, -row => 1, -sticky => "ews");
$UI{sbvMsgList}->g_grid( -column => 1, -row => 0, -sticky => "ens");
$UI{frmMsgList}->g_grid_columnconfigure(0, -weight => 1);
$UI{frmMsgList}->g_grid_rowconfigure(0, -weight => 1);
$UI{txtMessage}->g_grid( -column => 0, -row => 0, -sticky => "nwes");
$UI{sbvMessage}->g_grid( -column => 1, -row => 0, -sticky => "ens");
$UI{frmMessage}->g_grid_columnconfigure(0, -weight => 1);
$UI{frmMessage}->g_grid_rowconfigure(0, -weight => 1);

# inside Nicklist frame
$UI{lbNicklist}->g_grid( -column => 0, -row => 0, -sticky => "nwes");
$UI{sbhNicklist}->g_grid(-column => 0, -row => 1, -sticky => "ews");
$UI{sbvNicklist}->g_grid(-column => 1, -row => 0, -sticky => "ens");
$UI{frmNicklist}->g_grid_columnconfigure(0, -weight => 1);
$UI{frmNicklist}->g_grid_rowconfigure(0, -weight => 1);

# all window
$UI{mw}->g_grid_columnconfigure("all", -weight => 1);
$UI{mw}->g_grid_columnconfigure(0, -weight => 0);
$UI{mw}->g_grid_columnconfigure(7, -weight => 0);
$UI{mw}->g_grid_rowconfigure(1, -weight => 1);

## menus
my $IS_AQUA = Tkx::tk_windowingsystem() eq "aqua"; # detect those pesky with Mac OS
$UI{menubar}    = $UI{mw}->new_menu;
$UI{menuFile}   = $UI{menubar}->new_menu;
$UI{menuSet}    = $UI{menubar}->new_menu;
$UI{menuSetDbg} = $UI{menuSet}->new_menu;
$UI{menubar}->add_cascade(-menu => $UI{menuFile}, -label => "File");
$UI{menubar}->add_cascade(-menu => $UI{menuSet}, -label => "Set");
$UI{menuFile}->add_command(-label => "Save '$opts->{session}'", -command => \&save_session);
$UI{menuFile}->add_command(-label => "Exit", -underline => 1, -command => [\&Tkx::destroy, $UI{mw}]) unless $IS_AQUA;
$UI{menuSet}->add_checkbutton(-label => "Verbose", -variable => \$opts->{verbose}, -onvalue => 1, -offvalue => 0);
$UI{menuSet}->add_checkbutton(-label => "Keep scrolling log to end", -variable => \$logScrollEnd);
$UI{menuSet}->add_separator;
$UI{menuSet}->add_cascade(-menu => $UI{menuSetDbg}, -label => "Debug");
$UI{menuSetDbg}->add_radiobutton(-label => "Off",   -variable => \$opts->{debug}, -value => 0, -command => \&set_debug);
$UI{menuSetDbg}->add_radiobutton(-label => "Debug", -variable => \$opts->{debug}, -value => 1, -command => \&set_debug);
$UI{menuSetDbg}->add_radiobutton(-label => "Trace", -variable => \$opts->{debug}, -value => 2, -command => \&set_debug);

# those backyard Different platform...
{
    # NOTE these must be added after usual menus
    my $help = $UI{menubar}->new_menu(-name => "help"); # XXX check it really last on X11, _mpath?
    $UI{menubar}->add_cascade(-label => "Help", -underline => 0, -menu => $help);
    $help->add_command(-label => "\u$0 Manual", -command => sub { $statusText = "What? Ask Durov for it!";});
    my $about_menu = $help;
    if ($IS_AQUA) {
        # On Mac OS we want about box to appear in the application
        # menu.  Anything added to a menu with the name "apple" will
        # appear in this menu.
        $about_menu = $UI{menubar}->new_menu(-name => "apple");
        $UI{menubar}->add_cascade(-menu => $about_menu);
        # XXX need we '.window' menu for them?
    }
    $about_menu->add_command(-label => "About \u$0", -command => \&about);

    if ($^O eq 'MSWin32') {
        my $system = Tkx::widget->new(Tkx::menu($UI{menubar}->_mpath . ".system"));
        $UI{menubar}->add_cascade(-menu => $system);
        $system->add_command(-label => "foo bar", -command => sub { $statusText = "Yay!"; });
    }

}

# must be last to ".apple" work
$UI{mw}->configure(-menu => $UI{menubar});

## popup menu
$UI{menuPopup}  = $UI{mw}->new_menu();
$UI{menuPopup}->add_command(-label => $_) foreach qw(One Two Three);
if (Tkx::tk_windowingsystem() eq "aqua") {
    $UI{mw}->g_bind("<2>", [sub {my($x,$y) = @_; $UI{menuPopup}->g_tk___popup($x,$y)}, Tkx::Ev("%X", "%Y")] );
    $UI{mw}->g_bind("<Control-1>", [sub {my($x,$y) = @_; $UI{menuPopup}->g_tk___popup($x,$y)}, Tkx::Ev("%X", "%Y")]);
} else {
    $UI{mw}->g_bind("<3>", [sub {my($x,$y) = @_; $UI{menuPopup}->g_tk___popup($x,$y)}, Tkx::Ev("%X", "%Y")]);
}

## other event dispatching
$UI{mw}->g_bind("<Return>", \&btSendMsg);
$UI{lbNicklist}->g_bind("<<ListboxSelect>>", \&onNicklistSelect);
$UI{tvMsgList}->g_bind("<<TreeviewSelect>>", \&onMsgListSelect);

# set tags for messages and their list
$UI{tvMsgList}->tag_configure("out",            -background => "yellow");
$UI{tvMsgList}->tag_configure("mentioned",      -font => "-underline 1");
$UI{tvMsgList}->tag_configure("silent",         -font => "-overstrike 1");
$UI{tvMsgList}->tag_configure("MessageService", -foreground => "#a000a0");

our @_columns = (
    id              => [ [ -text => "ID" ],         [ -minwidth => 30, -width => 50 ], "%d" ],
    date            => [ [ -text => "Date/time"],   [ -minwidth => 50, -width => 89 ], \&_format_time, ],
    reply_to_msg_id => [ [ -text => "Reply to ID"], [ -minwidth => 30, -width => 50 ], "%d" ],
    from            => [ [ -text => "From" ],       [ -minwidth => 70, -width => 99 ], "%s" ],
    media_unread    => [ [ -text => "media_unread"],[ -minwidth => 10, -width => 20 ], "%d" ],
    post            => [ [ -text => "Post"],        [ -minwidth => 10, -width => 25 ], "%d" ],
# NOTE above are both with messageService, below are normal Message only
    edit_date       => [ [ -text => "Edit date" ],  [ -minwidth => 50, -width => 85 ], \&_format_time, ],
    views           => [ [ -text => "Views"],       [ -minwidth => 10, -width => 30 ], "%d" ],
    post_author     => [ [ -text => "Post author"], [ -minwidth => 40, -width => 60 ], "%s" ],
    via_bot_id      => [ [ -text => "Via"],         [ -minwidth => 30, -width => 45 ], sub { $tg->peer_name($_[0], 1) } ],
    fwd_from        => [ [ -text => "Forwarded from"],[ -minwidth=>60, -width => 99 ], \&_format_fwd_from, ],
    grouped_id      => [ [ -text => "grouped_id"],  [ -minwidth => 10, -width => 40 ], "%d" ],
# XXX reply_markup ???
);
setup_msglist($UI{tvMsgList});
presetup_tags($UI{txtMessage});

### GUI subs

sub btGetDlgs {
    $UI{lbNicklist}->delete(0, 'end');
    AE::log info => "btGetDlgs: invoke";
    $tg->invoke(
        Telegram::Messages::GetDialogs->new(
            offset_id => 0,
            offset_date => 0,
            offset_peer => Telegram::InputPeerEmpty->new,
            limit => -1
        ),
        sub {
            handle_dialogs(0, @_)
        }
    );
    $UI{btGetDlgs}->state("disabled");
    Tkx::after(5000, sub { $UI{btGetDlgs}->state("!disabled") });
}

sub btGetHistor {
    $statusText="No ID for listbox item", return unless $curNicklistId;

    my $peer = $tg->peer_from_id($curNicklistId);
    $UI{pbCountDone}->configure(-maximum => $sbLimit);
    $pbValue = 0;

    AE::log info => "btGetHistor: invoke $sbLimit on $curNicklistId";
    $tg->invoke( Telegram::Messages::GetHistory->new(
            peer => $peer,
            offset_id	=> 0,
            offset_date	=> 0,
            add_offset	=> 0,
            limit	=> $sbLimit,
            max_id	=> 0,
            min_id	=> 0,
            hash => 0
        ), sub {
            handle_history($peer, $_[0], $sbLimit) if $_[0]->isa('Telegram::Messages::MessagesABC');
        } );
    $UI{btGetHistor}->state("disabled");
}

sub btCachUsers {
    $UI{lbNicklist}->delete(0, 'end');
    my $cache = $tg->{session}{users};
    $UI{lbNicklist}->insert(0,
        sort map {
            defined $cache->{$_}{username}
                ? '@'. $cache->{$_}{username}
                : "$_ ".dutf8($cache->{$_}->{first_name}//"")." ".dutf8($cache->{$_}->{last_name} // "")
        } keys %$cache
    );
}

sub btCachChats {
    $UI{lbNicklist}->delete(0, 'end');
    my $cache = $tg->{session}{chats};
    $UI{lbNicklist}->insert(0,
        sort map {
            defined $cache->{$_}{username}
                ? '@'. $cache->{$_}{username}
                : "$_ ".dutf8($cache->{$_}{title}//"")
        } keys %$cache
    );
}

sub btSendMsg {
    $statusText="No ID for listbox item", return unless $curNicklistId;

    $tg->send_text_message(
        to => $curNicklistId,
        message => encode_utf8($msgToSend), # XXX utf8 here or in Telegram?
        ($cbReplyTo ? (reply_to_msg_id => $curSelMsgId) : ()),
    );
    $msgToSend = '';
}

sub onNicklistSelect {
    my @idx = $UI{lbNicklist}->curselection;
    return unless scalar @idx;
    if ($#idx==0) {
        my $val = $UI{lbNicklist}->get($idx[0]);
        if ($val =~ /^@/) {
            $curNicklistId = $tg->name_to_id($val);
        } elsif ($val =~ /^([0-9]+) /) {
            $curNicklistId = $tg->name_to_id($1);
        }
        $statusText = "Id for '$val' is $curNicklistId";
    }
    else {
        $statusText = "multiple selection currently not handled";
    }
}

sub onMsgListSelect {
    my $id = $UI{tvMsgList}->selection();
    my ($parent, $msgid) = split('/', $id);
    $curSelMsgId = $msgid;
    AE::log debug => "onMsgListSelect $id";
    $statusText = "parent=$parent msgid=".($curSelMsgId//"");

    render_msg($messageStore{$parent}->{$msgid}) if $msgid;
}

sub set_debug {
    $tg->{debug} = $opts->debug;
    AE::log note => "set_debug now $tg->{debug}";
}

sub about {
    Tkx::tk___messageBox(
        -parent => $UI{mw},
        -title => "About \u$0",
        -type => "ok",
        -icon => "info",
        -message => "$0 v$VERSION\n" .
                    "Copymiddle 2019 vgadfly & nuclight\n" .
                    "All rights reversed.",
    );
}

### semi-GUI subs

sub handle_dialogs
{
    my ($count, $ds) = @_;
    AE::log debug => "handle_dialogs $count";
    if ($ds->isa('Telegram::Messages::DialogsABC')) {
        my %users;
        my %chats;
        my $ipeer;

        $tg->_cache_users(@{$ds->{users}});
        $tg->_cache_chats(@{$ds->{chats}});
        for my $u (@{$ds->{users}}) {
            $users{$u->{id}} = $u;
        }
        for my $c (@{$ds->{chats}}) {
            $chats{$c->{id}} = $c;
        }
        handle_msg($_) for @{$ds->{messages}};
        for my $d (@{$ds->{dialogs}}) {
            $count++;
            my $peer = $d->{peer};
            if ($peer->isa('Telegram::PeerUser')) {
                my $user_id = $peer->{user_id};
                $peer = $users{$user_id};
                $UI{lbNicklist}->insert('end',
                    $peer->{username}
                    ? '@'.$peer->{username}
                    : "$user_id ".dutf8($peer->{first_name}//"")." ".dutf8($peer->{last_name} // "")
                );
                $ipeer = Telegram::InputPeerUser->new(
                    user_id => $user_id,
                    access_hash => $peer->{access_hash}
                );
            }
            if ($peer->isa('Telegram::PeerChannel')) {
                my $chan_id = $peer->{channel_id};
                $peer = $chats{$chan_id};
                $ipeer = Telegram::InputPeerChannel->new(
                    channel_id => $chan_id,
                    access_hash => $peer->{access_hash}
                );
                $UI{lbNicklist}->insert('end',
                    $peer->{username}
                    ? '@'.$peer->{username}
                    : "$chan_id ".dutf8($peer->{title}//"")
                );
            }
            if ($peer->isa('Telegram::PeerChat')){
                my $chat_id = $peer->{chat_id};
                $peer = $chats{$chat_id};
                $ipeer = Telegram::InputPeerChat->new(
                    chat_id => $chat_id,
                );
                $UI{lbNicklist}->insert('end', "$chat_id ".dutf8($peer->{title} // "")
                );
            }
        }
        if ($ds->isa('Telegram::Messages::DialogsSlice')) {
            AE::log debug => "handle_dialogs: invoke? $count";
            $tg->invoke(
                Telegram::Messages::GetDialogs->new(
                    offset_id => $ds->{messages}[-1]{id},
                    offset_date => $ds->{messages}[-1]{date},
                    offset_peer => Telegram::InputPeerEmpty->new,
                    #    offset_peer => $ipeer,
                    limit => -1
                ),
                sub { handle_dialogs($count, @_) }
            ) if ($count < $ds->{count});
        }
    }
}

sub handle_history
{
    my ($peer, $messages, $ptop, $left) = @_;
    AE::log debug => "handle_history ptop$ptop left=".($left//"");

    my $top = 0;
    $tg->_cache_users(@{$messages->{users}});
    for my $upd (@{$messages->{messages}}) {
        $top = $upd->{id};
        $left--;
        $pbValue++;
        if ($upd->isa('Telegram::Message')) {
            handle_msg($upd);
        }
    }
    if ($ptop == 0 or $top < $ptop && $left) {
        AE::log debug => "handle_history: invoke $top, $left";
        $tg->invoke( Telegram::Messages::GetHistory->new(
                peer => $peer,
                offset_id => $top,
                offset_date	=> 0,
                add_offset	=> 0,
                limit	=> $left,
                max_id	=> 0,
                min_id	=> 0,
                hash => 0
            ), sub {
                handle_history($peer, $_[0], $top, $left) if $_[0]->isa('Telegram::Messages::MessagesABC');
            } );
    }
    else {
        AE::log debug => "handle_history end left=$left pb=$pbValue";
        Tkx::after(1000, sub { $pbValue = 0;});
        $UI{btGetHistor}->state("!disabled");
    }
}

sub writeToLog {
    my ($log, $msg) = @_;
    #my $numlines = $log->index("end - 1 line");
    $log->configure(-state => "normal");
    $log->insert_end("\n") if $log->index("end-1c") != "1.0";
    $log->insert_end($msg);
    $log->see("end") if $logScrollEnd;
    $log->configure(-state => "disabled");
}

sub render {
    writeToLog($UI{txtUpdates}, dutf8($_[0]));
}

sub setup_msglist {
    my $tree = shift;

    # base roots
    $tree->insert("", "end", -id => "User", -text => "Private with users");
    $tree->insert("", "end", -id => "Chat", -text => "Group chats");
    $tree->insert("", "end", -id => "Channel", -text => "Channels & supergroups");

    # main tree column
    $tree->column('#0', -minwidth => 50, -stretch => 1);

    $tree->configure(-columns => [pairkeys @_columns]);
    foreach my $colspec (pairs @_columns) {
        my ($id, $spec) = @$colspec;
        $tree->column($id, @{ $spec->[1] });
        $tree->heading($id, @{ $spec->[0] });
    }
}

sub presetup_tags {
    my $text = shift;   # widget

    $text->tag_configure('Telegram::MessageEntityMention',      -foreground => 'red', );
    $text->tag_configure('Telegram::MessageEntityHashtag',      -foreground => 'green', );
    $text->tag_configure('Telegram::MessageEntityBotCommand',   -foreground => 'yellow', );
    $text->tag_configure('Telegram::MessageEntityUrl',          -foreground => 'blue', -underline => 1);
    $text->tag_configure('Telegram::MessageEntityTextUrl',      -foreground => 'blue', -underline => 1);#url
    $text->tag_configure('Telegram::TextUrl',                   -foreground => 'blue', -underline => 1);#url webpage_id 
    $text->tag_configure('Telegram::MessageEntityEmail',        -foreground => 'blue',);
    $text->tag_configure('Telegram::TextEmail',                 -foreground => 'blue',); # email
    $text->tag_configure('Telegram::MessageEntityBold',         -font => "-weight bold");
    $text->tag_configure('Telegram::TextBold',                  -font => "-weight bold");
    $text->tag_configure('Telegram::MessageEntityItalic',       -font => "-slant italic");
    $text->tag_configure('Telegram::TextItalic',                -font => "-slant italic");
    $text->tag_configure('Telegram::TextUnderline',             -underline => 1);
    $text->tag_configure('Telegram::TextStrike',                -overstrike=> 1);
    $text->tag_configure('Telegram::MessageEntityCode',         -foreground => 'red', -font => 'TkFixedFont');
    $text->tag_configure('Telegram::MessageEntityPre',          -font => 'TkFixedFont', ); # language
    $text->tag_configure('Telegram::TextFixed',                 -font => 'TkFixedFont', );
    $text->tag_configure('Telegram::MessageEntityMentionName',  -foreground => 'brown', ); # user_id
    $text->tag_configure('Telegram::InputMessageEntityMentionName', -foreground => '#8e68c9', ); # user_id
    $text->tag_configure('Telegram::MessageEntityPhone',        -foreground => '#69e34b', );
    $text->tag_configure('Telegram::MessageEntityCashtag',      -foreground => '#4e743f', );
    $text->tag_configure('Title',                               -font => "Helvetica 18 bold", );
    $text->tag_configure('Caption',                             -font => 'TkCaptionFont', );
    $text->tag_configure('Subtitle',                            -font => "Helvetica 16", );
    $text->tag_configure('Header',                              -font => "Helvetica 14 bold", );
    $text->tag_configure('Subheader',                           -font => "-weight bold", );
    $text->tag_configure('Paragraph',                           -font => "", );
    $text->tag_configure('Preformatted',                        -font => 'TkFixedFont', );
    $text->tag_configure('Footer',                              -font => 'TkSmallCaptionFont', );
    $text->tag_configure("MessageService",                      -background => "#a000a0");
}

sub render_msg {
    #@type Telegram::Message
    my $msg = shift;

    $UI{txtMessage}->configure(-state => "normal");
    $UI{txtMessage}->delete("1.0", "end");

    $UI{txtMessage}->insert_end(
        $msg->isa('Telegram::MessageService')
        ? (_message_action($msg->{action}), "MessageService")
        : dutf8($msg->{message})
    );

    if (exists $msg->{entities}) {
        foreach (@{ $msg->{entities} }) {
            $UI{txtMessage}->tag_add(
                ref $_,
                "1.0+" . $_->{offset} . "chars",
                "1.0+" . ($_->{offset} + $_->{length}) . "chars"
            );
        }
    }

    if (exists $msg->{media}) {
        my $sep = $UI{txtMessage}->new_ttk__separator(-orient => 'horizontal');
        $UI{txtMessage}->insert_end("\n");
        $UI{txtMessage}->window_create("end", -window => $sep, -stretch => 1); # FIXME need more geometry
        $UI{txtMessage}->insert_end("\n" . ref $msg->{media});

        if ($msg->{media}->isa('Telegram::MessageMediaWebPage')) {
            my $webpage = $msg->{media}->{webpage};

            if ($webpage->isa('Telegram::WebPage')) {
                for (qw/id type hash embed_width embed_height duration 
                    url site_name display_url description embed_url embed_type author/) {
                    if (defined $webpage->{$_}) {
                        $UI{txtMessage}->insert_end("\n$_:\t", "Telegram::TextBold");
                        $UI{txtMessage}->insert_end(dutf8($webpage->{$_}));
                    }
                }
                handle_photo($UI{txtMessage}, $webpage->{photo}) if $webpage->{photo};
                $UI{txtMessage}->insert_end(non_handled($webpage->{document}))
                    if $webpage->{document}; # TODO
                if (my $iv = $webpage->{cached_page}) {
                    if ($iv->isa('Telegram::PageABC')) {
                        my $photos = $iv->{photos};
                        push @$photos, $webpage->{photo} if $webpage->{photo};
                        for my $block (@{ $iv->{blocks} }) {
                            if ($block->isa('Telegram::PageBlockABC')) {
                                handle_pageblock($UI{txtMessage}, $block, $photos);
                            }
                            else {
                                $UI{txtMessage}->insert_end(non_handled($block));
                            }
                        }
                        handle_photo($UI{txtMessage}, $_) for @{ $iv->{photos} }; # XXX
                        $UI{txtMessage}->insert_end(non_handled($_)) for @{ $iv->{documents} }; # TODO
                    }
                    else {
                        $UI{txtMessage}->insert_end("\nhas Instant View (not handled yet) type=". ref $iv);
                    }
                }
            }
            else {
                $UI{txtMessage}->insert_end(non_handled($webpage));
            }
        }
    }

    $UI{txtMessage}->configure(-state => "disabled");
}

sub handle_photo {
    my ($tw, $photo) = @_;

    warn "not photo or empty", return unless $photo && $photo->isa('Telegram::Photo'); # XXX

    $tw->insert_end("\nPhoto: id=" . $photo->{id} . ($photo->{has_stickers} ? "[stickers]" : "")." ". _format_time($photo->{date}));

    for my $ps (@{ $photo->{sizes} }) {
        warn "non PhotoSize", next unless $ps->isa('Telegram::PhotoSizeABC');
        if ($ps->isa('Telegram::PhotoCachedSize') && $ps->{bytes}) {
            my $imgid = "pcs$photo->{id}";
            AE::log info => "creating image $imgid";
            Tkx::image_create_photo($imgid, -data => $ps->{bytes});
            $tw->image_create("end", -image => $imgid, -padx => 2, -pady => 2);
        }
        else {
            $tw->insert_end(non_handled($ps));
        }
    }
}

sub handle_richtext {
    my ($tw, $rtext, @tags) = @_;

    if ($rtext->isa('Telegram::TextPlain')) {
        $tw->insert_end(dutf8($rtext->{text}), (@tags ? join(' ', @tags) : ()));
    }
    elsif ($rtext->isa('Telegram::TextEmpty')) {
        return;
    }
    elsif ($rtext->isa('Telegram::TextConcat')) {
        handle_richtext($tw, $_, @tags) for @{ $rtext->{texts} };
        return;
    }
    else {
        handle_richtext($tw, $rtext->{text}, (@tags, ref($rtext)));
    }
}

sub handle_pageblock {
    my ($tw, $block, $photos) = @_;

    $tw->insert_end("\n");

    my $btype = ref $block;
    $btype =~ s/^Telegram::PageBlock//;

    my %actions = (
        Unsupported => sub { $tw->insert_end("[PageBlockUnsupported]\n"); },
        Title       => 'text',
        Subtitle    => 'text',
        Header      => 'text',
        Subheader   => 'text',
        Paragraph   => 'text',
        Preformatted=> 'text', # XXX language
        Footer      => 'text',
        AuthorDate => sub {
            handle_richtext($tw, $block->{author});
            $tw->insert_end(" " . _format_time($block->{published_date}) . "\n");
        },
        Divider     => sub {
            my $sep = $tw->new_ttk__separator(-orient => 'horizontal');
            $tw->insert_end("\n");
            $tw->window_create("end", -window => $sep, -stretch => 1) ; # FIXME need more geometry
            $tw->insert_end("\n");
        },
        Anchor      => sub { AE::log info => "anchor ".$block->{name} }, # FIXME
        List => sub {
            my $i = 0;
            for (@{ $block->{items} }) {
                $tw->insert_end("\n".($block->{ordered} ? $i++ . ". " : "\x{2022} "));
                handle_richtext($tw, $_);
            }
        },
        Blockquote  => sub {
            handle_richtext($tw, $block->{caption}, 'Caption');
            $tw->insert_end("\n");
            handle_richtext($tw, $block->{text}, 'Blockquote');
        },
        Pullquote   => sub {
            handle_richtext($tw, $block->{caption}, 'Caption');
            $tw->insert_end("\n");
            handle_richtext($tw, $block->{text}, 'Pullquote');
        },
        Photo       => sub {
            handle_richtext($tw, $block->{caption}, 'Caption');
            handle_photo($tw, grep { $_->{id} == $block->{photo_id} } @$photos);
        },
        Audio       => sub {
            handle_richtext($tw, $block->{caption}, 'Caption');
            $tw->insert_end(" [Audio id=$block->{audio_id}]");
        },
        Video       => sub {
            handle_richtext($tw, $block->{caption}, 'Caption');
            $tw->insert_end(" [Video id=$block->{video_id}]");
        },
        Cover       => sub {
            handle_pageblock($tw, $block->{cover}, $photos);
        },
        Collage     => sub {
            handle_richtext($tw, $block->{caption}, 'Caption');
            $tw->insert_end("\n");
            handle_pageblock($tw, $_, $photos) for @{ $block->{items} };
        },
        Slideshow   => sub {
            handle_richtext($tw, $block->{caption}, 'Caption');
            $tw->insert_end("\n");
            handle_pageblock($tw, $_, $photos) for @{ $block->{items} };
        },
        Channel     => sub {
            my $id = $block->{channel}->{id};   # TODO request (asynchronously) if not in cache
            $tw->insert_end('@'.$tg->peer_name($id, 1), 'Telegram::TextUrl');
        },
    );

    if (my $code = $actions{$btype}) {
        if (ref $code eq 'CODE') {
            &$code();
        } else {
            handle_richtext($tw, $block->{$code}, $btype);
        }
    }
    else {
        $tw->insert_end("[unhandled $btype ". non_handled($block) ."]\n");
        warn "unhandled $btype";
    }
}

sub _message_action {
    my $action = shift;
    my $ret;
    # TODO should be more friendly but that requires photo handling etc.
    my $class = ref $action;
    $ret = $class;
    $ret =~ s/Telegram::MessageAction//;
    local $Data::Dumper::Indent = 0;
    local $Data::Dumper::Quotekeys = 0;
    local $Data::Dumper::Bless = '';
    no strict 'refs';
    my (@keys, @vals);
    push(@keys, $_), push(@vals, $action->{$_}) for keys %{"$class\::FIELDS"};
    $ret .= " " . Data::Dumper->Dump(\@vals, \@keys) if @keys;
    return $ret;
}

sub handle_msg {
    my $msg = shift;

    AE::log trace => Dumper($msg);

    render_msg_console($msg);

    my $to_id;
    my $to = $msg->{to_id};
    # FIXME XXX TODO instead fix Telegram::message_from_update ! for all this block!
    $to = Telegram::PeerUser->new( user_id => $tg->{session}{self_id} )
        unless $to;
    my $to_type = ref $to;
    $to_type =~ s/^Telegram::Peer//;
    if (ref $to eq '' and $to =~ /^\d+$/) {
        $to_type = 'Chat';
        $to_id = $to;
    }
    elsif ($to->isa('Telegram::PeerChannel')) {
        $to_id = $to->{channel_id};
    } elsif ($to->isa('Telegram::PeerChat')) {
        $to_id = $to->{chat_id};
    } elsif ($to->isa('Telegram::PeerUser')) {
        $to_id = $to->{user_id};
    } else {
        AE::log alert => Dumper($msg);
        die 'unknown to_id ' . ref $to;
    }

    my ($id, $parent, $label, $textbegin);

    my $to_name = dutf8($tg->peer_name($to_id));
    my $from_name = defined $msg->{from_id} ? dutf8($tg->peer_name($msg->{from_id}, 1)) : '(noid)';

    # content part
    if ($msg->isa('Telegram::Message')) {
        $textbegin = $msg->{message};
    }
    elsif ($msg->isa('Telegram::MessageService')) {
        $textbegin = _message_action($msg->{action});
    }
    else {
        $textbegin = "[unhandled " . ref $msg . "]";
    }
    $textbegin = dutf8($textbegin);
    $textbegin = length $textbegin < 256 ? $textbegin : substr($textbegin, 0, 253)."...";
    $textbegin =~ s/\n/ /g;
    $textbegin = '[media]' if $textbegin eq '' and exists $msg->{media};

    AE::log debug => "$to_id '$to_name' '$from_name' $to_type txt=$textbegin";

    # first, entry for dialog in tree if not exists yet
    if ($to_type eq 'User' and not $msg->{out}) {
        $id = $msg->{from_id};
        $label = $from_name;
    }
    else {
        $id = $to_id;
        $label = $to_name;
    }
    $id = substr($to_type, 0, 4) . $id; # they are int, in theory collision possible

    AE::log debug => "id=$id dialabel=$label %s",
    $UI{tvMsgList}->insert($to_type, "end", -id => $id, -text => $label)
        unless $UI{tvMsgList}->exists($id);

    # then, entry for message itself, if not exists yet - but handle edits, too
    $parent = $id;
    $id = $msg->{id};

    $UI{tvMsgList}->insert($parent, "end", -id => "$parent/$id", -text => $textbegin)
        unless exists $messageStore{$parent}->{$id};

    # this sets values, which could be from edit, so proceed anyway
    my (@values, @tags);
    foreach my $tag (Tkx::SplitList($UI{tvMsgList}->tag_names)) {
        push @tags, $tag if exists $msg->{$tag};
    }
    push @tags, 'MessageService' if $msg->isa('Telegram::MessageService');

    foreach my $colspec (pairs @_columns) {
        my ($id, $spec) = @$colspec;
        my $val = '';
        if ($id eq 'from') { # XXX
            $val = $to_type eq 'Channel' && !defined $msg->{from_id} ? $to_name : $from_name;
        }
        elsif (exists $msg->{$id}) {    # NOTE both classes, action, too - not all keys avail
            my $f = $spec->[2];
            my $v = $msg->{$id};
            $val = dutf8( ref $f eq 'CODE' ? &$f($v) : sprintf($f, $v) );
        }
        push @values, $val;
    }
    $UI{tvMsgList}->item("$parent/$id", -values => [@values], (@tags ? (-tags => [@tags]) : ()));

    # be able to render it later, too
    $messageStore{$parent}->{$id} = $msg;
    render_msg($msg);   # render it, finally
}
### backend subs

sub non_handled ($) {
    my $obj = shift;
    my $class = ref($obj);
    my $ret = "not handled $class";
    no strict 'refs';
    warn "non-fields", return $ret unless keys %{"$class\::FIELDS"};
    $ret .= ":";
    $ret .= " $_=$obj->{$_}" for keys %{"$class\::FIELDS"};
    return "$ret\n";
}

sub dutf8 ($) { decode_utf8($_[0], Encode::WARN_ON_ERR|Encode::FB_PERLQQ) }

sub _format_time {
    my $ts = shift;

    # TODO take from app options/config
    return POSIX::strftime(
        (AE::now - $ts < 86400) ? "%H:%M:%S" : "%Y.%m.%d %H:%M",
        localtime $ts);
}

sub _format_fwd_from {
    my $fwh = shift;
    my $ret = "";
    if ($fwh->isa('Telegram::MessageFwdHeader')) {
        $ret .= $tg->peer_name($fwh->{from_id}, 1) if $fwh->{from_id};
        $ret .= " in " . $tg->peer_name($fwh->{channel_id}, 1) if $fwh->{channel_id};
        if ($opts->verbose) {
            $ret .= " @ " . _format_time($fwh->{date});
            for (qw(channel_post post_author saved_from_msg_id)) {
                $ret .= " $_=" . $fwh->{$_} if $fwh->{$_};
            }
            # TODO saved_from_peer
        }
    }
    return $ret;
}

sub report_update
{
    my ($upd) = @_;

    AE::log info => "report_update";
    if ($upd->isa('MTProto::RpcError')) {
        render("\rRpcError $upd->{error_code}: $upd->{error_message}");
    }
    if ($upd->isa('Telegram::Message')) {
        handle_msg($upd);
    }
    if ($upd->isa('Telegram::UpdateChatUserTyping')) {
        my $user = $tg->peer_name($upd->{user_id});
        my $chat = $tg->peer_name($upd->{chat_id});
        if (defined $user and defined $chat) {
            render("\n$user is typing in $chat...");
        }
    }
}

sub render_msg_console {
    #@type Telegram::Message
    my $msg = shift;

    AE::log info => "render_msg_console";
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

    if (exists $msg->{fwd_from}) {
        $add .= "[fwd from ";
        $add .= _format_fwd_from($msg->{fwd_from});
        $add .= "] ";
    }
    $add .= "[reply to " . $msg->{reply_to_msg_id} . "] "           if $msg->{reply_to_msg_id};
    $add .= "[mention] "                                            if $msg->{mentioned};
    $add .= "[via " . $tg->peer_name($msg->{via_bot_id}, 1) . "] "  if exists $msg->{via_bot_id};
    $add .= "[edited " . _format_time($msg->{edit_date}) . "] "     if exists $msg->{edit_date};
    $add .= "[media] "                                              if exists $msg->{media};
    $add .= "[reply_markup] "                                       if exists $msg->{reply_markup};

    my @t = localtime;
    render("[rcvd " . join(":", map {"0"x(2-length).$_} reverse @t[0..2]) . "] "
        . ($v ? "id=$msg->{id} ":"")
        . _format_time($msg->{date}) . " "
        . "$name$to: $add"
        . ($msg->isa('Telegram::MessageService') ? _message_action($msg->{action}) : $msg->{message})
        . "\n"
    );
}

sub save_session {
    AE::log note => "saving session file";
    store( $tg->{session}, $opts->session );
}

### now let's start everything

$tg->start;

Tkx::MainLoop();
AE::log note => "quittin..";
save_session();# not the best way to do it AFTER gui
