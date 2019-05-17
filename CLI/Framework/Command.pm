package CLI::Framework::Command;

use strict;
use warnings;
#use warnings::register;

our $VERSION = 0.04;

use Carp;
use Getopt::Long::Descriptive;
use Exception::Class::TryCatch;
use Class::Inspector;

use CLI::Framework::Exceptions qw( :all );

#FIXME-TODO-CLASS_GENERATION:
#our %CLASSES; # remember which classes have been auto-generated
#
#sub import {
#    my ($class, %import_args) = @_;
#
#    # If caller has supplied import args, CLIF's "inline form" is being used;
#    # we need to generate command classes dynamically...
#    while( my ($cmd_pkg, $cmd_def) = each %import_args ) {
#
##FIXME-TODO-CLASS_GENERATION: Create the new classes named in $cmd_pkg, injecting the subs indicated
## (whether explicitly or implicitly) by the contents of $cmd_def...
#
##        $cmd_obj = __PACKAGE__->new();
#    }
#}

###############################
#
#   OBJECT CONSTRUCTION
#
###############################

sub manufacture {
    my ($class, $target_pkg) = @_;

    # Manufacture base command...
    eval "require $target_pkg"; # (may or may not be pre-loaded)
    my $object = $target_pkg->new()
        or croak "Failed to instantiate command package '$target_pkg' via new(): $!";

    # Recognize subcommands that were defined in their own package files...
    $object->_manufacture_subcommands_in_dir_tree();

    # Recognize subcommands that have been loaded via an inline definition...
    $object->_register_preloaded_subcommands();

    return $object;
}

sub _manufacture_subcommands_in_dir_tree {
    my ($parent_command_object) = @_;

    # Check for a subdirectory by the name of the current command containing .pm
    # files representing subcommands, then manufacture() any that are found...

    # Look for subdirectory with name of current command...
    my $subcommand_dir = Class::Inspector->resolved_filename( ref $parent_command_object );
    substr( $subcommand_dir, -3, 3 ) = ''; # trim trailing '.pm'

    if( -d $subcommand_dir ) {
        # Directory with name of current command exists; look inside for .pm
        # files representing subcommands...

        my $dh;
        opendir( $dh, $subcommand_dir ) or die "cannot opendir '$dh': $!";
        while( my $subcommand = readdir $dh ) {
            # Ignore non-module files...
            next unless substr( $subcommand, -3 ) =~ s/\.pm//; # trim trailing '.pm'

            my $subcommand_pkg = (ref $parent_command_object).'::'.$subcommand;
            eval "require $subcommand_pkg";
            if( $subcommand_pkg->isa(ref $parent_command_object) ) {
                my $subcommand_obj = $subcommand_pkg->new()
                    or croak 'Failed to instantiate subcommand',
                             "'$subcommand_pkg' via method new(): $!";

                $parent_command_object->register_subcommand( $subcommand_obj );

                $subcommand_obj->_manufacture_subcommands_in_dir_tree();
                $subcommand_obj->_register_preloaded_subcommands();
            }
#            else {
#                warnings::warn "Found a non-subclass Perl package file in search path: '$subcommand_pkg' -- ignoring..."
#                    if warnings::enabled;
#            }
        }
    }
    return 1;
}

sub _register_preloaded_subcommands {
    my ($parent_cmd_obj) = @_;

    # Find direct subclasses and register them beneath the given parent...

    # Class::Inspector::subclasses actually finds all *descendants*
    # (not just direct subclasses)...
    my $descendants = sub { Class::Inspector->subclasses(@_) };
    my $descendant_names = $descendants->( ref $parent_cmd_obj );
    return unless ref $descendant_names eq 'ARRAY';

    for my $descendant_cmd ( @$descendant_names ) {
        # (skip if already registered)
        next if $parent_cmd_obj->package_is_registered( $descendant_cmd );

        # Find the direct parent class(es) of the descendant...
        my @direct_parents;
        {   no strict 'refs';
            @direct_parents = @{ $descendant_cmd.'::ISA' };
        }
        for my $direct_parent_of_descendant (@direct_parents) {
            # If the descendant is a *direct* subclass of the given parent...
            if( $direct_parent_of_descendant eq ref $parent_cmd_obj ) {
                # ...register child command as subcommand of parent...
                my $child_cmd = $descendant_cmd->new();
                $parent_cmd_obj->register_subcommand( $child_cmd );
                $child_cmd->_register_preloaded_subcommands();
            }
        }
    }
    return 1;
}

sub new { bless { _cache => undef }, $_[0] }

sub set_cache { $_[0]->{_cache} = $_[1] }
sub cache { $_[0]->{_cache} }

###############################
#
#   COMMAND DISPATCHING
#
###############################

sub get_default_usage { $_[0]->{_default_usage}         }
sub set_default_usage { $_[0]->{_default_usage} = $_[1] }

sub usage {
    my ($cmd, $subcommand_name, @subcommand_args) = @_;

    # Allow subcommand aliases in place of subcommand name...
    $cmd->_canonicalize($subcommand_name);

    my $usage_text;
    if(my $subcommand = $cmd->registered_subcommand_object($subcommand_name)) {
        # Get usage from subcommand object...
        $usage_text = $subcommand->usage(@subcommand_args);
    }
    else {
        # Get usage from Command object...
        $usage_text = $cmd->usage_text();
    }
    # Finally, fall back to default command usage message...
    $usage_text ||= $cmd->get_default_usage();
    return $usage_text;
}

sub _canonicalize {
    my ($cmd, $input) = @_;

    # Translate shorthand aliases for subcommands to full names...

    return unless $input;

    my %aliases = $cmd->subcommand_alias();
    return unless %aliases;

    my $command_name = $aliases{$input} || $input;
    $_[1] = $command_name;
}

#
# ARGV_Format
#
# $ app [app-opts] <cmd> [cmd-opts] <the rest>
#
# params contain: $cmd = <cmd>, $cmd_opts = [cmd-opts], @args = <the rest>
#
# <the rest> could, in turn, indicate nested subcommands:
#   { <subcmd> [subcmd-opts] {...} } [subcmd-args]
#

sub dispatch {
    my ($cmd, $cmd_opts, @args) = @_;

    # --- VALIDATE COMMAND OPTIONS AND ARGS ---
    eval { $cmd->validate($cmd_opts, @args) };
    if( catch my $e ) { # (command failed validation)
        throw_cmd_validation_exception( error => $e );
    }
    # Check if a subcommand is being requested...
    my $first_arg = shift @args; # consume potential subcommand name from input
    $cmd->_canonicalize( $first_arg );
    my ($subcmd_opts, $subcmd_usage);
    if( my $subcommand = $cmd->registered_subcommand_object($first_arg) ) {
        # A subcommand is being requested; parse its options...
        @ARGV = @args;
        my $format = $cmd->name().' '.$subcommand->name().' %o ...';
        eval { ($subcmd_opts, $subcmd_usage) =
            describe_options( $format, $subcommand->option_spec(),
                CLI::Framework::Application::_getopt_conf($subcommand) )
        };
        if( catch my $e ) { # (subcommand failed options parsing)
            $e->isa( 'CLI::Framework::Exception' ) && do{ $e->rethrow };
            throw_cmd_opts_parse_exception( error => $e );
        }
        $subcommand->set_default_usage( $subcmd_usage->text() );

        # Reset arg list to reflect only arguments ( options may have been
        # consumed by describe_options() )...
        @args = @ARGV;

        # Pass session data to subcommand...
        $subcommand->set_cache( $cmd->cache() );

        # --- NOTIFY MASTER COMMAND OF SUBCOMMAND DISPATCH ---
        $cmd->notify_of_subcommand_dispatch( $subcommand, $cmd_opts, @args );

        # Dispatch subcommand with its options and the remaining args...
        $subcommand->dispatch( $subcmd_opts, @args );
    }
    else {
        # If first arg is not a subcommand then put it back in input...
        unshift @args, $first_arg if defined $first_arg;

        # ...and run the command itself...
        my $output;
        eval { $output = $cmd->run( $cmd_opts, @args ) };
        if( catch my $e ) { # (error during command execution)
            $e->isa( 'CLI::Framework::Exception' ) && do{ $e->rethrow };
            throw_cmd_run_exception( error => $e );
        }
        return $output;
    }
}

###############################
#
#   COMMAND REGISTRATION
#
###############################

sub registered_subcommand_names { keys %{$_[0]->{_subcommands}} }

sub registered_subcommand_object {
    my ($cmd, $subcommand_name) = @_;

    return unless $subcommand_name;

    return $cmd->{_subcommands}->{$subcommand_name};
}

sub register_subcommand {
    my ($cmd, $subcommand_obj) = @_;

    return unless $subcommand_obj &&
        $subcommand_obj->isa("CLI::Framework::Command");

    my $subcommand_name = $subcommand_obj->name();
    $cmd->{_subcommands}->{$subcommand_name} = $subcommand_obj;

    return $subcommand_obj;
}

sub package_is_registered {
    my ($cmd, $pkg) = @_;
    my @registered_pkgs = map { ref $_ } values %{ $cmd->{_subcommands} };
    return grep { $pkg eq $_ } @registered_pkgs;
}

###############################
#
#   COMMAND SUBCLASS HOOKS
#
###############################

sub name {
    my ($cmd) = @_;

    # Use base name of package as command name...
    my $pkg = ref $cmd;
    my @pkg_parts = split /::/, $pkg;
    return lc $pkg_parts[-1];
}

sub getopt_conf { }

sub option_spec { ( ) }

sub subcommand_alias { ( ) }

sub validate { }

sub notify_of_subcommand_dispatch { }

sub usage_text { }

sub run { $_[0]->usage() }

#-------
1;

__END__

=pod

=head1 NAME

CLI::Framework::Command - CLIF Command superclass

=head1 SYNOPSIS

    # The code below shows a few of the methods your command classes are likely
    # to override...

    package My::Journal::Command::Search;
    use base qw( CLI::Framework::Command );

    sub usage_text { q{
        search [--titles-only] <search regex>: search a journal
    } }

    sub option_spec { (
        [ 'titles-only' => 'search only journal titles' ],
    ) }

    sub validate {
        my $self, $opts, @args) = @_;
        die "exactly one argument required (search regex)" unless @args == 1;
    }

    sub run {
        my ($self, $opts, @args) = @_;

        my $db = $self->cache->get( 'db' )

        # perform search against $db...
        # $search_results = ...

        return $search_results;
    }

=head1 DESCRIPTION

CLI::Framework::Command (command class for use with
L<CLI::Framework::Application>) is the base class for CLIF commands.  All CLIF
commands inherit from this class.

=head1 CONCEPTS

=over

=item Subcommands

Commands can have "subcommands," which are also objects of
CLI::Framework::Command.  Subcommands can, in turn, have their own
subcommands, and this pattern may repeat indefinitely.

B<Note> that in this documentation, the term "command" may be used to refer to both
commands and subcommands.

=item Registration of subcommands

Subcommands are "registered" with their parent commands.  The parent commands
can then forward subcommand responsibilities as appropriate.

=item File-based commands vs. inline commands

Command classes (which inherit from CLI::Framework::Command) can be defined in
their own package files or they may be declared inline in another package
(e.g. a command package file could include the declaration of a subcommand
package or command packages could be declared inline in the package file where
the application is declared).  As long as the classes have been loaded (making
their way into the symbol table), CLIF can use the commands.

=back

=head1 OBJECT CONSTRUCTION

=head2 manufacture( $command_package )

    # (manufacture MyApp::Command::Go and any subcommand trees beneath it)
    my $go = CLI::Framework::Command->manufacture( 'MyApp::Command::Go' );

CLI::Framework::Command is an abstract factory; C<manufacture()> is the factory
method that constructs and returns an object of the specific command class that
is requested.

After instantiating an object of the requested command package, C<manufacture()>
attempts to load subcommands in the following 2 steps:

=over

=item 1

Attempt to find package B<files> representing subcommands.  For every
subcommand S, S is registered as a child of the parent command.  Next,
steps 1 and 2 repeat, this time being invoked on S (i.e. with S as the parent
in an attempt to find subcommands of S).

=item 2

Attempt to find and register pre-compiled subcommands defined B<inline>.  Only
pre-compiled subcommands are considered for registration (i.e. package files are
not considered in this step).  For every subcommand S, any pre-compiled
subcommands that inherit B<directly> from S are found and step 2 repeats for
those classes.

=back

Note the following rules about command class definition:

=over

=item *

If a command class is defined inline, its subcommand classes must be defined inline as well.

=item *

If a command class is file-based, each of its subcommand classes can be either file-based or inline.  Furthermore, it is not necessary for all of these subcommand classes to be defined in the same way -- a mixture of file-based and inline styles can be used for the subcommands of a given command.

=back

=head2 new()

    $object = $cli_framework_command_subclass->new();

Basic constructor.

=head1 SHARED CACHE DATA

CLIF commands may need to share data with other commands and with their
associated application.  These methods support those needs.

=head2 set_cache( $cache_object )

Set the internal cache object for this instance.

See L<cache|CLI::Framework::Application/cache()>.

=head2 cache()

Retrieve the internal cache object for this instance.

See L<cache|CLI::Framework::Application/cache()> for an explanation of how to
use this simple cache object.

=head1 COMMAND DISPATCHING

=head2 get_default_usage() / set_default_usage( $default_usage_text )

Get or set the default usage message for the command.  This message is used
by L<usage|/usage( $subcommand_name, @subcommand_chain )>.

B<Note>: C<get_default_usage()> merely retrieves the usage data that has already
been set.  CLIF only sets the default usage message for a command when
processing a run request for the command.  Therefore, the default usage message
for a command may be empty (if a run request for the command has not been
given and you have not otherwise set the default usage message).

    $cmd->set_default_usage( ... );
    $usage_msg = $cmd->get_default_usage();

=head2 usage( $subcommand_name, @subcommand_chain )

    # Command usage...
    print $cmd->usage();

    # Subcommand usage (to any level of depth)...
    $subcommand_name = 'list';
    @subcommand_chain = qw( completed );
    print $cmd->usage( $subcommand_name, @subcommand_chain );

Attempts to find and return a usage message for a command or subcommand.

If a subcommand is given, returns a usage message for that subcommand.  If no
subcommand is given or if the subcommand cannot produce a usage message,
returns a general usage message for the command.

Logically, here is how the usage message is produced:

=over

=item *

If registered subcommand(s) are given, attempt to get usage message from a
subcommand (B<Note> that a sequence of subcommands could be given, e.g.
C<< $cmd->usage('list' 'completed') >>, which would result in the usage
message for the final subcommand, C<'completed'>).  If no usage message is
defined for the subcommand, the usage message for the command is used instead.

=item *

If the command has implemented L<usage_text|/usage_text()>, its return value is
used as the usage message.

=item *

Finally, if no usage message has been found, the default usage message produced
by L<get_default_usage|CLI::Framework::Application/get_default_usage() / set_default_usage( $default_usage )>
is returned.

=back

=head2 dispatch( $cmd_opts, @args )

For the given command request, C<dispatch> performs any applicable validation
and initialization with respect to supplied options C<$cmd_opts> and arguments
C<@args>, then runs the command.

C<@args> may indicate the request for a subcommand:

    { <subcmd> [subcmd-opts] {...} } [subcmd-args]

...as in the following command (where "usage" is the <subcmd>):

    $ gen-report --html stats --role=admin usage --time='2d' '/tmp/stats.html'

If a subcommand registered under the indicated command is requested,
the subcommand is initialized and dispatched with its options
C<[subcmd-opts]> and arguments.  Otherwise, the command itself is run.

This means that a request for a subcommand will result in the C<run>
method of only the deepest-nested subcommand (because C<dispatch> will keep
forwarding to successive subcommands until the args no longer indicate that a
subcommand is requested).  Furthermore, the only command that can receive args
is the final subcommand in the chain (but all commands in the chain can receive
options).  However, B<Note> that each command in the chain can affect the
execution process through its
L<notify_of_subcommand_dispatch|/notify_of_subcommand_dispatch( $subcommand, $cmd_opts, @args )>
method.

=head1 COMMAND REGISTRATION

=head2 registered_subcommand_names()

    @registered_subcommands = $cmd->registered_subcommand_names();

Return a list of the currently-registered subcommands.

=head2 registered_subcommand_object( $subcommand_name )

    $subcmd_obj = $cmd->registered_subcommand_object( 'lock' );

Given the name of a registered subcommand, return a reference to the
subcommand object.  If the subcommand is not registered, returns undef.

=head2 register_subcommand( $subcmd_obj )

    $cmd->register_subcommand( $subcmd_obj );

Register C<$subcmd_obj> as a subcommand under master command C<$cmd>.

If C<$subcmd_obj> is not a CLI::Framework::Command, returns undef.  Otherwise,
returns C<$subcmd_obj>.

=head2 package_is_registered( $package_name )

Return a true value if the named class is registered as a subcommand.  Returns
a false value otherwise.

=head2 name()

    $s = My::Command::Squeak->new();
    $s->name();    # => 'squeak'

C<name()> takes no arguments and returns the name of the command.  This method uses the normalized base name of the package as the command name, e.g. the command defined by the package My::Application::Command::Xyz would be named 'xyz'.

=head1 COMMAND SUBCLASS HOOKS

Just as CLIF Applications have hooks that subclasses can use, CLIF Commands are
able to influence the command dispatch process via several hooks.  Except
where noted, all hooks are optional -- subclasses may choose whether or not to
override them.

=head2 option_spec()

This method should return an option specification as expected by
L<Getopt::Long::Descriptive> (see
L<Getopt::Long::Descriptive|Getopt::Long::Descriptive/opt_spec>).  The option
specification is a list of arrayrefs that defines recognized options, types,
multiplicities, etc. and specifies textual strings that are used as
descriptions of each option:

    sub option_spec {
        [ "verbose|v"   => "be verbose"         ],
        [ "logfile=s"   => "path to log file"   ],
    }

Subclasses should override this method if commands accept options (otherwise,
the command will not recognize any options).

=head2 getopt_conf()

Returns list of words for L<Getopt::Long::Configure>, to be used in
addition to standard CLIF ones.

Subclasses should override this method only when something uncommon is needed,
e.g. to allow repeated specs like '=s@{3} one could use:

    sub getopt_conf { qw(no_bundling) }

=head2 subcommand_alias()

    sub subcommand_alias {
        rm  => 'remove',
        new => 'create',
        j   => 'jump',
        r   => 'run',
    }

Subcommands can have aliases to support shorthand versions of subcommand
names.

Subclasses should override this method if subcommand aliases are desired.
Otherwise, the subcommands will only be recognized by their full command names.

=head2 validate( $cmd_opts, @args )

To provide strict validation of a command request, a subclass may override
this method.  Otherwise, validation is skipped.

C<$cmd_opts> is an options hash with the received command options as keys and
their values as hash values.

C<@args> is a list of the received command arguments.

C<validate()> is called in void context.  It is expected to throw an exception
if validation fails.  This allows your validation routine to provide a
context-specific failure message.

B<Note> that Getop::Long::Descriptive performs some validation of its own based
on the L<option_spec|/option_spec()>.  However, C<validate()> allows more
flexibility in validating command options and also allows validation of
arguments.

=head2 complete_arg( $lastopt, $argnum, $text, $attribs, $rawARGV, @args )

    sub complete_arg {
        my ($self, $lastopt, $argnum, $text, $attribs) = @_;

        # readonly part of our model must be available after app->init() 
        my $model = $self->cache->get('model');

        if ($lastopt =~ /^--user$/ && $argnum == 1) {
            # accept usernames from /etc/passwd
            return $attribs->{username_completion_function};
        }

        if ($lastopt =~ /script/ && $argnum == 1) {
            # empty list for filename completion
            return ();
        }

        # first non-option arg must be partition and second - a template
        if ($argnum == 1) {
            return map { ($_->{id}, $_->{dev}) } $model->all_partitions();
        }
        elsif ($argnum == 2) {
            return map { ($_->{id}, $_->{label}) } $model->all_templates();
        }

        # explicitly forbid argument completion
        return undef;
    }

If application is run in interactive mode and GNU readline is available, CLIF
will automatically complete all (sub)command and option names when user hits
TAB, showing proper lists of available completions, as your hierarchy defines.
You may want go further and offer a completions of arguments specific to your
subcommands, whose list then must be returned to CLIF by this hook.

Completion is complex to implement, however, because command line is
I<usually> incorrect at the moment of hitting the TAB key - user wants
B<you> to provide correct answers!  And you have not (yet) so much info and
may have to guess what is more appropriate for user to see right here
(e.g. just think about cursor moved to middle of the typed line and TAB
pressed here - we now don't know whetther words after cursor are to CLIF or
will be just args; so it's better to pretend there's nothing after)...

It makes sense to define this hook only in "leaf" subcommands of your
command hierarchy and, only for argument-taking options (defined like
C<file=s> in L<option_spec|/option_spec()>) of "intermediate" commands.

C<$text> is the partial word to be completed (where TAB is hit).

C<$lastopt> is the last seen option to command, or empty string if none.

C<$argnum> is the positional number of C<$text> after the C<$lastopt> (first
argument after option will have number 1), or just to your command itself,
if there were no options typed by user.  Given C<$argnum> and C<$lastopt>
value, you, as author knowing your options, can differentiate whether an
argument to option or to entire command is currently being completed.

C<$attribs> is a reference to a hash which describes internal configuration
(variables) of L<Term::ReadLine> object.  It is supposed you usually don't
need to use it except returning C<$attribs-E<gt>{username_completion_function}>,
because readline is tedious and sometimes fragile...

C<$rawARGV> is a reference to partial (up to, but not including, C<$text>) list
of the command and it's arguments and options received so far, already
tokenized (and upgraded to UTF-8, if possible) to array from raw string
by shell-like quotes and escapes, but not yet parsed to commands, options and
arguments.  Usually C<$lastopt>/C<$argnum> mechanism is enough, as you don't
need anything not related to your command, but metacommands may need more.

C<@args> is a part of C<$@rawARGV> filled with arguments/options just to your
last (sub)command (on which the hook is being called), that is, everything
after the word naming your command - while C<$rawARGV> holds everything from
the beginning of the command line, for rare cases you need access to data of
upper (ancestor) commands.

Based on all these, C<complete_arg> should not fail and return one of:

=over

=item *

A non-empty list of strings - candidates to complete.

=item *

Empty list - to tell GNU readline to use built-in filename completion.

=item *

A reference to generator function like L<Term::ReadLine::Gnu/C<completion_entry_function>>.
If all you want is to provide completion of system-wide usernames, just return
C<$attribs-E<gt>{username_completion_function}>.

=item *

C<undef> to prohibit completion in this place.

=back

=head2 notify_of_subcommand_dispatch( $subcommand, $cmd_opts, @args )

If a request for a subcommand is received, the master command itself does not
C<run()>.  Instead, its C<notify_of_subcommand_dispatch()> method is called.
This gives the master command a chance to act before the subcommand is run.

For example, suppose some (admittedly contrived) application, 'queue', has a
command hierarchy with multiple commands:

    enqueue
    dequeue
    print
    property
        constraint
            maxlen
        behavior
    ...

In this case, C<$ queue property constraint maxlen> might set the max length
property for a queue.  If the command hierarchy was built this way, C<maxlen>
would be the only command to C<run> in response to that request.  If
C<constraint>, the master command of C<maxlen>, needs to hook into this
execution path, C<notify_of_subcommand_dispatch()> could be overridden in the
command class that implements C<constraint>.  C<notify_of_subcommand_dispatch()>
would then be called just before C<dispatch>ing C<maxlen>.

The C<notify_of_subcommand_dispatch()> method is called in void context.

C<$subcommand> is the subcommand object.

C<$cmd_opts> is the options hash for the subcommand.

C<@args> is the argument list for the subcommand.

=head2 usage_text()

    sub usage_text {
        q{
        dequeue: remove item from queue
        }
    }

If implemented, this method should simply return a string containing usage
information for the command.  It is used automatically to provide
context-specific help.

Implementing this method is optional.  See
L<usage|CLI::Framework::Application/usage( $command_name, @subcommand_chain )>
for details on how usage information is generated within the context of a CLIF
application.

Users are encouraged to override this method.

=head2 run( $cmd_opts, @args )

This method is responsible for the main execution of a command.  It is
called with the following parameters:

C<$cmd_opts> is a pre-validated options hash with command options as keys and
their user-provided values as hash values.

C<@args> is a list of the command arguments.

The default implementation of this method simply calls
L<usage|/usage( $subcommand_name, @subcommand_chain )> to show help information
for the command.  Therefore, subclasses will usually override C<run()>
(Occasionally, it is useful to have a command that does little or nothing on
its own but has subcommands that define the real behavior.  In such occasional
cases, it may not be necessary to override C<run()>).

If an error occurs during the execution of a command via its C<run()> method,
the C<run()> method code should throw an exception.  The exception will be
caught and handled appropriately by CLIF.

The return value of C<run()> is treated as data to be processed by the
L<render|CLI::Framework::Application/render( $output )> method in your CLIF Application
class.  B<Note that nothing should be printed directly in your implementation of
C<run>>.  If no output is to be produced, your C<run()> method should return
C<undef> or empty string.

=head1 DIAGNOSTICS

=over

=item C<< Error: failed to instantiate command package '<command pkg>' via new() >>

L<manufacture|/manufacture( $command_package )> was asked to manufacture an object of class
<command pkg>, but failed while trying to invoke its constructor.

=item C<< Error: failed to instantiate subcommand '<class>' via method new() >>

Object construction for the subcommand <class> (whose package has already been
C<require()d>) was unsuccessful.

=item C<< cannot opendir <dir> >>

While trying to L<manufacture|/manufacture( $command_package )> subcommands in a directory tree,
calling C<opendir()> on the subdirectory with the name of the parent command
failed.

=back

=head1 CONFIGURATION & ENVIRONMENT

No special configuration requirements.

=head1 DEPENDENCIES

Carp

L<Getopt::Long::Descriptive>

L<Exception::Class::TryCatch>

L<Class::Inspector>

L<CLI::Framework::Exceptions>

=head1 SEE ALSO

L<CLI::Framework>

L<CLI::Framework::Application>

L<CLI::Framework::Tutorial>

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2009 Karl Erisman (kerisman@cpan.org). All rights reserved.

This is free software; you can redistribute it and/or modify it under the same
terms as Perl itself. See perlartistic.

=head1 AUTHOR

Karl Erisman (kerisman@cpan.org)

=cut
