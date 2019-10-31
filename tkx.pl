#!/usr/bib/env perl5

my $VERSION = 0.01;

use Modern::Perl;
use utf8;

use Encode ':all';
use Carp;
use List::Util qw(max pairs pairkeys pairvalues);
use Config::Tiny;
use Storable qw( store retrieve freeze thaw );
use Getopt::Long::Descriptive;
use Class::Inspector;

use Tkx;

use AnyEvent;
use AnyEvent::Log;

push @AnyEvent::REGISTRY, [Tkx => AnyEvTkx::]; # XXX currently pure-perl only

use Telegram;

use Telegram::Messages::GetDialogs;
use Telegram::InputPeer;
use Telegram::Messages::GetHistory;
use Telegram::Messages::ReadHistory;
use Telegram::Channels::ReadHistory;

use Teleperl::Util qw(:DEFAULT get_AE_log_format_cb);
use Scalar::Util qw(blessed);
use Data::Dumper;

sub option_spec {
    [ 'verbose|v!'  => 'be verbose, by default also influences logger'      ],
    [ 'noupdate!'   => 'pass noupdate to Telegram->new'                     ],
    [ 'debug|d:+'   => 'pass debug (2=trace) to Telegram->new & AE::log'    ],
    [ 'session=s'   => 'name of session data save file', { default => 'session.dat'} ],
    [ 'config|c=s'  => 'name of configuration file', { default => "teleperl.conf" } ],
    [ 'logfile|l=s' => 'path to log file', { default => "tkx.log" }         ],
    [ 'theme=s'     => 'ttk::style theme to use'                            ],
    [ 'replay|r=s'  => 'enter offline mode & read from specified CBOR file' ],
}

### initialization

my ($opts, $usage);

eval { ($opts, $usage) = describe_options( '%c %o ...', option_spec() ) };
die "Invalid opts: $@\nUsage: $usage\n" if $@;

my $session = retrieve( $opts->session ) if -e $opts->session;
my $conf = Config::Tiny->read($opts->config);

$Data::Dumper::Indent = 1;
$AnyEvent::Log::FILTER->level(
    $opts->debug//0 >1 ? "trace" :
        $opts->{debug} ? "debug" :
            $opts->{verbose} ? "info" : "note"
);
$AnyEvent::Log::LOG->log_to_path($opts->logfile) if $opts->{logfile}; # XXX path vs file

# XXX workaround crutch of AE::log not handling utf8 & function name
install_AE_log_crutch();

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

#Tkx::package_require("style");  # able to look modern TODO what's this?
#Tkx::style__use("as", -priority => 70); # TODO what is it? discover later
if ($opts->{theme}) {
    eval {
        Tkx::ttk__style_theme_use($opts->theme);
    };
    die $@ . "\nAvailable theme names: " . Tkx::ttk__style_theme_names() . "\n"
        if $@;
}
# catch all non-our Perl's warns to log with stack trace
install_AE_log_SIG_WARN();
install_AE_log_SIG_DIE();

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
my $lboxNicks = '{Surprised to see} {nick list on right?} {} LOL {This is old tradition} {in IRC and Jabber}';
my $cmbxTLFunc;         # name of selected TL function
my @tlfunclist = sort map { $_->{func} } grep { exists $_->{func} and not exists $_->{bang} } values %Telegram::ObjTable::tl_type;
my $logScrollEnd = 1;   # keep scrolling on adding
my %messageStore;       # XXX refactor me!

## create widgets
$UI{mw}         = Tkx::widget->new("."); # main window

# top and bottom labels & btns
$UI{lblToolbar} = $UI{mw}->new_ttk__label( -text => "Here planned to be toolbar :)");
$UI{sbLimit}    = $UI{mw}->new_tk__spinbox(-from => 1, -to => 9999, -width => 4, -textvariable => \$sbLimit,
    -validate => 'key', -validatecommand => [sub { $_[0] =~ /^\d+$/ ? 1 : 0 }, Tkx::Ev("%P")]);
$UI{btGetHistor}= $UI{mw}->new_ttk__button(-text => "Get History", -command => \&btGetHistor);
$UI{btGetDlgs}  = $UI{mw}->new_ttk__button(-text => "Get dialogs", -command => \&btGetDlgs);
$UI{btCachUsers}= $UI{mw}->new_ttk__button(-text => "Cached users", -command => \&btCachUsers);
$UI{btCachChats}= $UI{mw}->new_ttk__button(-text => "Cached Chats", -command => \&btCachChats);
$UI{cbReplyTo}  = $UI{mw}->new_ttk__checkbutton(-variable => \$cbReplyTo, -onvalue => 1, -offvalue => 0,
                        -text => "Reply to selected message");
$UI{btMarkRead} = $UI{mw}->new_ttk__button(-text => "Mark read up to selected or all", -command => \&btMarkRead);
$UI{pbCountDone}= $UI{mw}->new_ttk__progressbar(-length => 200, -mode => 'determinate', -variable => \$pbValue);
$UI{lblSendMsg} = $UI{mw}->new_ttk__label( -text => "Enter message:");
$UI{enSendMsg}  = $UI{mw}->new_ttk__entry(-width => 80, -textvariable => \$msgToSend);
$UI{btSendMsg}  = $UI{mw}->new_ttk__button(-text => "Send message", -command => \&btSendMsg);
$UI{lblStatus}  = $UI{mw}->new_ttk__label(-width => 170, -textvariable => \$statusText, -anchor => "w");
$UI{sizeGrip}   = $UI{mw}->new_ttk__sizegrip;

# parts in frames
$UI{panw}       = $UI{mw}->new_ttk__panedwindow(-orient => 'horizontal');
$UI{frmNicklist}= $UI{panw}->new_ttk__frame();
$UI{panControl} = $UI{panw}->new_ttk__panedwindow(-orient => 'vertical');
$UI{panMessages}= $UI{panw}->new_ttk__panedwindow(-orient => 'vertical');
$UI{frmUpdates} = $UI{panControl}->new_ttk__frame();
$UI{frmInvoke}  = $UI{panControl}->new_ttk__labelframe(-text => "API raw query constructor");
$UI{frmMsgList} = $UI{panMessages}->new_ttk__frame();
$UI{frmMessage} = $UI{panMessages}->new_ttk__frame();
$UI{tvMsgList}  = $UI{frmMsgList}->new_ttk__treeview(-selectmode => "browse"); # setup others later
$UI{sbhMsgList} = $UI{frmMsgList}->new_ttk__scrollbar(-command => [$UI{tvMsgList}, "xview"], -orient => "horizontal");
$UI{sbvMsgList} = $UI{frmMsgList}->new_ttk__scrollbar(-command => [$UI{tvMsgList}, "yview"], -orient => "vertical");
$UI{cmbTLFunc}  = $UI{frmInvoke}->new_ttk__combobox(-state => "readonly", -textvariable => \$cmbxTLFunc,
    -values => [@tlfunclist]);
$UI{trcReqArgs} = $UI{frmInvoke}->new_treectrl(-showroot => 0, -showrootbutton => 0, -showrootlines => 0, -selectmode => 'single');
$UI{btReqArrAdd}= $UI{frmInvoke}->new_ttk__button(-text => "Add \@{}", -command => \&btReqArrAdd);
$UI{btReqArrDel}= $UI{frmInvoke}->new_ttk__button(-text => "Del \@{}", -command => \&btReqArrDel);
$UI{btInputPeer}= $UI{frmInvoke}->new_ttk__button(-text => "InputPeer/User", -command => \&btInputPeer);
$UI{btInvoke}   = $UI{frmInvoke}->new_ttk__button(-text => "Invoke!", -command => \&btInvoke);
$UI{txtUpdates} = $UI{frmUpdates}->new_tk__text(-state => "disabled", -width => 39, -height => 26, -wrap => "char");
$UI{sbhUpdates} = $UI{frmUpdates}->new_ttk__scrollbar(-command => [$UI{txtUpdates}, "xview"], -orient => "horizontal");
$UI{sbvUpdates} = $UI{frmUpdates}->new_ttk__scrollbar(-command => [$UI{txtUpdates}, "yview"], -orient => "vertical");
$UI{txtMessage} = $UI{frmMessage}->new_tk__text(-state => "disabled", -width => 80, -height => 24, -wrap => "word", -font => 'TkTextFont');
$UI{sbvMessage} = $UI{frmMessage}->new_ttk__scrollbar(-command => [$UI{txtMessage}, "yview"], -orient => "vertical");
$UI{lbNicklist} = $UI{frmNicklist}->new_tk__listbox(-listvariable => \$lboxNicks, -height => 43);
$UI{sbhNicklist}= $UI{frmNicklist}->new_ttk__scrollbar(-command => [$UI{lbNicklist}, "xview"], -orient => "horizontal");
$UI{sbvNicklist}= $UI{frmNicklist}->new_ttk__scrollbar(-command => [$UI{lbNicklist}, "yview"], -orient => "vertical");
$UI{panw}->add($UI{panControl}, -weight => 2);
$UI{panw}->add($UI{panMessages}, -weight => 4);
$UI{panw}->add($UI{frmNicklist}, -weight => 3);
$UI{panMessages}->add($UI{frmMsgList}, -weight => 4);
$UI{panMessages}->add($UI{frmMessage}, -weight => 3);
$UI{panControl}->add($UI{frmInvoke}, -weight => 1);
$UI{panControl}->add($UI{frmUpdates}, -weight => 2);
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
$UI{btMarkRead}->g_grid( -column => 3, -row => 2, -sticky => "nwes", -pady => 1, -padx => 5);
$UI{pbCountDone}->g_grid(-column => 4, -row => 2, -columnspan => 3, -sticky => "nes",  -pady => 1, -padx => 5);
$UI{lblSendMsg}->g_grid( -column => 0, -row => 3, -columnspan => 1, -sticky => "nwes", -pady => 5, -padx => 5);
$UI{enSendMsg}->g_grid(  -column => 1, -row => 3, -columnspan => 5, -sticky => "nwes", -pady => 5, -padx => 5);
$UI{btSendMsg}->g_grid(  -column => 6, -row => 3, -sticky => "nwes", -pady => 5, -padx => 5);

$UI{panw}->g_grid(       -column => 0, -row => 1, -columnspan => 8, -sticky => "nwes", -pady => 1, -padx => 5);

$UI{lblStatus}->g_grid(  -column => 0, -row => 4, -columnspan => 8, -sticky => "nwes", -padx => 1);
$UI{sizeGrip}->g_grid(   -column => 7, -row => 4, -sticky => "es");

# inside Control pane
# inside constructor frame
$UI{cmbTLFunc}->g_pack(  -side => "top",  -fill => "x", -expand => "no",  -pady => 2, -padx => 2);
$UI{trcReqArgs}->g_pack( -side => "top",  -fill => "both", -expand => "yes", -pady => 2, -padx => 2);
$UI{btReqArrAdd}->g_pack(-side => "left", -pady => 2, -padx => 2);
$UI{btReqArrDel}->g_pack(-side => "left", -pady => 2, -padx => 2);
$UI{btInputPeer}->g_pack(-side => "left", -expand => "yes", -pady => 2, -padx => 2);
$UI{btInvoke}->g_pack(  -side => "right", -pady => 2, -padx => 2);

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
$UI{menuFile}->add_command(-label => "Read CBOR binary log...", -command => sub { process_cbor(Tkx::tk___getOpenFile()); });
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
$UI{cmbTLFunc}->g_bind("<<ComboboxSelected>>", \&onTLFuncSelected); # see also there

# set tags for messages and their list
$UI{tvMsgList}->tag_configure("out",            -background => "lightyellow");
$UI{tvMsgList}->tag_configure("mentioned",      -font => "-underline 1");
$UI{tvMsgList}->tag_configure("silent",         -font => "-overstrike 1");
$UI{tvMsgList}->tag_configure("MessageService", -foreground => "#a000a0");

our @_columns = (
    id              => [ [ -text => "Msg ID" ],     [ -minwidth => 30, -width => 50 ], "%d" ],
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
setup_treqargs($UI{trcReqArgs});

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

sub btMarkRead {
    $statusText="No ID for listbox item", return unless $curNicklistId;

    my $peer = $tg->peer_from_id($curNicklistId);

    if ($peer->isa('Telegram::InputPeerChannel')) {
        $tg->invoke( Telegram::Channels::ReadHistory->new(
                channel => $peer,
                max_id => $curSelMsgId // 0,
        ), sub { render(Dumper @_) } );
    }
    else {
        $tg->invoke( Telegram::Messages::ReadHistory->new(
                peer => $peer,
                max_id => $curSelMsgId // 0,
        ), sub { render(Dumper @_) } );
    }
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

    render_msg($UI{txtMessage}, $messageStore{$parent}->{$msgid}) if $msgid;
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

### raw API request constructor treectrl

## We have 3 item types:
# 1) leaf: always builtin type, edit widgets allowed only here
# 2) HASH: children are fields, each can have own type
# 3) ARRAY: children are indexes, each always inherits type of parent item
# ...but for 2 and 3, real type of child may be a choice from a small list:
# descendants of base class (polymorphic).
# Moreover, things are complicated by optional fields.
# So, we must use custom item states.
sub setup_treqargs {
    my $trc = shift;    # tree control

    # treectrl needs to setup *everything* - even most basic things!
    # XXX so take colors from existing listbox
    my $SystemButtonFace    = $UI{lbNicklist}->cget('-highlightbackground');
    my $SystemHighlight     = $UI{lbNicklist}->cget('-selectbackground');
    my $SystemHighlightText = $UI{lbNicklist}->cget('-selectforeground');

    # a hack: instead of real widget, steal checkbox GIFs from demo :)
   Tkx::image_create_photo('checked', -data => q{
R0lGODlhDQANABEAACwAAAAADQANAIEAAAB/f3/f39////8CJ4yPNgHtLxYYtNbIbJ146jZ0gzeC
IuhQ53NJVNpmryZqsYDnemT3BQA7
   });
   Tkx::image_create_photo('unchecked', -data => q{
R0lGODlhDQANABEAACwAAAAADQANAIEAAAB/f3/f39////8CIYyPNgHtLxYYtNbIrMZTX+l9WThw
ZAmSppqGmADHcnRaBQA7
    });

    ## custom states - for per-state element visibility options
    # note next 3 states are named after keys in %TYPES
    $trc->item_state_define('vector');  # ARRAY nodes - 'vector' in schema
    $trc->item_state_define('optional');# field may be absent - to correctly draw "checkbox"
    $trc->item_state_define('builtin'); # value is editable only for builtins
    # our GUI states
    $trc->item_state_define('CHECK');   # "checkbox" is set in optional
    $trc->item_state_define('EDIT');    # while widget is displayed during editing
    $trc->item_state_define('MenuType');# whether has multiple values in Type column

    # elements
    $trc->element_create(elemTxtName => 'text', -fill => [$SystemHighlightText => 'selected focus']);
    $trc->element_create(elemTxtCount => 'text', -fill => 'blue');
    $trc->element_create(elemTxtValue => 'text', -lines => 1); # NOTE lines - for tk::entry, not text!
    $trc->element_create(elemRectSel => 'rect',
        -fill => [$SystemHighlight => 'selected focus', gray => 'selected !focus'],
        -showfocus => 'yes');
    $trc->element_create(elemImgCheck => 'image', -image => 'checked CHECK unchecked {}');
    $trc->element_create(elemWidget => 'window', -destroy => 'yes', -draw => 'yes MenuType no {}');

    ## styles

    # for field/index - elemTxtCount element is visible if ARRAY (vector) node
    # visual selection for element via elemRectSel (elemTxtName only) also here
    $trc->style_create('styField');
    $trc->style_elements(styField => [qw{elemRectSel elemTxtName elemTxtCount}]);
    $trc->style_layout(styField => 'elemTxtName', -padx => 2, -expand => 'ns', -squeeze => 'x');
    $trc->style_layout(styField => 'elemTxtCount', -expand => 'ns', -visible => 'yes vector no {}');
    $trc->style_layout(styField => 'elemRectSel', -union => 'elemTxtName', -iexpand => 'ns', -ipadx => 2);

    # plain text display
    $trc->style_create('styPlain');
    $trc->style_elements(styPlain => 'elemTxtValue');

    # plain text display
    $trc->style_create('styType');
    $trc->style_elements(styType => 'elemTxtValue elemWidget');
    $trc->style_layout(styType => 'elemTxtValue', -visible => 'no MenuType'); # see below
    $trc->style_layout(styType => 'elemWidget',  -squeeze => 'xy'); # see below

    # optional - bit number and a "checkbox"
    $trc->style_create('styOptFlag');
    $trc->style_elements(styOptFlag => 'elemImgCheck elemTxtValue');
    $trc->style_layout(styOptFlag => 'elemImgCheck', -ipadx => 2, -visible => 'yes optional no {}');
    $trc->style_layout(styOptFlag => 'elemTxtValue'); # XXX pad?

    # value editor
    $trc->style_create('styValue');
    $trc->style_elements(styValue => 'elemTxtValue elemWidget');
    $trc->style_layout(styValue => 'elemTxtValue', -draw => 'no EDIT'); # see below
# $trc->style_layout(styValue => 'elemWidget', -union => 'elemTxtValue'); # XXX was masking textfor filelist editing

    # (ab)use Tkx-provided instance state for each widget pathname
    my $vars = $trc->_data();

    # column field names as in generator, assign default item styles where possible
    $vars->{hColumn}{name}    = $trc->column_create(-text => "Field/index", -itemstyle => 'styField');
    $vars->{hColumn}{type}    = $trc->column_create(-text => "Type", -squeeze => "yes", -itemstyle => 'styType');
    $vars->{hColumn}{optional}= $trc->column_create(-text => "?", -itemstyle => "styOptFlag", -itembackground => 'linen white');
    $vars->{hColumn}{vector}  = $trc->column_create(-text => '@[]', -itemstyle => 'styPlain');
    $vars->{hColumn}{value}   = $trc->column_create(-text => 'Value', -itemstyle => 'styValue');

    $trc->configure(-treecolumn => $vars->{hColumn}{name});

    # allow reordering columns :)
    $trc->header_dragconfigure(-enable => 1);
    $trc->notify_install('<ColumnDrag-receive>');
    $trc->notify_bind('MyTag', '<ColumnDrag-receive>', '%T column move %C %b');

    ## XXX NOTE semi-HACK! For being able to edit values in-place, we're
    ## (ab)using tktreectrl's library/filelist-bindings.tcl here, though which
    ## is itself a semi-hack made for Explorer demos, so we need to carefully
    ## place hack on hack :) Thus, using knowledge of it's source, we disable
    ## it's unneeded (made specifically for file browser) parts and arrogantly
    ## replace some other internal pieces with our code on the fly.

    # elements where secondary (non-double!) click will call editing
    # NOTE that _treq_one_level will not fill with any text for non-builtin
    # typss in Value column, so user just won't be able to take aim and hit
    # the element to fire editing :)
    Tkx::TreeCtrl__SetEditable($trc, [
            [$vars->{hColumn}{value}, 'styValue', 'elemTxtValue']
        ]);

    # Tkx::TreeCtrl__SetDragImage uses DirCnt variable for file browser :( so we
    # just disable drag completely, it's non of much use on HASHes, though
    Tkx::bind('TreeCtrlFileList', '<Button1-Motion>', '');

    # where TreeCtrlFileList, which is breaking tag, will allow clicks for us
    Tkx::TreeCtrl__SetSensitive($trc, [
            [ $vars->{hColumn}{name},     'styField', 'elemTxtName'],
            [ $vars->{hColumn}{type},     'styType',  'elemTxtValue'],
            [ $vars->{hColumn}{optional}, 'styOptFlag', 'elemTxtValue', 'elemImgCheck'],
            [ $vars->{hColumn}{vector},   'styPlain', 'elemTxtValue'],
            [ $vars->{hColumn}{value},    'styValue', 'elemTxtValue'],
        ]);
    # enable filelist-bindings.tcl for us
    $trc->g_bindtags(Tkx::linsert($trc->g_bindtags, 1, 'TreeCtrlFileList')); # save one var/splice :)

    # our checkbox emulation is earlier in binding tags
    $trc->g_bind('<ButtonPress-1>' => [sub {
                my ($x, $y) = @_;
                my $ids = $trc->identify($x, $y);
                return unless $ids =~ /^item\s.+\scolumn\s.+\selem\s.+$/;
                my %id = Tkx::SplitList($ids);
                if ($id{column} eq $vars->{hColumn}{optional} and $id{elem} eq 'elemImgCheck') {
                    $trc->item_state_set($id{item}, '~CHECK');
                }
            }, Tkx::Ev('%x', '%y')]
        );

    # allow events to be fired
    $trc->notify_install('<Edit-begin>');
    $trc->notify_install('<Edit-accept>');
    $trc->notify_install('<Edit-end>');

    # we could just use 3 lines if all we need were just 'string' type...
    # like this:
    #   $trc->notify_bind($trc, '<Edit-begin>', '%T item state set %I ~EDIT');
    #   $trc->notify_bind($trc, '<Edit-accept>', '%T item element configure %I %C %E -text %t');
    #   $trc->notify_bind($trc, '<Edit-end>', '%T item state set %I ~EDIT');
    # were we toggle EDIT state in begin and end of edit for text element to be
    # not drawn in EDIT state, to not get in our way...
    # ...but we'll have different widget types, and two possible columns for
    # editing (type and value), so `forcolumn` instead of entire item's state

    # For most builtin types, we'll still have entry. It would be better to have
    # e.g. spinbox for integer and checkbox for boolean, but due to laziness and
    # visual constraints (these spinbox buttons and borders will greatly
    # increase item height which is not good if tree is big) we just change
    # validation
    my %validatecmd = (
        string	=> sub { 1 },
        bytes	=> sub { 1 },
        int	=> sub { $_[0] =~ /^\s*[-+]?\d{1,10}\s*$/  ? 1 : 0 },
        nat	=> sub { $_[0] =~ /^\s*\d+\s*$/            ? 1 : 0 },
        long	=> sub { $_[0] =~ /^\s*[-+]?\d{1,19}\s*$/  ? 1 : 0},
        int128	=> sub { 1 },   # XXX
        int256	=> sub { 1 },   # XXX
        double	=> sub { $_[0] =~ /^\s*[-+]?(\d+|\.\d+|\d+\.\d*)([eE][-+]?\d+)?\s*$/ ? 1 : 0},
        Bool	=> sub { 1 },   # will be interpreted on invoke according to Perl rules
        true	=> sub { Tkx::i::call($_[-1], "insert", 0, "LOL WAT? it will be always true"); 1 },
        date	=> sub { 1 },   # XXX wat? haven't seen such in schema
    );
    $trc->notify_bind($trc, '<Edit-begin>' => [sub {
                my ($entry, $I, $C, $E) = @_;
                $trc->item_state_forcolumn($I, $C, '~EDIT');
                my $type = $trc->item_text($I, $vars->{hColumn}{type});
                no strict 'refs';
                &{"Tkx::${entry}_delete"}(1 => 'end') # fix too much spaces
                    if &{"Tkx::${entry}_get"}() =~ /^\s+$/;
                &{"Tkx::${entry}_configure"}(
                    -validate => 'key',
                    -validatecommand => [$validatecmd{$type}, Tkx::Ev("%P"), $entry]);
            }, Tkx::Ev('%T.entry', '%I', '%C', '%E')]
        );
    $trc->notify_bind($trc, '<Edit-accept>', '%T item element configure %I %C %E -text %t');
    $trc->notify_bind($trc, '<Edit-end>' => [sub {
                my ($entry, $I, $C, $E) = @_;
                $trc->item_state_forcolumn($I, $C, '~EDIT');
                # no matter what type was, will be recreated as entry next time
                Tkx::destroy($entry) if Tkx::i::call("winfo", "exists", $entry);
            }, Tkx::Ev('%T.entry', '%I', '%C', '%E')]
        );

    # link Perl hash <-> Tcl array for storing menu states, using stringification
    $vars->{MenuType} = {};
    tie %{$vars->{MenuType}}, "Tcl::Var", Tkx::i::interp(), "::perl::MenuType$trc";

    $vars->{MenuTypeCnt} = {};  # counter closure XXX FIXME
    # use the almighty Tcl's trace command!
    Tkx::trace_add_variable("::perl::MenuType$trc", [qw(array write)], sub {
        my ($varname, $key, $op) = @_;
        return unless $op eq 'write';
        $vars->{MenuTypeCnt}{$key}++;
        # here we have already written (new) value, but what about setting
        # first time? and selecting already selected? we solve both by comparing
        # with text element, which is set for us before menu creation, and which
        # we'll also set
        if ($trc->item_id($key)) {  # check item existence
    say "fired $varname, $key, $op|${$vars->{MenuType}}{$key}";
            if ($trc->item_text($key, $vars->{hColumn}{type}) ne ${$vars->{MenuType}}{$key}) {
    say "ne";
                # clear children and populate with new type
                $trc->item_delete($_) for Tkx::SplitList($trc->item_children($key));
                _treq_one_level($trc, ${$vars->{MenuType}}{$key}, $key);
                $trc->item_expand($key);

                # finally remember current value for future calls
                $trc->item_text($key, $vars->{hColumn}{type}, ${$vars->{MenuType}}{$key});
            }
        }
    });

    # and finally, process current selection to disable/enable buttons etc.
    $trc->notify_bind($trc, '<Selection>' => [sub {
            my ($c, $D, $S) = @_;
            die "misconfiguration! only 1 item in selection supports, not $c" if $c > 1;
            $vars->{Selection} = $S;
            my $parent = $c ? $trc->item_parent($S) : '';
            $UI{btReqArrAdd}->state(
                $c && (
                $trc->item_state_get($S, 'vector') || $trc->item_state_get($parent, 'vector'))
                    ? "!disabled"
                    : "disabled"
            );
            $UI{btReqArrDel}->state(
                $c && $trc->item_state_get($parent, 'vector')
                    ? "!disabled"
                    : "disabled"
            );
            $UI{btInputPeer}->state(
                $c
                && ! $trc->item_state_get($S, 'builtin')
                && ! $trc->item_state_get($S, 'vector')
                && $trc->item_text($S, $vars->{hColumn}{type}) =~ /Input/
                    ? "!disabled"
                    : "disabled"
            );
        }, Tkx::Ev('%c', '%D', '%S')]
    );
}

## Create one item, fill it's fields and return it's handle
# naming and positioning in tree must be done by caller
# %$TYPE is hash entry value for one field in schema
sub _treq_one_item {
    my ($trc, $name, $TYPE) = @_;
    my $vars = $trc->_data();

    my $hItem = $trc->item_create(
        $TYPE->{vector} || !$TYPE->{builtin}
            ? (-button => "yes")
            : ()
    );
    # set states according to generated type options
    $trc->item_state_set($hItem, [map { ($TYPE->{$_} ? '' : '!').$_ } qw(vector optional builtin)]);

    # set text fields
    $trc->item_text($hItem, $vars->{hColumn}{name}, $name);
    $trc->item_text($hItem, $vars->{hColumn}{type}, $TYPE->{type} =~ s/Telegram:://r);
    $trc->item_element_configure(
        $hItem, $vars->{hColumn}->{optional}, 'elemTxtValue',
        -text => (split(/\./, $TYPE->{optional}))[1])       if $TYPE->{optional};
    $trc->item_text($hItem, $vars->{hColumn}{vector}, '@')  if $TYPE->{vector};
    $trc->item_element_configure(
        $hItem, $vars->{hColumn}->{value}, 'elemTxtValue',
        -text => (' 'x 10), -font => '') if $TYPE->{builtin}; # XXX

    # populate children if possible & handle polymorphic
    unless ($TYPE->{vector} || $TYPE->{builtin}) {
        # detect if class is polymorphic...
        my ($poly, @subc);
        $poly = eval {
            no strict 'refs';
            require Class::Inspector->filename($TYPE->{type});
            ${"$TYPE->{type}ABC::VERSION"}
        };
        # ...but it may have only one subclass...
        if ($poly) {
            my $sc = Class::Inspector->subclasses($TYPE->{type}.'ABC');
            @subc = @$sc;
        }
        # ...in which case giving a choice is meaningless
        if (@subc > 1) {    # make menu
            $trc->item_state_set($hItem, 'MenuType');
            $trc->item_text($hItem, $vars->{hColumn}{type}, $subc[0]); # for trace
            my $path = "$trc.m$hItem";
            my $menu = Tkx::tk___optionMenu($path, "::perl::MenuType$trc($hItem)", @subc);
            # make it taking less space on screen, though a little ugly
            Tkx::i::call($path, "configure", -padx => 0, -pady => 0, -borderwidth => 0);
            $trc->item_element_configure($hItem, $vars->{hColumn}->{type}, 'elemWidget',
                -window => $path
            );
            # TODO
        }
        else {  # only one class
            # NOTE it may be different from base class
            _treq_one_level($trc, $poly ? $subc[0] : $TYPE->{type}, $hItem);
        }
    }

    return $hItem;
}

## Populate fields of one hash
# 'require' must be done for us by caller
sub _treq_one_level {
    my ($trc, $class, $parent) = @_;
    my $vars = $trc->_data();

    no strict 'refs';
    # sort as in schema XXX kludge 
    my @fields = sort {
            ${"$class\::FIELDS"}{$a} <=> ${"$class\::FIELDS"}{$b}
        } keys %{"$class\::FIELDS"};
    my %TYPES = %{"$class\::TYPES"};

    # filter out 'flags'
    # XXX we don't handle multiple such though they wasn't seen in real schemas
    my $optional = (map {
            exists $TYPES{$_}->{optional}
                ? (split(/\./, $TYPES{$_}->{optional}))[0]
                : ()
        } keys %TYPES)[0] // '';
    @fields = grep { $_ ne $optional } @fields;

    for my $name (@fields) {
        my $hItem = _treq_one_item($trc, $name, $TYPES{$name});

        $trc->item_collapse($hItem);

        $trc->item_lastchild($parent => $hItem);
    }
}

my $_cmbxJump = '';     # type to navigate prefix/substring
sub onTLFuncSelected {
    $_cmbxJump = '';
    my $tltyp = (grep { exists $_->{func} and $_->{func} eq $cmbxTLFunc }
        values %Telegram::ObjTable::tl_type
    )[0];
    my $class = $tltyp->{class};
    require $tltyp->{file};
    my $_nargs = do { no strict 'refs'; grep(!/^flags$/, keys %{"$class\::FIELDS"})};

    $UI{cmbTLFunc}->selection_clear();  # make it visually less odd
    $UI{trcReqArgs}->g_focus();         # prevent accidental changing after select
    $statusText="selected $class ($_nargs non-flags args) returns @{[$tltyp->{vector} ? 'vector of' : '']} $tltyp->{returns}";

    # clear all
    $UI{trcReqArgs}->item_delete($_)
        for Tkx::SplitList($UI{trcReqArgs}->item_children("root"));

    # buttons will be re-enabled by selection
    $UI{btReqArrAdd}->state("disabled");
    $UI{btReqArrDel}->state("disabled");
    $UI{btInputPeer}->state("disabled");

    # populate immediate arguments
    _treq_one_level($UI{trcReqArgs}, $class, "root");
}

# pressing letters to jump in the long list - first by prefix, then any substring
# FIXME it works strange and only in collapsed state
for my $key ('a'..'z', 'A'..'Z', '.', '_') {
    $UI{cmbTLFunc}->g_bind($key, sub {
            $_cmbxJump .= $key;
            my $cur = $UI{cmbTLFunc}->current();
            my $new = -1;
            foreach my $i (0 .. $#tlfunclist) {
                $new = $i, last if $tlfunclist[$i] =~ /^$_cmbxJump/;
            }
            unless ($new > 0) {
                foreach my $i ($cur .. $#tlfunclist) {
                    $new = $i, last if $tlfunclist[$i] =~ /$_cmbxJump/;
                }
            }
            $UI{cmbTLFunc}->current($new) if $new > 0 && $new != $cur;
        });
}

sub _treq_renumber {
    my ($trc, $parent, $hItem) = @_;
    my $vars = $trc->_data();

    my $numc = $trc->item_numchildren($parent);
    # update counter
    $trc->item_element_configure($parent,
        $vars->{hColumn}{name}, 'elemTxtCount',
        -text => "($numc)");

    # if nothing to do
    return unless $numc;
    if ($numc == 1) {
        $trc->item_text($trc->item_firstchild($parent), $vars->{hColumn}{name}, '0');
        return;
    }

    my $idx = 0;
    for my $id (Tkx::SplitList($trc->item_children($parent))) {
        $trc->item_text($id, $vars->{hColumn}{name}, $idx++);
    }
}

sub btReqArrAdd {
    my $vars = $UI{trcReqArgs}->_data();
    my $trc  = $UI{trcReqArgs};

    my $select = $vars->{Selection};
    my $parent = $trc->item_state_get($select, 'vector')
        ? $select
        : $trc->item_parent($select);
    die "parent $parent is not vector!"
        unless $trc->item_state_get($parent, 'vector');

    my $newIdx = ($parent == $select) ? 0 : 1 + $trc->item_text($select, $vars->{hColumn}{name});
    my $builtin = $trc->item_state_get($parent, 'builtin');

    my $class = $trc->item_text($parent, $vars->{hColumn}{type});
    $class = 'Telegram::' . $class unless $class =~ /^Telegram::/ or $builtin;

    # child of vector will never be vector or optional, inherit other properties
    my $type = {
        type    => $class,
        builtin => $builtin,
        vector  => 0,
    };

    my $hItem = _treq_one_item($trc, $newIdx, $type);

    # insert to tree
    if ($parent == $select) {
        $trc->item_lastchild($parent => $hItem);
    }
    else {
        $trc->item_nextsibling($select => $hItem);
    }

    _treq_renumber($trc, $parent, $hItem);    # fix shifted indexes
    $trc->item_expand($parent);
}

sub btReqArrDel {
    my $vars = $UI{trcReqArgs}->_data();
    my $trc  = $UI{trcReqArgs};
    my $select = $vars->{Selection};
    my $parent = $trc->item_parent($select);
    die "parent $parent is not vector!"
        unless $trc->item_state_get($parent, 'vector');
    $trc->item_delete($select);
    _treq_renumber($trc, $parent);    # fix shifted indexes
}

sub btInputPeer {
    $statusText="No ID for listbox item", return unless $curNicklistId;

    my $vars = $UI{trcReqArgs}->_data();
    my $trc  = $UI{trcReqArgs};
    my $peer = $tg->peer_from_id($curNicklistId);

    my $select = $vars->{Selection};

    for my $child (Tkx::SplitList($trc->item_children($select))) {
        next unless $trc->item_state_get($child, 'builtin');
        my $name = $trc->item_text($child, $vars->{hColumn}{name});
        for (keys %$peer) {
            if ($_ eq $name) {
                $trc->item_text($child, $vars->{hColumn}{value}, $peer->{$name});
            }
        }
    }
}

sub _treq_walk {
    my ($trc, $parent) = @_;
    my $vars = $trc->_data();

    my @pairs = ();

    for my $child (Tkx::SplitList($trc->item_children($parent))) {
        next if $trc->item_state_get($child, 'optional') && !$trc->item_state_get($child, 'CHECK');
        my $name = $trc->item_text($child, $vars->{hColumn}{name});
        my $type = $trc->item_text($child, $vars->{hColumn}{type});
        my $value = $trc->item_text($child, $vars->{hColumn}{value});
        if ($trc->item_state_get($child, 'builtin')) {
            $value =~ s/^\s+//;
            $value =~ s/\s+$//;
            push @pairs, $name => $value;
        }
        elsif ($trc->item_state_get($child, 'vector')) {
            push @pairs, $name => [ pairvalues _treq_walk($trc, $child) ];
        }
        else { # class
            $type = 'Telegram::' . $type unless $type =~ /^Telegram::/;
            push @pairs, $name => $type->new( _treq_walk($trc, $child) );
        }
    }

    return @pairs;
}

sub btInvoke {
    my $vars = $UI{trcReqArgs}->_data();
    my $trc  = $UI{trcReqArgs};

    my $tltyp = (grep { exists $_->{func} and $_->{func} eq $cmbxTLFunc }
        values %Telegram::ObjTable::tl_type
    )[0];
    my $class = $tltyp->{class};
    my $request = $class->new(_treq_walk($trc, 'root'));

    # XXX temporary instead of real invoke
    my $dump = Dumper($request);
    AE::log info => "tg->invoke $dump";
    render($dump);

    $statusText="like invoked ^)";
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

    # TODO font_actual (especially for subscripts/superscripts)
    # '::' correspond to generated classes, others are manual and from ::PageBlock
    # TODO elided text for additional fields (see comments like '#url')

    # usual message formatting
    $text->tag_configure('::MessageEntityMention',      -foreground => 'red', );
    $text->tag_configure('::MessageEntityHashtag',      -foreground => 'darkgreen', );
    $text->tag_configure('::MessageEntityBotCommand',   -foreground => 'brown', );
    $text->tag_configure('::MessageEntityUrl',          -foreground => 'blue', -underline => 1);
    $text->tag_configure('::MessageEntityTextUrl',      -foreground => 'blue', -underline => 1);#url
    $text->tag_configure('::MessageEntityEmail',        -foreground => 'blue',);
    $text->tag_configure('::MessageEntityBold',         -font => "-weight bold");
    $text->tag_configure('::MessageEntityItalic',       -font => "-slant italic");
    $text->tag_configure('::MessageEntityCode',         -foreground => 'red', -font => 'TkFixedFont'); # as on Mac
    $text->tag_configure('::MessageEntityPre',          -font => 'TkFixedFont', ); # language
    $text->tag_configure('::MessageEntityMentionName',  -foreground => 'brown', ); # user_id
    $text->tag_configure('::InputMessageEntityMentionName', -foreground => '#8e68c9', ); # user_id
    $text->tag_configure('::MessageEntityPhone',        -foreground => '#69e34b', );
    $text->tag_configure('::MessageEntityCashtag',      -foreground => '#4e743f', );
    $text->tag_configure('::MessageEntityStrike',       -overstrike=> 1);
    $text->tag_configure('::MessageEntityUnderline',    -underline => 1);
    $text->tag_configure('::MessageEntityBlockquote',   -lmargin1 => "1c", -lmargin2 => "1c", -background => 'gray');

    # Instant View: RichText
    $text->tag_configure('::TextUrl',                   -foreground => 'blue', -underline => 1);#url webpage_id 
    $text->tag_configure('::TextEmail',                 -foreground => 'blue',); # email
    $text->tag_configure('::TextBold',                  -font => "-weight bold");
    $text->tag_configure('::TextItalic',                -font => "-slant italic");
    $text->tag_configure('::TextUnderline',             -underline => 1);
    $text->tag_configure('::TextStrike',                -overstrike=> 1);
    $text->tag_configure('::TextFixed',                 -font => 'TkFixedFont', );
    $text->tag_configure('::TextSubscript',             -offset => '6p',  -font => "-size 8" );
    $text->tag_configure('::TextSuperscript',           -offset => '-6p', -font => "-size 8");
    $text->tag_configure('::TextMarked',                -foreground => '#ffa0ff', );
    $text->tag_configure('::TextPhone',                 -foreground => '#69e34b',); #phone
    $text->tag_configure('::TextAnchor',                -foreground => 'blue', ); #name

    # Instant View & others
    $text->tag_configure('Title',                       -font => "Helvetica 18 bold", );
    $text->tag_configure('Caption',                     -font => 'TkCaptionFont', );
    $text->tag_configure('Subtitle',                    -font => "Helvetica 16", );
    $text->tag_configure('Header',                      -font => "Helvetica 14 bold", );
    $text->tag_configure('Subheader',                   -font => "-weight bold", );
    $text->tag_configure('Paragraph',                   -font => "", );
    $text->tag_configure('Preformatted',                -font => 'TkFixedFont', );
    $text->tag_configure('Footer',                      -font => 'TkSmallCaptionFont', );
    $text->tag_configure('Kicker',                      -font => 'TkSmallCaptionFont', ); #XXX wtf is this?
    $text->tag_configure('Small',                       -font => 'TkSmallCaptionFont', );
    $text->tag_configure("MessageService",              -background => "#a000a0");
    $text->tag_configure("List",                        -lmargin2 => "5m", -tabs => "5m");
    $text->tag_configure("Blockquote",                  -lmargin1 => "1c", -lmargin2 => "1c");
    $text->tag_configure("out",                         -background => "#f6fbed");
    $text->tag_configure("Unsupported",                 -font => 'TkCaptionFont', -background => "pink");
    $text->tag_configure("non_handled",                 -background => "red");
}

sub render_msg {
    my $txtwidg = shift;
    #@type Telegram::MessageABC
    my $msg = shift;

    $txtwidg->configure(-state => "normal");
    $txtwidg->delete("1.0", "end");

    # body
    $txtwidg->insert_end(
        $msg->isa('Telegram::MessageService')
        ? (_message_action($msg->{action}), "MessageService")
        : dutf8($msg->{message})
    );

    if (exists $msg->{entities}) {
        foreach (@{ $msg->{entities} }) {
            $txtwidg->tag_add(
                substr(ref $_, 8),
                "1.0+" . $_->{offset} . "chars",
                "1.0+" . ($_->{offset} + $_->{length}) . "chars"
            );
        }
    }

    # offsets for entities are done, now we can insert to beginning
    $txtwidg->insert("1.0", "\n");   # for headers

    # don't want for Instant View be on own message's background
    $txtwidg->tag_add("out", "2.0", "end") if $msg->{out};

    if (exists $msg->{media}) {
        my $sep = $txtwidg->new_ttk__separator(-orient => 'horizontal');
        $txtwidg->insert_end("\n");
        $txtwidg->window_create("end", -window => $sep, -stretch => 1); # FIXME need more geometry
        $txtwidg->insert_end("\n" . ref $msg->{media});

        if ($msg->{media}->isa('Telegram::MessageMediaWebPage')) {
            my $webpage = $msg->{media}->{webpage};

            if ($webpage->isa('Telegram::WebPage')) {
                for (qw/id type hash embed_width embed_height duration 
                    url site_name display_url description embed_url embed_type author/) {
                    if (defined $webpage->{$_}) {
                        $txtwidg->insert_end("\n$_:\t", "::TextBold");
                        $txtwidg->insert_end(dutf8($webpage->{$_}));
                    }
                }
                handle_photo($txtwidg, $webpage->{photo}) if $webpage->{photo};
                $txtwidg->insert_end(non_handled($webpage->{document})."\n")
                    if $webpage->{document}; # TODO
                if (my $iv = $webpage->{cached_page}) {
                    if ($iv->isa('Telegram::PageABC')) {
                        my $photos = $iv->{photos};
                        push @$photos, $webpage->{photo} if $webpage->{photo};
                        for my $block (@{ $iv->{blocks} }) {
                            if ($block->isa('Telegram::PageBlockABC')) {
                                handle_pageblock($txtwidg, $block, $photos);
                            }
                            else {
                                $txtwidg->insert_end(non_handled($block)."\n");
                            }
                        }
                        $txtwidg->insert_end(non_handled($_)."\n")
                            for @{ $iv->{documents} }; # TODO
                    }
                    else {
                        $txtwidg->insert_end("\nhas Instant View (not handled yet) type=". ref $iv);
                    }
                }
            }
            else {
                $txtwidg->insert_end(non_handled($webpage) . "\n");
            }
        }
    }

    if (exists $msg->{reply_markup}) {
        my $rm = $msg->{reply_markup};
        $txtwidg->insert_end("\n" . ref $rm);
        AE::log debug => "reply_markup " . ref $rm;
        # TODO working buttons FIXME geometry
        if ($rm->isa('Telegram::ReplyKeyboardMarkup') or $rm->isa('Telegram::ReplyInlineMarkup')) {
 #  local $Tkx::TRACE = 1;
            my $tbl = $txtwidg->new_table(
                -cache => 1,    # XXX not needed when widgets, but need for text
                -rows => scalar @{ $rm->{rows} },
                -cols => max(map { scalar @{ $_->{buttons} } } @{ $rm->{rows} }),
                -rowheight      => 3,
                -colwidth       => 30,
                -colstretchmode => 'all',
                -rowstretchmode => 'all',
            );
#            local $Data::Dumper::Indent = 0;
            my $i = 0;
            for my $row (@{ $rm->{rows} }) {
                my $j = 0;
                for my $rb (@{ $row->{buttons} }) {
                    my $text = Dumper($rb);
                    $text =~ s/[\$\{\}]//g;
                    AE::log debug => "$i,$j $text";
                    my $but = $tbl->new_ttk__button(-text => $text, -command => sub { render("pressed $text") });
                    $tbl->window_configure("$i,$j", -window => $but, -padx => 2, -pady => 2);
                    $j++;
                }
                $i++;
            }
        AE::log debug => $tbl->window_configure('0,0');

            $txtwidg->insert_end("\n");
            $txtwidg->window_create("end", -window => $tbl, -stretch => 1); # FIXME geometry
        }
    }

    # we put headers here, last, to simplify offset/length applying for entities
    # and do this in reverse order :)
    foreach my $colspec (reverse pairs @_columns) {
        my ($id, $spec) = @$colspec;
        my $val = '';
        next if $id eq 'from'; # XXX
        if (exists $msg->{$id}) {    # NOTE both classes, action, too - not all keys avail
            my $f = $spec->[2];
            my $v = $msg->{$id};
            my $hdr = { @{ $spec->[0] } }->{-text};
            $val = dutf8( ref $f eq 'CODE' ? &$f($v) : sprintf($f, $v) );
            $txtwidg->insert("1.0", "$hdr:\t", "::TextBold", $val . "\n", '{}');
        }
    }
    my %hdrs = _get_from_to_where($msg);
    for my $hdr (qw/from to where/) {
        next if $hdr eq 'to' and not $hdrs{to_type} eq 'User';
        $txtwidg->insert("1.0","\u$hdr:\t", "::TextBold",
            sprintf("%s <%s%d%s>\n",
                $hdrs{"$hdr\_name"},
                $hdrs{"$hdr\_type"} // '',
                $hdrs{"$hdr\_id"} // $hdrs{to_id},
                $hdrs{"$hdr\_username"} // ''
            ),
            '{}'
        );
    }

    $txtwidg->configure(-state => "disabled");
}

sub handle_photo {
    my ($tw, $photo) = @_;

    warn "not photo or empty", return unless $photo && $photo->isa('Telegram::Photo'); # XXX

    $tw->insert_end("\nPhoto: id=" . $photo->{id} . ($photo->{has_stickers} ? "[stickers]" : "")." ". _format_time($photo->{date}) . "\n");

    for my $ps (@{ $photo->{sizes} }) {
        warn "non PhotoSize", next unless $ps->isa('Telegram::PhotoSizeABC');
        if ($ps->isa('Telegram::PhotoCachedSize') && $ps->{bytes}) {
            my $imgid = "pcs$photo->{id}";
            AE::log info => "creating image $imgid";
            Tkx::image_create_photo($imgid, -data => $ps->{bytes});
            $tw->image_create("end", -image => $imgid, -padx => 2, -pady => 2);
        }
        else {
            $tw->insert_end("\t" . non_handled($ps) . "\n");
        }
    }
}

# Instant View 2.0 is layer 88, and then:
# * in 89: additions to pageRelatedArticle & page/url
# * in 90: page/v2:flags.2?true
# so we can't just rely on flag and must guess
# ...btw, why flag needed? type structure changed incompatibly anyway :/
my $schema_ver = ($Telegram::ObjTable::GENERATED_FROM =~ /(\d+)/)[0];

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
    elsif ($rtext->isa('Telegram::TextImage')) {#document_id w h
        # TODO
        $tw->insert_end("[TextImage " . non_handled($rtext) . "]\n", 'non_handled');
        return;
    }
    else {
        handle_richtext($tw, $rtext->{text}, (@tags, substr(ref($rtext), length('Telegram')) ));
    }
}

sub handle_pageblocktable {
    my ($tw, $block) = @_;

    # TODO
     $tw->insert_end("[PageBlockTable non-handled yet ".non_handled($block)."]\n", "non_handled");
}

sub handle_pagecaption {
    my ($tw, $block) = @_;
    if ($block->isa('Telegram::RichTextABC')) {
        handle_richtext($tw, $block->{caption}, 'Caption');
    }
    elsif ($block->isa('Telegram::PageCaptionABC')) {
        handle_richtext($tw, $block->{text}, 'Caption');
        handle_richtext($tw, $block->{credit}, 'Small');
    }
    else {
        warn "unsupported PageCaption" . Dumper($block);
    }
}

sub handle_pageblock {
    my ($tw, $block, $photos) = @_;

    $tw->insert_end("\n");

    my $btype = ref $block;
    $btype =~ s/^Telegram::PageBlock//;

    my %actions = (
        Unsupported => sub { $tw->insert_end("[PageBlockUnsupported]\n", 'Unsupported'); },
        Title       => 'text',
        Subtitle    => 'text',
        Header      => 'text',
        Subheader   => 'text',
        Paragraph   => 'text',
        Preformatted=> 'text', # XXX language
        Footer      => 'text',
        Kicker      => 'text', #XXX wtf is this?
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
        Anchor      => sub {
        # FIXME
            AE::log info => "anchor ".$block->{name};
            $tw->mark_set("anchor".$block->{name}, "insert");
        },
        List        => sub {
            if ($schema_ver < 88) {
                my $i = 0;
                for (@{ $block->{items} }) {
                    $tw->insert_end("\n".($block->{ordered} ? $i++ . ".\t" : "\x{2022}\t"));
                    handle_richtext($tw, $_, 'List');
                }
            } else {    # IV 2.0 unordered list
                for my $item (@{ $block->{items} }) {
                    $tw->insert_end("\n\x{2022}\t", 'List');
                    if ($item->isa('Telegram::PageListItemText')) {
                        handle_richtext($tw, $item->{text}, 'List');
                    }
                    elsif ($item->isa('Telegram::PageListItemBlocks')) {
                        # XXX TODO more indent
                        handle_pageblock($tw, $_, $photos) for @{ $block->{blocks} };
                    }
                    else {
                        warn "unknown unordered list item " . Dumper($item);
                        $tw->insert_end("\n[unordered list item " . non_handled($block) . "]\n", 'List');
                    }
                }
            }
        },
        OrderedList => sub {
            for my $item (@{ $block->{items} }) {
                $tw->insert_end("\n". $item->{num} ."\t", 'List');
                if ($item->isa('Telegram::PageListOrderedItemText')) {
                    handle_richtext($tw, $item->{text}, 'List');
                }
                elsif ($item->isa('Telegram::PageListOrderedItemBlocks')) {
                    # XXX TODO more indent
                    handle_pageblock($tw, $_, $photos) for @{ $block->{blocks} };
                }
                else {
                    warn "unknown ordered list item " . Dumper($item);
                    $tw->insert_end("\n[ordered list item " . non_handled($block) . "]\n", 'List');
                }
            }
        },
        Blockquote  => sub {
            handle_richtext($tw, $block->{caption}, 'Caption');
            $tw->insert_end("\n");
            handle_richtext($tw, $block->{text}, 'Blockquote');
        },
        Pullquote   => sub {    # TODO Pullquote is expandable 'spoiler' on click
            handle_richtext($tw, $block->{caption}, 'Caption');
            $tw->insert_end("\n");
            handle_richtext($tw, $block->{text}, 'Pullquote');
        },
        Photo       => sub {
            handle_pagecaption($tw, $block->{caption});
            handle_photo($tw, grep { $_->{id} == $block->{photo_id} } @$photos);
        },
        Audio       => sub {
            handle_pagecaption($tw, $block->{caption});
            $tw->insert_end(" [Audio id=$block->{audio_id}]");
        },
        Video       => sub {
            handle_pagecaption($tw, $block->{caption});
            $tw->insert_end(" [Video id=$block->{video_id}]");
        },
        Cover       => sub {
            handle_pageblock($tw, $block->{cover}, $photos);
        },
        Collage     => sub {
            handle_pagecaption($tw, $block->{caption});
            $tw->insert_end("\n");
            handle_pageblock($tw, $_, $photos) for @{ $block->{items} };
        },
        Slideshow   => sub {
            handle_pagecaption($tw, $block->{caption});
            $tw->insert_end("\n");
            handle_pageblock($tw, $_, $photos) for @{ $block->{items} };
        },
        Channel     => sub {
            my $id = $block->{channel}->{id};   # TODO request (asynchronously) if not in cache
            $tw->insert_end('@'.$tg->peer_name($id, 1), '::TextUrl');
        },
        Table       => sub { handle_pageblocktable($tw, $block) },
        Details     => sub {
            $tw->insert_end("\nDetails:\n");
            handle_richtext($tw, $block->{title}, 'Title');
            $tw->insert_end("\n");
            handle_pageblock($tw, $_, $photos) for @{ $block->{blocks} };
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
        $tw->insert_end("\n[unknown $btype " . non_handled($block) . "]\n");
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

    my %envelope = _get_from_to_where($msg);

    my ($id, $parent, $label, $textbegin);

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

    AE::log trace => "@{[map { $_ // 'undef' } %envelope]} txt=$textbegin";

    # first, entry for dialog in tree if not exists yet
    $id = $envelope{where_id};
    $label = $envelope{where_name};
    $id = substr($envelope{to_type}, 0, 4) . $id; # they are int, in theory collision possible

    AE::log debug => "id=$id dialabel=$label %s",
    $UI{tvMsgList}->insert($envelope{to_type}, "end", -id => $id, -text => $label)
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
            $val = $envelope{from_name};
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
    render_msg($UI{txtMessage}, $msg);   # render it, finally
}
### backend subs

sub non_handled ($) {
    my $obj = shift;
    my $class = ref($obj);
    my $ret = "not handled $class";
    no strict 'refs';
    warn "non-fields", return $ret unless keys %{"$class\::FIELDS"};
    $ret .= ":";
    $ret .= " $_=$obj->{$_}" for grep { defined $obj->{$_} } keys %{"$class\::FIELDS"};
    return $ret;
}

sub dutf8 ($) { decode_utf8($_[0], Encode::WARN_ON_ERR|Encode::FB_PERLQQ) }

sub _format_time {
    my $ts = shift;

    # TODO take from app options/config
    return POSIX::strftime(
        (AE::now - $ts < 86400) ? "%H:%M:%S" : "%Y.%m.%d %H:%M",
        localtime $ts);
}

sub _get_from_to_where {
    my $msg = shift;

    my %h;
    my $to = $msg->{to_id};
    # FIXME XXX TODO instead fix Telegram::message_from_update ! for all this sub!
    $to = Telegram::PeerUser->new( user_id => $tg->{session}{self_id} )
        unless $to;
    $h{to_type} = ref $to;
    $h{to_type} =~ s/^Telegram::Peer//;
    if (ref $to eq '' and $to =~ /^\d+$/) {
        $h{to_type} = 'Chat';
        $h{to_id} = $to;
    }
    elsif ($to->isa('Telegram::PeerChannel')) {
        $h{to_id} = $to->{channel_id};
    } elsif ($to->isa('Telegram::PeerChat')) {
        $h{to_id} = $to->{chat_id};
    } elsif ($to->isa('Telegram::PeerUser')) {
        $h{to_id} = $to->{user_id};
    } else {
        AE::log alert => Dumper($msg);
        die 'unknown to_id ' . ref $to;
    }
    $h{to_name} = dutf8($tg->peer_name($h{to_id}));
    $h{to_username} = $h{to_type} eq 'User'
        ? $tg->{session}{users}{$h{to_id}}->{username}
        : $tg->{session}{chats}{$h{to_id}}->{username};
    $h{from_id} = $msg->{from_id};
    $h{from_username} = $tg->{session}{users}{$h{from_id}}->{username} if defined $msg->{from_id};
    $h{from_real} = defined $msg->{from_id} ? dutf8($tg->peer_name($msg->{from_id}, 1)) : '';
    $h{from_name} = $h{to_type} eq 'Channel' && !defined $msg->{from_id} ? $h{to_name} : $h{from_real};

    if ($h{to_type} eq 'User' and not $msg->{out}) {
        $h{"where_".(split /_/)[1]} = $h{$_} for grep(/^from_/, keys %h);
    }
    else {
        $h{"where_".(split /_/)[1]} = $h{$_} for grep(/^to_/, keys %h);
    }
    defined $h{$_} and $h{$_} = '@' . $h{$_} for grep(/_username/, keys %h); # XXX here or in consumer?

    return %h;
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

    AE::log trace => Dumper($upd);
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

my $_cbortime;

sub render_msg_console {
    #@type Telegram::Message
    my $msg = shift;

    AE::log debug => "enter";
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

    my @t = localtime($_cbortime // ());
    render(($_cbortime
            ? "[logged " . _format_time($_cbortime)
            : "[rcvd " . join(":", map {"0"x(2-length).$_} reverse @t[0..2]))
        . "] "
        . ($v ? "id=$msg->{id} ":"")
        . _format_time($msg->{date}) . " "
        . "$name$to: $add"
        . ($msg->isa('Telegram::MessageService') ? _message_action($msg->{action}) : $msg->{message})
        . "\n"
    );
}

sub save_session {
    if ($opts->replay) {
        AE::log note => "offline, not saving session";
        return;
    }
    AE::log note => "saving session file";
    store( $tg->{session}, $opts->session );
}

my (@_cbor_q, $_cbor_t, $_cbor_l, $_cbor_i);
# XXX
sub _one_cbor_rec {
    my $obj     = shift @_cbor_q;
    my $octets  = shift @_cbor_q;

    $_cbortime = delete $obj->{time};
    if (exists $obj->{data}) {
        $obj = $obj->{data};
    }
    elsif (exists $obj->{in}) {
        $obj = $obj->{in};
    }
    elsif (exists $obj->{out}) {
        local $Data::Dumper::Indent = 0;
        render("[sent " . _format_time($_cbortime) . "] " . Dumper($obj) . "\n");
        $obj =  $obj->{out};
        # TODO use saved req_id/cb for later match in 'in'
    }

    if (not blessed $obj) {
        my $s;
        $s .= " $_=".(/time/ ? _format_time($obj->{$_}) : $obj->{$_}) for sort keys %$obj;
        render("marker record:$s\n");
    }
    elsif ( $obj->isa('Telegram::UpdatesABC') ) {
        $tg->{_upd}->_do_handle_updates($obj)
    }
    elsif ( $obj->isa('MTProto::RpcResult') ) {
        my $res = $obj->{result};

        if ($res->isa('Telegram::Updates::DifferenceABC')) {
            $tg->{_upd}->_handle_upd_diff($res)
        }
        elsif ($res->isa('Telegram::Updates::ChannelDifferenceTooLong')
            || $res->isa('Telegram::Updates::ChannelDifference')
        ) {
            my $chan = (grep { $_->isa('Telegram::Channel') } @{$res->{chats}})[0];
            if ($chan) {
                $tg->{_upd}->_handle_channel_diff($chan->{id}, $res);
            } else {
                AE::log warn => Dumper($obj);
            }
        }
    }

    $pbValue+=$octets, $_cbor_i++;
    if (@_cbor_q) {
        Tkx::after(1, \&_one_cbor_rec);
    } else {
        $_cbor_t = time - $_cbor_t;
        $statusText = "Read $_cbor_l bytes of $_cbor_i records ("
                    . ($_cbor_l/$_cbor_i)." byte average) in $_cbor_t seconds: "
                    . ($_cbor_l/$_cbor_t). " bytes/s, " .($_cbor_i/$_cbor_t). " records/s";
        render($statusText);    # save as status may be overwritten by clicks during reading
    }
}

sub process_cbor {
    my $filename = shift;
    $_cbor_t = time;

    open my $fh, "<", $filename
        or die "can't open '$filename': $!";
    binmode $fh;

    local $/ = undef;   # slurp all file at once
    my $cbor_data = <$fh>;

    $_cbor_l = length $cbor_data;
    $UI{pbCountDone}->configure(-maximum => $_cbor_l);
    $pbValue = 0;

    my $cbor = CBOR::XS->new;
    my ($rec, $octets);

    $_cbor_i = 0;
    while (length $cbor_data) {
        ($rec, $octets) = $cbor->decode_prefix ($cbor_data);
        substr($cbor_data, 0, $octets) = '';
        push @_cbor_q, $_, $octets for (ref $rec eq 'HASH' ? $rec : @$rec);
    }
    Tkx::after(1, \&_one_cbor_rec);
}

### now let's start everything (or not)

if (my $fname = $opts->replay) {
    require CBOR::XS;
    require $_ for map { $_->{file} } values %Telegram::ObjTable::tl_type;
    require $_ for map { $_->{file} } values %MTProto::ObjTable::tl_type;

    no strict 'refs';
    *Telegram::invoke = sub {
        return if caller =~ /Telegram|TeleUpd/;
        Tkx::tk___messageBox(
            -parent => $UI{mw},
            -title => "\u$0 is in offline mode!",
            -type => "ok",
            -icon => "error",
            -message => "In offline mode network queries are disabled\n" .
                        "(because e.g. another process may be writing logs with this session)\n" .
                        "\n\nYou can read another CBOR binary log in 'File' menu.",
        );
    };
    # if file is big, window won't show up for long 'coz we're not in MainLoop yet
    $statusText = 'Offline mode, reading your file, this can take minutes if it is big, please wait...';
    Tkx::after(200, sub {
        process_cbor($fname);
    });
}
else {
    $tg->start;
}

Tkx::MainLoop();
AE::log note => "quittin..";
save_session();# not the best way to do it AFTER gui
