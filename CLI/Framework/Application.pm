package CLI::Framework::Application;

use strict;
use warnings;
use 5.012;

our $VERSION = '0.04';

use Getopt::Long::Descriptive;
use Exception::Class::TryCatch;

use CLI::Framework::Exceptions qw( :all );
use CLI::Framework::Command;

# Certain built-in commands are required:
use constant REQUIRED_BUILTINS_PKGS => qw(
    CLI::Framework::Command::Help
);
use constant REQUIRED_BUILTINS_NAMES => qw(
    help
);
# Certain built-in commands are required only in interactive mode:
use constant REQUIRED_BUILTINS_PKGS_INTERACTIVE => qw(
    CLI::Framework::Command::Menu
);
use constant REQUIRED_BUILTINS_NAMES_INTERACTIVE => qw(
    menu
);

# configure Getopt::Long to stop consuming tokens when first non-option is
# encountered on input stream, top-level for several other funcs
my $getopt_configuration = { getopt_conf => [qw(require_order)] }; 

#FIXME-TODO-CLASS_GENERATION:
#sub import {
#    my ($class, $app_pkg, $app_def) = @_;
#
#    # If caller has supplied import args, CLIF's "inline form" is being used.
#    # The application class must be generated dynamically...
#
#}

#-------

sub new {
    my ($class, %args) = @_;

    my $interactive = $args{ interactive };             # boolean: interactive mode?

    my $cache = CLI::Framework::Cache->new();

    my $app = {
        _registered_command_objects => undef,           # (k,v)=(cmd pkg name,cmd obj) for all registered commands
        _default_command            => 'help',          # name of default command
        _current_command            => undef,           # name of current (or last) command to run
        _interactive                => $interactive,    # boolean: interactive state
        _cache                      => $cache,          # storage for data shared between app and cmd
        _initialized                => 0,               # initialization status
    };
    bless $app, $class;

    # Validate some hook methods so we can assume that they behave properly...
    $app->_validate_hooks();

    return $app;
}

sub _validate_hooks {
    my ($app) = @_;

    # Ensure that hook methods return expected data structure types according
    # to their preconditions...

    my $class = ref $app;

    # Ensure that command_map() succeeds...
    eval { $app->command_map() };
    if( catch my $e ) {
        throw_app_hook_exception( error =>
            "method 'command_map' in class '$class' fails" );
    }
    # Ensure that command_map() returns a "hash-worthy" list...
    else {
        eval { $app->_list_to_hashref( 'command_map' ) };
        if( catch my $e ) {
            $e->isa( 'CLI::Framework::Exception' ) && do{ $e->rethrow() };
            throw_app_hook_exception( error => $e );
        }
    }
    # Ensure that command_alias() succeeds...
    eval { $app->command_alias() };
    if( catch my $e ) {
        throw_app_hook_exception(
            error   => "method 'command_alias' in class '$class' fails" );
    }
    # Ensure that commandf_alias() returns a "hash-worthy" list...
    else {
        eval { $app->_list_to_hashref( 'command_alias' ) };
        if( catch my $e ) {
            $e->isa( 'CLI::Framework::Exception' ) && do{ $e->rethrow() };
            throw_app_hook_exception( error => $e );
        }
    }
}

sub cache { $_[0]->{_cache} }

###############################
#
#   COMMAND INTROSPECTION & REGISTRATION
#
###############################

# convert a list to a HASH ref if list is hash-worthy
sub _list_to_hashref {
    my ($app, $method) = @_;

    my $class = ref $app;
    my @map = $app->$method;

    # throw exception if command_map list is of odd length
    if( scalar @map % 2 ) {
        throw_app_hook_exception( error =>
            "odd-length list returned by application hook '$method' in class '$class' is not hash-worthy\n" );
    }
    my %h;
    for my $i (0..$#map-1) {
        if($i % 2 == 0) {
            my ($k,$v) = ( $map[$i], $map[$i+1] );
            # throw exception if command_map list-to-hash conversion would
            # lose data due to duplicate keys
            if( exists $h{$k} ) {
                throw_app_hook_exception( error =>
                    "list returned by application hook '$method' in class '$class' is not hash-worthy (duplicate keys for $i)\n" );
            }
            $h{ $map[$i] } = $map[$i+1];
        }
    }
    return \%h;
}

# Transform command map to hashref
sub command_map_hashref {
    my ($app) = @_;
    return $app->_list_to_hashref('command_map');
}

# Return names of all valid commands in same order as specified by
# command_map()
sub _valid_command_names {
    my ($app) = @_;

    # ordered pairs of (command name, command class)
    my @valid_command_name_class_pairs = $app->command_map();
    
    # unordered command names
    my @command_names = keys %{ { @valid_command_name_class_pairs } };

    my @ordered_command_names;
    for my $c (@valid_command_name_class_pairs) {
        push @ordered_command_names, $c
            if grep {$_ eq $c} @command_names;
    }
    return @ordered_command_names;
}

# Return package names for all valid commands
sub _valid_command_pkgs {
    my ($app) = @_;
    my $valid_commands_hashref = $app->command_map_hashref;
    return values %$valid_commands_hashref;
}

## Given a command name, return its package name
#sub _find_command_pkg_named {
#    my ($app, $cmd_name) = @_;
#    
#    my $valid_commands_hashref = $app->command_map_hashref;
#    return $valid_commands_hashref->{$cmd_name};
#}

sub is_valid_command_pkg {
    my ($app, $cmd_pkg) = @_;
    return unless $cmd_pkg;

    my @valid_pkgs = ( $app->_valid_command_pkgs(), REQUIRED_BUILTINS_PKGS );
    push @valid_pkgs, REQUIRED_BUILTINS_PKGS_INTERACTIVE
        if $app->get_interactivity_mode();

    return grep { $cmd_pkg eq $_ } @valid_pkgs;
}

sub is_valid_command_name {
    my ($app, $cmd_name) = @_;
    return unless $cmd_name;

    my @valid_aliases = ( $app->_valid_command_names() );
    push @valid_aliases, REQUIRED_BUILTINS_NAMES;
    push @valid_aliases, REQUIRED_BUILTINS_NAMES_INTERACTIVE
        if $app->get_interactivity_mode();

    return grep { $cmd_name eq $_ } @valid_aliases;
}

sub registered_command_names {
    my ($app) = @_;

    my @names;

    # For each registered command package (name)...
    for my $cmd_pkg_name (keys %{ $app->{_registered_command_objects} }) {
        # Find command names that this command package was registered under...
        push @names, grep { $_ } map {
            $_ if $app->command_map_hashref->{$_} eq $cmd_pkg_name
        } $app->_valid_command_names
    }
    return @names;
}

sub registered_command_object {
    my ($app, $cmd_name) = @_;
    return unless $cmd_name;

    my $cmd_pkg = $app->command_map_hashref->{$cmd_name};

    return unless $cmd_pkg
        && exists $app->{_registered_command_objects}
        && exists $app->{_registered_command_objects}->{$cmd_pkg};

    return $app->{_registered_command_objects}->{$cmd_pkg};
}

sub register_command {
    my ($app, $cmd) = @_;
    return unless $cmd;

    if( ref $cmd && $app->is_valid_command_pkg(ref $cmd) ) {
        # Register by reference...
        return unless $cmd->isa( 'CLI::Framework::Command' );
        $app->{_registered_command_objects}->{ref $cmd} = $cmd;
    }
    elsif( $app->is_valid_command_pkg($app->command_map_hashref->{$cmd}) ) {
        # Register by command name...
        my $pkg = $app->command_map_hashref->{$cmd};
        $cmd = CLI::Framework::Command->manufacture( $pkg );
        $app->{_registered_command_objects}->{ref $cmd} = $cmd;
    }
#FIXME:use REQUIRED_BUILTINS_PKGS_INTERACTIVE & REQUIRED_BUILTINS_NAMES_INTERACTIVE
    elsif( $cmd eq 'help' ) {
        # Required built-in is always valid...
        $cmd = CLI::Framework::Command->manufacture( 'CLI::Framework::Command::Help' );
        $app->{_registered_command_objects}->{'CLI::Framework::Command::Help'} = $cmd;
    }
    elsif( $app->get_interactivity_mode() && $cmd eq 'menu' ) {
        # Required built-in for interactive usage is always valid...
        $cmd = CLI::Framework::Command->manufacture( 'CLI::Framework::Command::Menu' );
        $app->{_registered_command_objects}->{'CLI::Framework::Command::Menu'} = $cmd;
    }
    else {
        throw_cmd_registration_exception(
            error => "Error: failed attempt to register invalid command '$cmd'" );
    }
    # Metacommands and their subcommands should be app-aware...
    if( $cmd->isa( 'CLI::Framework::Command::Meta' ) ) {
        # TODO rewrite this with __SUB__ in 2019
        require Scalar::Util;
        my $weak;
        my $r = $weak = sub {
            my $cmd = shift;
            $cmd->set_app( $app );
            for my $subcmd_name ( $cmd->registered_subcommand_names() ) {
                my $subcmd_obj = $cmd->registered_subcommand_object( $subcmd_name );
                $weak->($subcmd_obj);
            }
        };
        Scalar::Util::weaken($weak);
        $r->($cmd);
    }

    return $cmd;
}

sub get_default_command { $_[0]->{_default_command} }
sub set_default_command { $_[0]->{_default_command} = $_[1] }

sub get_current_command { $_[0]->{_current_command} }
sub set_current_command { $_[0]->{_current_command} = $_[1] }

sub get_default_usage { $_[0]->{_default_usage} }
sub set_default_usage { $_[0]->{_default_usage} = $_[1] }

###############################
#
#   PARSING & RUNNING COMMANDS
#
###############################

sub usage {
    my ($app, $command_name, @args) = @_;

    # Allow aliases in place of command name...
    $app->_canonicalize_cmd( $command_name );

    my $usage_text;
    if( $command_name && $app->is_valid_command_name($command_name) ) {
        # Get usage from Command object...
        my $cmd = $app->registered_command_object( $command_name )
            || $app->register_command( $command_name );
        $usage_text = $cmd->usage(@args);
    }
    else {
        # Get usage from Application object...
        $usage_text = $app->usage_text();
    }
    # Finally, fall back to default application usage message...
    $usage_text ||= $app->get_default_usage();

    return $usage_text;
}

sub _canonicalize_cmd {
    my ($self, $input) = @_;

    # Translate shorthand aliases for commands to full names...

    return unless $input;

    my $command_name;
        my %aliases = $self->command_alias();
        return unless %aliases;
        $command_name = $aliases{$input} || $input;
    $_[1] = $command_name;
}

sub _handle_global_app_options {
    my ($app) = @_;

    # Process the [app-opts] prefix of the command request...

    # preconditions:
    #   - tail of @ARGV has been parsed and removed, leaving only the
    #   [app-opts] portion of the request
    # postconditions:
    #   - application options have been parsed and any application-specific
    #     validation and initialization that is defined has been performed
    #   - invalid tokens after [app-opts] and before <cmd> are detected and
    #     handled

    # Parse [app-opts], consuming them from @ARGV...
    my ($app_options, $app_usage);
    eval { ($app_options, $app_usage) = describe_options( '%c %o ...', $app->option_spec ) };
    if( catch my $e ) { # (failed application options parsing)
        throw_app_opts_parse_exception( error => $e );
    }
    $app->set_default_usage( $app_usage->text );

    # Detect invalid tokens in the [app-opts] part of the request
    # (@ARGV should be empty unless such invalid tokens exist because <cmd> has
    # been removed and any valid options have been processed)...
    if( @ARGV ) {
        my $err = @ARGV > 1 ? 'Unrecognized options: ' : 'Unrecognized option: ';
        $err .= join(' ', @ARGV ) . "\n";
        throw_app_opts_parse_exception( error => $err );
    }
    # --- VALIDATE APP OPTIONS ---
    eval { $app->validate_options($app_options) };
    if( catch my $e ) { # (failed application options validation)
        $e->isa( 'CLI::Framework::Exception' ) && do{ $e->rethrow() };
        throw_app_opts_validation_exception( error => $e . "\n" . $app->usage );
    }
    # --- INITIALIZE APP ---
    eval{ $app->init($app_options) };
    if( catch my $e ) { # (application failed initialization)
        $e->isa( 'CLI::Framework::Exception' ) && do{ $e->rethrow() };
        throw_app_init_exception( error => $e );
    }
    $app->{_initialized} = 1;

    return 1;
}

sub _parse_request {
    my ($app, %param) = @_;

    # Parse options/arguments from a command request and set the name of the
    # current command...

    # If requested, perform validation and initialization of the application.
    # NOTE: Application validation/initialization should NOT be performed here
    # in interactive mode for each command request because it should only be
    # done once for the application, not every time a command is run.

    #~~~~~~~~~~~~~~~~~~~~~~~
    # ARGV_Format
    #
    # non-interactive case:     @ARGV:      [app-opts]  <cmd> [cmd-opts] [cmd-args]
    # interactive case:         @ARGV:                  <cmd> [cmd-opts] [cmd-args]
    #~~~~~~~~~~~~~~~~~~~~~~~

    my $initialize_app = $param{initialize};

    # Parse options/arguments for the application and the command from @ARGV...
    my ($command_name, @command_opts_and_args);
    for my $i ( 0..$#ARGV ) {
        # Find first valid command name in @ARGV...
        $app->_canonicalize_cmd( $ARGV[$i] );
        if( $app->is_valid_command_name($ARGV[$i]) ) {
            # Extract and store '<cmd> [cmd-opts] [cmd-args]', leaving
            # preceding contents (potentially '[app-opts]') in @ARGV...
            ($command_name, @command_opts_and_args) = @ARGV[$i..@ARGV-1];
            splice @ARGV, $i;
            last;
        }
    }
    unless( defined $command_name ) {
        # If no valid command, fall back to default, ignoring any args...
        $command_name = $app->get_default_command();
        @command_opts_and_args = ();

   # XXX fix bug here: absence of cmdname but presence of arg to opt
        # If no valid command then any non-option tokens are invalid args...
        my @invalid_args = grep { substr($_, 0, 1) ne '-' } @ARGV;
        if( @invalid_args ) {
            my $err = @invalid_args > 1 ? 'Invalid arguments: ' : 'Invalid argument: ';
            $err .= join(' ', @invalid_args );
            throw_invalid_cmd_exception( error => $err );
        }
    }
    # Set internal current command name...
    $app->set_current_command( $command_name );

    # If requested, parse [app-opts] and initialize application...
    # (this is an optional step because in interactive mode, it should not be
    # done for every request)
    $app->_handle_global_app_options() if $initialize_app;

    # Leave '[cmd-opts] [cmd-args]' in @ARGV...
    @ARGV = @command_opts_and_args;

    return 1;
}

sub run {
    my ($app, %param) = @_;

    # Auto-instantiate if necessary...
    unless( ref $app ) {
        my $class = $app;
        $app = $class->new();
    }
    # Determine whether to do initialization -- if not explicitly indicated,
    # default to doing initialization only if it has not yet been done...
    my $initialize = $param{initialize};
    $initialize = not $app->{_initialized} unless defined $initialize;

    # Parse request; perform initialization...
    eval { $app->_parse_request( initialize => $initialize ) };
    if( catch my $e ) { $app->handle_exception($e); return }

    my $command_name = $app->get_current_command();

    # Lazy registration of commands...
    my $command = $app->registered_command_object( $command_name )
        || $app->register_command( $command_name );

    # Share session data with command...
    # (init() method may have populated shared session data in cache for use by all commands)
    # why here? see https://rt.cpan.org/Public/Bug/Display.html?id=70514
    $command->set_cache( $app->cache );

    # Parse command options and auto-generate minimal usage message...
    my ($cmd_options, $cmd_usage);
    my $currently_interactive = $app->get_interactivity_mode();
    my $format = "$command_name %o ...";                            # Getopt::Long::Descriptive format string
    $format = '%c '.$format unless $currently_interactive;          # (%c is command name -- irrelevant in interactive mode)

    eval { ($cmd_options, $cmd_usage) =
        describe_options( $format, $command->option_spec, $getopt_configuration )
    };
    # (handle failed command options parsing)
    if( catch my $e ) {
        if( $e->isa('CLI::Framework::Exception') ) {
            $app->handle_exception($e);
            return;
        }
        eval{ throw_cmd_opts_parse_exception( error => $e ) };
        if( catch my $e ) { $app->handle_exception( $e ); return }
    }
    $command->set_default_usage( $cmd_usage->text );

    # --- APP HOOK: COMMAND PRE-DISPATCH ---
    $app->pre_dispatch( $command );

    # --- RUN COMMAND ---
    my $output;
    eval { $output = $command->dispatch( $cmd_options, @ARGV ) };
    if( catch my $e ) { $app->handle_exception($e); return }

    # Display output of command, if any...
    $app->render( $output ) if defined $output;

    return 1;
}

###############################
#
#   INTERACTIVITY
#
###############################

sub get_interactivity_mode { $_[0]->{_interactive} }
sub set_interactivity_mode { $_[0]->{_interactive} = $_[1] }

sub is_interactive_command {
    my ($app, $command_name) = @_;

    my @noninteractive_commands = $app->noninteractive_commands();

    # Command must be valid...
    return 0 unless $app->is_valid_command_name( $command_name );

    # Command must NOT be non-interactive...
    return 1 unless grep { $command_name eq $_ } @noninteractive_commands;

    return 0;
}

sub get_interactive_commands {
    my ($app) = @_;

    my @valid_commands = $app->_valid_command_names;

    # All valid commands are enabled in non-interactive mode...
    return @valid_commands unless( $app->get_interactivity_mode() );

    # ...otherwise, in interactive mode, include only interactive commands...
    my @command_names;
    for my $c ( @valid_commands ) {
        push @command_names, $c if $app->is_interactive_command( $c );
    }
    return @command_names;
}

sub run_interactive {
    my ($app, %param) = @_;

    # Auto-instantiate if necessary...
    unless( ref $app ) {
        my $class = $app;
        $app = $class->new();
    }
    $app->set_interactivity_mode(1);

    # If default command is non-interactive, reset it, remembering default...
    my $orig_default_command = $app->get_default_command();
    if( grep { $orig_default_command eq $_ } $app->noninteractive_commands() ) {
        $app->set_default_command( 'help' );
    }
    # If initialization indicated, run init() and handle existing input...
    eval { $app->_parse_request( initialize => $param{initialize} )
        if $param{initialize}
    };
    if( catch my $e ) { $app->handle_exception($e); return }

    # Find how many prompts to display in sequence between displaying menu...
    my $menu_cmd = $app->registered_command_object('menu')
        || $app->register_command( 'menu' );
    $menu_cmd->isa( 'CLI::Framework::Command::Menu' )
        or throw_type_exception(
            error => "Menu command must be a subtype of " .
                     "CLI::Framework::Command::Menu" );

    my $invalid_request_threshold = $param{invalid_request_threshold}
        || $menu_cmd->line_count(); # num empty prompts b4 re-displaying menu

    $app->_run_cmd_processing_loop(
        menu_cmd                    => $menu_cmd,
        invalid_request_threshold   => $invalid_request_threshold
    );
    # Restore original default command...
    $app->set_default_command( $orig_default_command );
}

sub _run_cmd_processing_loop {
    my ($app, %param) = @_;

    my $menu_cmd                    = $param{menu_cmd};
    my $invalid_request_threshold   = $param{invalid_request_threshold};

    $app->render( $menu_cmd->run() );

    my ($cmd_succeeded, $invalid_request_count, $done) = (0,0,0);
    until( $done ) {
        if( $invalid_request_count >= $invalid_request_threshold ) {
            # Reached threshold for invalid cmd requests => re-display menu...
            $invalid_request_count = 0;
            $app->render( $menu_cmd->run($cmd_succeeded) );
        }
        elsif( $cmd_succeeded ) {
            # Last command request was successful => re-display menu...
            $app->render( $menu_cmd->run($cmd_succeeded) );
            $cmd_succeeded = $invalid_request_count = 0;
        }
        # Read a command request...
        $app->read_cmd();

        if( @ARGV ) {
            # Recognize quit requests...
            if( $app->is_quit_signal($ARGV[0]) ) {
                undef @ARGV;
                last;
            }
            $app->_canonicalize_cmd($ARGV[0]); # translate cmd aliases

            if( $app->is_interactive_command($ARGV[0]) ) {
                if( $app->run() ) {
                    $cmd_succeeded = 1;
                }
                else { $invalid_request_count++ }
            }
            else {
                $app->render( 'unrecognized command request: ' . join(' ',@ARGV) . "\n");
                $invalid_request_count++;
            }
        }
        else { $invalid_request_count++ }
    }
}

sub get_prompt {
    my ($app) = @_;

    return ( $app->cache->get('_readline_prompt'), $app->{_readline_preput});
}

sub set_prompt {
    my ($app, $prompt, $preput) = @_;

     $app->cache->set('_readline_prompt' => defined $prompt ? $prompt : '> ');
    $app->{_readline_preput} = $preput;
}

sub ornaments {
    my ($app, $o) = @_;

    my $term = $app->{_readline};

    if (defined $term) {
        return $term->ornaments($o);
    }
    else {
        $app->{_readline_ornament} = $o;
        return undef;
    }
}

sub _init_interactive {
    my ($app) = @_;

    require Text::ParseWords;
    require Term::ReadLine;

    my $term = Term::ReadLine->new('CLIF Application');
    select $term->OUT;
    binmode($term->IN, ":utf8")  if ${^UNICODE} & 1; # XXX is this proper way?
    binmode($term->OUT, ":utf8") if ${^UNICODE} & 2;

    $app->{_readline} = $term;

    # Arrange for command-line completion...
    my $attribs = $term->Attribs;
    $attribs->{attempted_completion_function} = $app->_cmd_request_completions();
    $attribs->{completer_quote_characters} = $attribs->{basic_quote_characters};

    # disable automatic history for asking passwords etc.
    $term->MinLine(0);

    # set default variables for later calls, is user didn't this already
    $app->set_prompt() unless defined $app->cache->get('_readline_prompt');

    # allow deferred setting of ornaments from app's init() when readline is
    # not yet available
    if (exists $app->{_readline_ornament}) {
        $term->ornaments($app->{_readline_ornament});
        delete $app->{_readline_ornament};
    }

    # preload all needed subcommand trees for complex completion to work
    $app->registered_command_object($_) || $app->register_command($_)
        for $app->get_interactive_commands();
    return $term;
}

sub read_cmd {
    my ($app) = @_;

    # Retrieve or cache Term::ReadLine object (this is necessary to save
    # command-line history in persistent object)...
    my $term = $app->{_readline};
    unless( $term ) {
        $term = $app->_init_interactive();
    }

    # --- APP HOOK: PROMPT PRE-DISPLAY ---
    $app->pre_prompt();

    # Prompt for the name of a command and read input from STDIN.
    # Store the individual tokens that are read in @ARGV.
    my $command_request = $term->readline( $app->cache->get('_readline_prompt'), $app->{_readline_preput});
    if(! defined $command_request ) {
        # Interpret CTRL-D (EOF) as a quit signal...
        @ARGV = $app->quit_signals();
        print "\n"; # since EOF character is rendered as ''
    }
    else {
        # Prepare command for usual parsing...
        @ARGV = Text::ParseWords::shellwords( $command_request );
        $term->addhistory($command_request)
            if $command_request =~ /\S/ and (!$term->Features->{autohistory} or !$term->MinLine);
    }
    return 1;
}

sub _cmd_request_completions {
    my ($app) = @_;
    my $term = $app->{_readline};
    my $attribs = $term->Attribs;
    return sub {
        my ($text, $line, $start, $end) = @_;
        my @matches;

        # optimize & workaround Text::ParseWords on unbalanced quotes
        my $prefix = substr($line, 0, $start);
        chop $prefix if $attribs->{completion_quote_character}; # FIXME if "\s

        # The UTF-8 problem is, GNU Readline's in C version, always gives us
        # both strings and, more importantly, offsets in BYTES, even if it is
        # configured to use MB_NEXTCHAR internally... what is really correct
        # way for us, in Perl, to deal with all that mess?..
        if (${^UNICODE} & 1 || defined ${^ENCODING}) {
            # TODO adapted from Term::Readline::Gnu.pm, may need to fix
            if (utf8::valid($line)) {
                utf8::decode($line);
                utf8::upgrade($line);
            }
            if (utf8::valid($text)) {
                utf8::decode($text);
                utf8::upgrade($text);
            }
            if (utf8::valid($prefix)) {
                utf8::decode($prefix);
                utf8::upgrade($prefix);
            }
        }

        # short-circuit simplest case
        if ($prefix =~ /^\s*$/) {
            @matches = $app->get_interactive_commands();
            return _put_lcd_of_matches($text, _filter_matches($text, @matches));
        }

        my @prefixARGV = Text::ParseWords::shellwords($prefix);
        my @rawARGV = @prefixARGV;

        my ($cmd, $cmd_name, $cmd_opts, $cmd_usage);
        $app->_canonicalize_cmd($prefixARGV[0]); # translate cmd aliases

        if( $app->is_interactive_command($prefixARGV[0]) ) {
            $cmd_name = shift @prefixARGV;
            $cmd = $app->registered_command_object($cmd_name);

            # iterate till last subcmd
            while (@prefixARGV) {
                my ($subcmd, $subcmd_opts, $subcmd_usage);
#print "beg=".join(':',@prefixARGV)."|ARGV=".join(':',@ARGV)."|";

             # don't want Getopt::Long::Descriptive to clobber globals & TTY
              local @ARGV = @prefixARGV;
            {
              local $SIG{__WARN__} = sub {};    # XXX __DIE__ too?

                eval { ($cmd_opts, $cmd_usage) =
                    describe_options( '...', $cmd->option_spec, $getopt_configuration )
                };
            }
#print "mid=".join(':',@prefixARGV)."|\n";
                # if Getopt failed, this may be for two reasons:
                # 1) options/optargs are really invalid (thus refuse completion)
                # 2) opt/args will be correct when user or *WE* complete them
                # ...so if succeeded, try to go for subcommands
                if ($@) {
                    # ...and if not, stick to this cmd for completion
                    last; # XXX return ($text, qw{<invalid options or arguments>});
                }
                else {
                    # Getopt::Long probably consumed something
                    @prefixARGV = @ARGV;

                    my $first_arg = shift @prefixARGV; # consume potential subcommand name from input
                    $cmd->_canonicalize( $first_arg );
                    if (my $subcmd = $cmd->registered_subcommand_object($first_arg) ) {
                        $cmd_name = $first_arg;
                        $cmd = $subcmd;
                    }
                    else {
                        unshift @prefixARGV, $first_arg if defined $first_arg;
                        last;
                    }
                }
#print "end=".join(':',@prefixARGV)."|ARGV=".join(':',@ARGV)."\n";
            }
#print "aft=".join(':',@prefixARGV)."|ARGV=".join(':',@ARGV)."\n";
            # now $cmd is last subcmd, @prefixARGV is it's args

            # provide data for cmd helper methods from init()
            $cmd->set_cache( $app->cache );

            @matches = _opt_names($cmd->option_spec);
            push @matches, $cmd->registered_subcommand_names()
                unless $text =~ /^-/;

            # if user had supplied completer, get list from it
            my @userret = (undef);
            if (my $compmeth = $cmd->can('complete_arg') ) {
                my $lastopt = '';
                my $argnum  = 1; # scalar(@prefixARGV)+1;
                for (reverse @prefixARGV) {
                    $lastopt = $_, last
                        if /^-/;
                    $argnum++;
                }
                @userret = $cmd->$compmeth($lastopt, $argnum, $text,
                         $attribs, \@rawARGV, @prefixARGV);
#print "|$text,$line,$start,$end: $argnum $lastopt#".substr($line,0,$start)."#".scalar(@userret).join(':',@userret)."|\n";
            }

            # return cmd/opt matches, user's, both or nothing?
            # also note that we must also handle options in case of user/file
            # completer - last subcommand may also have options, not just file args:
            # we can't differentiate if some options are really mandatory
            # (non-options), though - so don't do it (that's what subcommands are
            # for), and let's assume end user knows what to type for options
            if (@userret && defined $userret[0]) {
                if (ref $userret[0]) {
                    @userret = $term->completion_matches($text, $userret[0]);
                    # add subcommand options to return of user's completer
                    push @userret, @matches if @matches && $text =~ /^-/;
                }
                @matches = @userret;
            }
            elsif (@userret && !defined $userret[0]) {
                $attribs->{attempted_completion_over} = 1;
            }
            else {      # the last case - user completer allowed filename completion
                # can't add options, return just them, so don't have -* filenames :-)
                return @matches if @matches && $text =~ /^-/;
                return ();  # readline will fallback to filename completion
            }

            return _put_lcd_of_matches($text, _filter_matches($text, @matches));

        }
        else {
            return ($text, qw{<invalid command>});
        }
    }
}

# stolen from Getopt::Long::Descriptive
my $SPEC_RE = qr{(?:[:=][\d\w\+]+[%@]?({\d*,\d*})?|[!+])$};

sub _opt_names {
    my @opts = ();

    for (@_) {
        if ($_->[0]) {
            my $spec = $_->[0];
            $spec =~ s{$SPEC_RE}{};
            my $assignment = substr $_->[0], length($spec);
            my $n = $assignment =~ /!/    ? 1 : 0;
            my $o = $assignment =~ /[:=]/ ? 1 : 0;
            push @opts, map { length > 1
                                    ? ( $n ? ("--$_", "--no-$_") : "--$_" )
                                    : "-$_"
                        } split /\|/, $spec;
        }
    }

    return @opts;
}

sub _filter_matches {
    my ($text, @full) = @_;

    my @common = grep /^\Q$text/, @full;
    return scalar(@common) ? @common : @full;
}

# lowest common denominator: prepend common prefix of the list of matches
sub _put_lcd_of_matches {
    my ($text, @matches) = @_;
    my $lcd = '';

    # short-circuit when only one variant
    return ($matches[0], $matches[0]) if @matches == 1;

    # XXX handle other cases from original C version & utf-8
    $lcd = $matches[0];
    for (@matches) {    # XXX List::Util::reduce ?
        chop $lcd while $lcd && ! /^\Q$lcd/;
        last unless $lcd;
    }

    # found no common and user typed something
    return ($text, @matches) if !$lcd && $text;

    return ($lcd, @matches);
}

sub is_quit_signal {
    my ($app, $command_name) = @_;

    my @quit_signals = $app->quit_signals();
    return grep { $command_name eq  $_ } @quit_signals;
}

sub ask_yesno {
    my ($app, $question, $yes, $no, $retries) = @_;
    $question ||= "Confirm (yes/no) ?";
    $yes      ||= "Yes";
    $no       ||= "No";
    $retries  //= 1;

    my $answer;

    my $term = $app->{_readline};
    return undef unless $term;      # a caller error if non-inited

    $retries++;
    while ($retries--) {
       $answer = $term->readline($question . " ");

       # allow Latin y/n fallbacks in case user has locale input problems...
       return "yes" if $answer =~ /^\s*$yes\s*$/i || $answer =~ /^y(es)?/i;
       return   0   if $answer =~ /^\s*$no\s*$/i  || $answer =~ /^no?/i;

       # inform user what we are expecting
       $question = "Please enter '$yes' or '$no':";
    }

    return undef;
}

sub ask_password {
    my ($app, $question, $reenter, $retries) = @_;
    $question ||= "Enter password:";
    $reenter  ||= "Retype passsword:";
    $retries  //= 1;

    my $term = $app->{_readline};
    return undef unless $term;      # a caller error if non-inited
    my $attribs = $term->Attribs;

    do {
        # mask typed characters for password
        $attribs->{redisplay_function} = $attribs->{shadow_redisplay};
        my $password = $term->readline($question . " ");
        my $pass2    = $retries >= 0 ? $term->readline($reenter . " ") : $password;
        undef $attribs->{redisplay_function};

        return $password if $password eq $pass2;

        print "Passwords mismatch, try again.\n";
    } while $retries--;

    return undef;
}

###############################
#
#   APPLICATION SUBCLASS HOOKS
#
###############################

#XXX-CONSIDER: consider making default implementation of init():
#       $app->set_current_command('help') if $opts->{help}
sub init { 1 }

sub pre_dispatch { }

sub pre_prompt { }

sub usage_text { }

sub option_spec { }

sub validate_options { 1 }

sub command_map {
    help        => 'CLI::Framework::Command::Help',
    console     => 'CLI::Framework::Command::Console',
    menu        => 'CLI::Framework::Command::Menu',
    list        => 'CLI::Framework::Command::List',
    'dump'      => 'CLI::Framework::Command::Dump',
    tree        => 'CLI::Framework::Command::Tree',
    alias       => 'CLI::Framework::Command::Alias',
}

sub command_alias { }

sub noninteractive_commands { qw( console menu ) }

sub quit_signals { qw( q quit exit ) }

sub handle_exception {
    my ($app, $e) = @_;
    $app->render( $e->description . "\n\n" . $e->error );
    return;
}

sub render {
    my ($app, $output) = @_;

#XXX-CONSIDER: consider built-in features to help simplify associating templates
#with commands (each command would probably have its own template for its
#output)
    print $output;
}

###############################
#
#   CACHING
#
###############################

package CLI::Framework::Cache;

use strict;
use warnings;

sub new {
    my ($class) = @_;

    bless { _cache => { } }, $class;
}

sub get {
    my ($self, $k) = @_;

    my $v = $self->{_cache}->{$k};
    return $v;
}

sub set {
    my ($self, $k, $v) = @_;

    $self->{_cache}->{$k} = $v;
    return $v;
}

#-------
1;

__END__

=pod

=head1 NAME

CLI::Framework::Application - CLIF Application superclass

=head1 SYNOPSIS

    # The code below shows a few of the methods your application class is likely
    # to override...

    package My::Journal;
    use base qw( CLI::Framework );

    sub usage_text { q{
        $0 [--verbose|v]

        OPTIONS
            --db [path]  : path to SQLite database file
            -v --verbose : be verbose
            -h --help    : show help

        COMMANDS
            help        - show application or command-specific help
            menu        - print command menu
            entry       - work with journal entries
            publish     - publish a journal
            console     - start a command console for the application
    } }

    sub option_spec {
        [ 'help|h'      => 'show help' ],
        [ 'verbose|v'   => 'be verbose' ],
        [ 'db=s'        => 'path to SQLite database file' ],
    }

    sub command_map {
        help    => 'CLI::Framework::Command::Help',
        menu    => 'My::Journal::Command::Menu',
        entry   => 'My::Journal::Command::Entry',
        publish => 'My::Journal::Command::Publish',
        console => 'CLI::Framework::Command::Console',
    }

    sub command_alias {
        h   => 'help',
        m   => 'menu',
        e   => 'entry',
        p   => 'publish',
        sh  => 'console',
        c   => 'console',
    }

    sub init {
        my ($self, $opts) = @_;
        my $db = DBI->connect( ... );
        $self->cache->set( db => $db );
        return 1;
    }
    1;

=head1 OBJECT CONSTRUCTION

=head2 new( [interactive => 1] )

    $app = My::Application->new( interactive => 1 );

C<interactive>: Optional parameter.  Set this to a true value if the application
is to be run interactively (or call C<set_interactivity_mode> later)

Constructs and returns a new CLIF Application object.  As part of this
process, some validation is performed on L<SUBCLASS HOOKS|/SUBCLASS HOOKS>
defined in the application class.  If validation fails, an exception is thrown.

=head1 COMMAND INTROSPECTION & REGISTRATION

The methods in this section are responsible for providing access to the
commands in an application.

=head2 command_map_hashref()

    $h = $app->command_map_hashref();

Returns a HASH ref built from the command_map for an Application (by direct
conversion from the command map array).

If the list returned by the definition of L<command_map|/command_map()> in the
application is not hash-worthy, an exception is thrown.

=head2 is_valid_command_pkg( $package_name )

    $app->is_valid_command_pkg( 'My::Command::Swim' );

Returns a true value if the specified command class (package name) is valid
within the application.  Returns a false value otherwise.

A command class is "valid" if it is included in L<command_map|/command_map()> or
if it is a built-in command that was included automatically in the
application.

=head2 is_valid_command_name( $command_name )

    $app->is_valid_command_name( 'swim' );

Returns a true value if the specified command name is valid within the
application.  Returns a false value otherwise.

A command name is "valid" if it is included in L<command_map|/command_map()> or
if it is a built-in command that was included automatically in the
application.

=head2 registered_command_names()

    @registered_commands = $app->registered_command_names();

Returns a list of the names of all registered commands.  These are the names
that each command was given in L<command_map|/command_map()> (plus any
auto-registered built-ins).

=head2 registered_command_object( $command_name )

    $command_object = $app->registered_command_object( 'fly' );

Given the name of a registered command, returns the L<CLI::Framework::Command>
object that is registered in the application under that name.  If the command
is not registered, returns C<undef>.

=head2 register_command( $cmd )

    # Register by name...
    $command_object = $app->register_command( $command_name );

    # ...or register by object reference...
    $command_object = CLI::Framework::Command->new( ... );
    $app->register_command( $command_object );

Register a command to be recognized by the application.  This method accepts
either the name of a command or a reference to a L<CLI::Framework::Command>
object.

If C<$cmd> is a L<CLI::Framework::Command> object and it is one of the command
types specified in L<command_map|/command_map()> to be valid, the command
object is registered and returned.

If C<$cmd> is the name of a valid command specified in
L<command_map|/command_map()>, an object of the corresponding command class is
registered and returned.

If C<$cmd> is not recognized, an exception is thrown.

=head2 get_default_command() / set_default_command( $default_cmd )

C<get_defualt_command()> retrieves the name of the command that is currently
set as the default command for the application.

    my $default_command = $app->get_default_command();

Given a command name, C<set_default_command> makes it the default command for
the application.

    $app->set_default_command( 'jump' );

=head2 get_current_command() / set_current_command( $current )

C<get_current_command> returns the name of the current command (or the one that
was most recently run).

    $status = $app->run();
    print 'The command named: ', $app->get_current_command(), ' was just run';

Given a command name, C<set_current_command> forwards execution to that command.
This might be useful (for instance) to "redirect" to another command.

    $app->set_current_command( 'fly' );

=head2 get_default_usage() / set_default_usage( $default_usage )

The "default usage" message is used as a last resort when usage information is
unavailable by other means.  See L<usage|/usage( $command_name, @subcommand_chain )>.

C<get_default_usage> gets the default usage message for the application.

    $usage_msg = $app->get_default_usage();

C<set_default_usage> sets the default usage message for the application.

    $app->set_default_usage( $usage_message );

=head1 PARSING & RUNNING COMMANDS

=head2 usage( $command_name, @subcommand_chain )

    # Application usage...
    print $app->usage();

    # Command-specific usage...
    $command_name = 'task';
    @subcommand_chain = qw( list completed );
    print $app->usage( $command_name, @subcommand_chain );

Returns a usage message for the application or a specific (sub)command.

If a command name is given (optionally with subcommands), returns a usage
message string for that (sub)command.  If no command name is given or if no
usage message is defined for the specified (sub)command, returns a general usage
message for the application.

Here is how the usage message is produced:

=over

=item *

If a valid command name (or alias) is given, attempt to get a usage message from
the command (this step takes into account C<@subcommand_chain> so that a
subcommand usage message will be shown if applicable); if no usage message is
defined for the command, use the application usage message instead.

=item *

If the application object has defined L<usage_text|/usage_text()>, use its
return value as the usage message.

=item *

Finally, fall back to using the default usage message returned by
L<get_default_usage|/get_default_usage() / set_default_usage( $default_usage )>.

B<Note>: It is advisable to define usage_text because the default usage
message, produced via Getopt::Long::Descriptive, is terse and is not
context-specific to the command request.

=back

=head2 cache()

CLIF Applications may have the need to share data between individual CLIF
Commands and the Application object itself.  C<cache()> provides a way for this
data to be stored, retrieved, and shared between components.

    $cache_object = $app->cache();

C<cache()> returns a cache object.  The following methods demonstrate usage of
the resulting object:

    $cache_object->get( 'key' );
    $cache_object->set( 'key' => $value );

B<Note>: The underlying cache class is currently limited to these rudimentary
features.  In the future, the object returned by C<cache()> may be changed to
an instance of a real caching class, such as L<CHI> (which would maintain
backwards compatibility but offer expiration, serialization, multiple caching
backends, etc.).

=head2 run()

    # as class method:
    My::App->run();

    # as object method (when having an object reference to call other methods
    # is desirable):
    my $app = My::App->new();
    $app->run();

    ...

    # Explicitly specify whether or not initialization should be done:
    $app->run( initialize => 0 );

This method controls the request processing and dispatching of a single
command.  It takes its input from @ARGV (which may be populated by a
script running non-interactively on the command line) and dispatches the
indicated command, capturing its return value.  The command's return value
represents the output produced by the command.  This value is passed to
L<render|/render( $output )> for final display.

If errors occur, they result in exceptions that are handled by
L<handle_exception|/handle_exception( $e )>.

The following parameters are accepted:

C<initialize>: This controls whether or not application initialization (via
L<init|/init( $options_hash )>) should be performed.  If not specified,
initialization is performed upon the first call to C<run>.  Should there be
subsequent calls, initialization is not repeated.  Passing C<initialize>
explicitly can modify this behavior.

=head1 INTERACTIVITY

=head2 get_interactivity_mode() / set_interactivity_mode( $is_interactive )

C<get_interactivity_mode> returns a true value if the application is in an
interactive state and a false value otherwise.

    print "running interactively" if $app->get_interactivity_mode();

C<set_interactivity_mode> sets the interactivity state of the application.  One
parameter is recognized: a true or false value to indicate whether the
application state should be interactive or non-interactive, respectively.

    $app->set_interactivity_mode(1);

=head2 is_interactive_command( $command_name )

    $help_command_is_interactive = $app->is_interactive_command( 'help' );

Returns a true value if there is a valid command with the specified name that
is an interactive command (i.e. a command that is enabled for this application
in interactive mode).  Returns a false value otherwise.

=head2 get_interactive_commands()

    my @interactive_commands = $app->get_interactive_commands();

Return a list of all commands that are to be available in interactive mode
("interactive commands").

=head2 run_interactive( [%param] )

    MyApp->run_interactive();

    # ...or as an object method:
    $app->run_interactive();

Start an event processing loop to prompt for and run commands in sequence.  The
C<menu> command is used to display available command selections (the built-in
C<menu> command, L<CLI::Framework::Command::Menu>, will be used unless the
application defines its own C<menu> command).

Within this loop, valid input is the same as in non-interactive mode except
that application options are not accepted (any application options should be
handled upon application initialization and before the interactive B<command>
loop is entered -- see the description of the C<initialize> parameter below).

The following parameters are recognized:

C<initialize>: causes any application options that are present in C<@ARGV> to be
procesed/validated and causes L<init|/init( $options_hash )> to be invoked
prior to entering the interactive event loop to recognize commands.  If
C<run_interactive()> is called after application options have already been
handled, this parameter can be omitted.

C<invalid_request_threshold>: the number of unrecognized command requests the
user can enter before the menu is re-displayed.

=head2 get_prompt() / set_prompt( $prompt, $preput )

C<get_prompt()> returns the current values of prompt and text preput.

    my ($prompt, $preput) = $app->get_prompt();

C<set_prompt()> sets the current values of prompt and text preput to user
input (if any), which will be used on the subsequent prompts for user input.

    $app->set_prompt( $needsave ? 'mycli(modified)> ' : 'mycli> ' );

Both parameters are optional, by default C<'E<gt> '> is used for prompt, and
C<$preput> is empty.

=head2 ornaments( $rl_term_set )

    $app->ornaments('md,me,,');     # make the prompt bold face

A wrapper of the function with the same name from L<Term::ReadLine> to set
formatting of the command line by using termcap data.

=head2 read_cmd()

    $app->read_cmd();

This method is responsible for retrieving a command request and placing the
user input into C<@ARGV>.  It is called in void context.

The default implementation uses L<Term::ReadLine> to prompt the user and read a
command request, supporting command history.

Subclasses are free to override this method if a different means of
accepting user input is desired.  This makes it possible to read command
selections without assuming that the console is being used for I/O.

=head2 is_quit_signal()

    until( $app->is_quit_signal(read_string_from_user()) ) { ... }

Given a string, return a true value if it is a quit signal (indicating that
the application should exit) and a false value otherwise.
L<quit_signals|/quit_signals()> is an application subclass hook that
defines what strings signify that the interactive session should exit.

=head2 ask_yesno( $question, $yes, $no, $retries )

    my $answer = $app->ask_yesno( "Really delete this?" );

This method is suitable for metacommands needing a confirmation from user
for action to proceed.  The user is asked with C<$question> and must type
string equal to either C<$yes> or C<$no> (defaults to C<"Yes"> and C<"No">
if not supplied), case-insensitive.  For compatibility (e.g. user has a
locale problems) just plain Latin C<y> or C<n> are always accepted.

Returns true value if user answered positively and false value if user
answered negatively.  If user input was neither C<$yes> nor C<$no>, user is
explicitly asked to re-enter answer.  If user's input was not recognized
after C<$retries> times (defaults to 1), C<undef> is returned.

=head2 ask_password( $question, $reenter, $retries )

    my $pass = $app->ask_password();

Allows metacommands to ask user to enter password which is not displayed on
the screen, using GNU Readline's feature of masking entered characters with
asterisks.  User is prompted using C<$question> (C<"Enter password:">
by default) and then is prompted again with C<$reenter> (C<"Retype passsword:">
by default), to catch spelling errors.  If two passwords mismatch, procedure
is retried for C<$retries> times (default 1).

Returns entered password, or C<undef> if entered strings still mismatch after
all retries.

If one wants to just ask password one time for checking, not setting purposes,
then C<$retries> should be passed negative value and C<$reenter> argument
will be ignored (won't be prompted again).

=head1 SUBCLASS HOOKS

There are several hooks that allow CLIF applications to influence the command
execution process.  This makes customizing the critical aspects of an
application as easy as overriding methods.

Except where noted, all hooks are optional -- subclasses may choose not to
override them (in fact, runnable CLIF applications can be created with very
minimal subclasses).

=head2 init( $options_hash )

This hook is called in void context with one parameter:

C<$options_hash> is a hash of pre-validated application options received and
parsed from the command line.  The options hash has already been checked
against the options defined to be accepted by the application in
L<option_spec|/option_spec()>.

This method allows CLIF applications to perform any common
initialization tasks that are necessary regardless of which command is to be
run.  Some examples of this include connecting to a database and storing a
connection handle in the shared L<cache|/cache()> slot for use by individual
commands, setting up a logging facility that can be used by each command by
storing a logging object in the L<cache|/cache()>, or initializing settings from
a configuration file.

=head2 pre_dispatch( $command_object )

This hook is called in void context.  It allows applications to perform actions
after each command object has been prepared for dispatch but before the command
dispatch actually takes place.  Its purpose is to allow applications to do
whatever may be necessary to prepare for running the command.  For example, a
log entry could be inserted in a database to store a record of every command
that is run.

=head2 pre_prompt()

This hook is called in void context.  It allows applications to perform actions
just before displaying next command prompt to user.  For example, a prompt
could be changed with L<C<set_prompt()>|/get_prompt() / set_prompt( $prompt, $preput )>
according to applicatopn state and result of running previous command.

=head2 option_spec()

An example definition of this hook is as follows:

    sub option_spec {
        [ 'verbose|v'   => 'be verbose'         ],
        [ 'logfile=s'   => 'path to log file'   ],
    }

This method should return an option specification as expected by
L<Getopt::Long::Descriptive|Getopt::Long::Descriptive/opt_spec>.  The option
specification defines what options are allowed and recognized by the
application.

=head2 validate_options( $options_hash )

This hook is called in void context.  It is provided so that applications can
perform validation of received options.

C<$options_hash> is an options hash parsed from the command-line.

This method should throw an exception if the options are invalid (throwing the
exception using C<die()> is sufficient).

B<Note> that L<Getopt::Long::Descriptive>, which is used internally for part of
the options processing, will perform some validation of its own based on the
L<option_spec|/option_spec()>.  However, the C<validate_options> hook allows for
additional flexibility in validating application options.

=head2 command_map()

Return a mapping between command names and Command classes (classes that inherit
from L<CLI::Framework::Command>).  The mapping is a list of key-value pairs.
The list should be "hash-worthy", meaning that it can be directly converted to
a hash.

Note that the order of the commands in this list determines the order that the
commands are displayed in the built-in interactive menu.

The keys are names that should be used to install the commands in the
application.  The values are the names of the packages that implement the
corresponding commands, as in this example:

    sub command_map {
        # custom commands:
        fly     => 'My::Command::Fly',
        run     => 'My::Command::Run',

        # overridden built-in commands:
        menu    => 'My::Command::Menu',

        # built-in commands:
        help    => 'CLI::Framework::Command::Help',
        list    => 'CLI::Framework::Command::List',
        tree    => 'CLI::Framework::Command::Tree',
        'dump'  => 'CLI::Framework::Command::Dump',
        console => 'CLI::Framework::Command::Console',
        alias   => 'CLI::Framework::Command::Alias',
    }

=head2 command_alias()

This hook allows aliases for commands to be specified.  The aliases will be
recognized in place of the actual command names.  This is useful for setting
up shortcuts to longer command names.

C<command_alias> should return a "hash-worthy" list where the keys are aliases
and the values are command names.

An example of its definition:

    sub command_alias {
        h   => 'help',
        l   => 'list',
        ls  => 'list',
        sh  => 'console',
        c   => 'console',
    }

=head2 noninteractive_commands()

    sub noninteractive_commands { qw( console menu ) }

Certain commands do not make sense to run interactively (e.g. the "console"
command, which itself puts the application into interactive mode).  This method
should return a list of their names.  These commands will be disabled during
interactive mode.  By default, all commands are interactive commands except for
C<console> and C<menu>.

=head2 quit_signals()

    sub quit_signals { qw( q quit exit ) }

An application can specify exactly what input represents a request to end an
interactive session.  By default, the example definition above is used.

=head2 handle_exception( $e )

    sub handle_exception {
        my ($app, $e) = @_;

        # Handle the exception represented by object $e...
        $app->my_error_logger( error => $e->error, pid => $e->pid, gid => $e->gid, ... );

        warn "caught error ", $e->error, ", continuing...";
        return;
    }

Error conditions are caught by CLIF and forwarded to this exception handler.
It receives an exception object (see L<Exception::Class::Base> for methods
that can be called on the object).

If not overridden, the default implementation extracts the error message from
the exception object and processes it through the L<render|/render( $output )>
method.

=head2 render( $output )

    $app->render( $output );

This method is responsible for presentation of the result from a command.
The default implementation simply attempts to print the C<$output> scalar,
assuming that it is a string.

Subclasses are free to override this method to provide more
sophisticated behavior such as processing the C<$output> scalar through a
templating system.

=head2 usage_text()

    sub usage_text {
        q{
        OPTIONS
            -v --verbose : be verbose
            -h --help    : show help
    
        COMMANDS
            tree        - print a tree of only those commands that are currently-registered in your application
            menu        - print command menu
            help        - show application or command-specific help
            console     - start a command console for the application
            list        - list all commands available to the application
        }
    }

To provide application usage information, this method may be overridden.  It
accepts no parameters and should return a string containing a useful help
message for the overall application.

Overriding this method is encouraged in order to provide a better usage
message than the default.  See
L<usage|/usage( $command_name, @subcommand_chain )>.

=head1 ERROR HANDLING IN CLIF

Internally, CLIF handles errors by throwing exceptions.  

The L<handle_exception|/handle_exception( $e )> method provides an opportunity
for customizing the way errors are treated in a CLIF application.

Application and Command class hooks such as
L<validate_options|/validate_options( $options_hash )>
and L<validate|CLI::Framework::Command/validate( $cmd_opts, @args )> are
expected to indicate success or failure by throwing exceptions (via C<die()> or
something more elaborate, such as exception objects).

=head1 CONFIGURATION & ENVIRONMENT

For interactive usage, L<Term::ReadLine> is used by default.  Depending on which
readline libraries are available on your system, your interactive experience
will vary (for example, systems with GNU readline can benefit from a command
history buffer).

=head1 DEPENDENCIES

L<Exception::Class::TryCatch>

L<Getopt::Long::Descriptive>

L<Text::ParseWords> (only for interactive use)

L<Term::ReadLine> (only for interactive use)

L<CLI::Framework::Exceptions>

L<CLI::Framework::Command>

=head1 DEFECTS AND LIMITATIONS

No known bugs.

=head1 PLANS FOR FUTURE VERSIONS

=over

=item *

Command-line completion of commands in interactive mode

=item *

Features to make it simpler to use templates for output

=item *

Features to instantly web-enable your CLIF Applications, making them
accessible via a "web console"

=item *

Better automatic usage message generation

=item *

An optional inline automatic class generation interface similar to that of
L<Exception::Class> that will make the simple "inline" form of usage even
more compact

=back

=head1 SEE ALSO

L<CLI::Framework>

L<CLI::Framework::Command>

L<CLI::Framework::Tutorial>

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2009 Karl Erisman (kerisman@cpan.org). All rights reserved.

This is free software; you can redistribute it and/or modify it under the same
terms as Perl itself. See perlartistic.

=head1 AUTHOR

Karl Erisman (kerisman@cpan.org)

=cut
