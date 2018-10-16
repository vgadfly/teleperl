package CLI::Framework;
use base qw( CLI::Framework::Application );

use strict;
use warnings;

our $VERSION = '0.05';

#-------
1;

__END__

=pod

=head1 NAME

CLI::Framework - Build standardized, flexible, testable command-line
applications

=head1 OVERVIEW

CLI::Framework ("CLIF") provides a framework and conceptual pattern
for building full-featured command line applications.  It intends to make this
process simple and consistent.  It assumes the responsibility of implementing
details that are common to all command-line applications, making it possible
for new applications adhering to well-defined conventions to be built without
the need to repeatedly write the same command-line interface code.

For instance, a complete application supporting commands and subcommands, with
options and arguments for the application itself as well as its commands, can
be built by writing concise, understandable code in packages that are easy to
test and maintain.  The classes can focus on implementation of unique aspects
essential to the command's purpose without being concerned with the many details
involved in building an interface around those commands.  This methodology for
building command-line applications also establishes a valuable standard for an
organization (or an individual developer).

=head1 LEARNING CLIF: RECOMMENDATIONS

CLIF has a rich set of features and offers many alternative approaches to
building applications, but if you are new to using it, you may want a succinct
introduction.  For this reason, the L<CLI::Framework::Tutorial> is provided
and is the recommended starting point.

After you gain a basic understanding, the other documents can be used as
references.

=head1 MOTIVATION

There are a few other distributions on CPAN intended to simplify building
modular command line applications.  I have not found any that meet my
requirements, which are documented in
L<DESIGN GOALS AND FEATURES|/DESIGN GOALS AND FEATURES>.

=head1 DESIGN GOALS AND FEATURES

CLIF was designed to offer the following features...

=over

=item *

A clear conceptual pattern for creating command-line applications

=item *

Guiding documentation and examples

=item *

Convenience for simple cases, flexibility for complex cases

=item *

Support for both non-interactive and interactive modes (with almost no
additional work -- define the necessary hooks and both modes will be supported)

=item *

A design that naturally encourages MVC applications: decouple data model,
control flow, and presentation

=item *

Commands that can be shared between applications (and uploaded to CPAN)

=item *

The possibility to share some components with MVC web applications

=item *

Validation of application options

=item *

Validation of command options and arguments

=item *

A model that encourages easily-testable applications

=item *

A flexible means to provide usage/help information for the application as a
whole and for individual commands

=item *

Support for subcommands that can be added as a natural extension to commands

=item *

Support for recursively-defined subcommands (sub-sub-...commands to any level
of depth)

=item *

Support for aliases to commands and subcommands

=item *

Allow Application and [sub]commands to be defined inline (some or all packages
involved may be defined in the same file) or split across multiple files

=item *

Support the concept of a default command for the application

=item *

Exception handling that allows individual applications to define custom
exception handlers

=item *

Performance.  Core framework code should load as quickly as a simple script;
individual commands should be initialized only when invoked.

=back

=head1 CONCEPTS AND DEFINITIONS

=over

=item *

Application Script - The wrapper program that invokes the CLIF Application's
L<run|CLI::Framework::Application/run()> method.  The file it is defined in may or may not also contain
the definition of Application or Command packages.

=item *

Metacommand - An application-aware command.  Metacommands are subclasses of
L<CLI::Framework::Command::Meta>.  They are identical to regular commands except
they hold a reference to the application within which they are running.  This
means they are able to "know about" and affect the application.  For example,
the built-in command "Menu" is a Metacommand because it needs to produce a
list of the other commands in its application.

In general, your commands should be designed to operate independently of the
application, so they should simply inherit from L<CLI::Framework::Command>.
This encourages looser coupling.  However, in exceptional cases, the use of
Metacommands is warranted (For an example, see the built-in "Menu" command).

=item *

Non-interactive Command - In interactive mode, some commands need to be
disabled.  For instance, the built-in "console" command (which is used to start
interactive mode, presenting a command menu and responding to user selections)
should not be presented as a menu option in interactive mode because it is
already running.  You can designate which commands are non-interactive by
overriding the
L<noninteractive_commands|CLI::Framework::Application/noninteractive_commands()>
method.

=item *

Registration of commands - Each CLIF application defines the commands it
will support.  These may be built-in CLIF commands or custom CLIF commands.
These commands are lazily "registered" as they are called upon for use.

=back

=head1 APPLICATION RUN SEQUENCE

When a command of the form:

    $ app [app-opts] <cmd> [cmd-opts] { <cmd> [cmd-opts] {...} } [cmd-args]

    examples:

            app      |             [app-opts]            { <cmd>       |   [cmd-opts]    } [cmd-args]
    `````````````````|```````````````````````````````````|`````````````|`````````````````|``````````````
    $ examples/queue |--qin=/tmp/qfile --qout=/tmp/qfile | enqueue     | --tag=x --tag=y | 'item'
    `````````````````|```````````````````````````````````|`````````````|`````````````````|``````````````
    $ gen-report     |              --html               | stats       |  --role=admin   |
                     |                                   | usage       |   --time='2d'   | '/tmp/stats.html'
    ````````````````````````````````````````````````````````````````````````````````````````````````````

...causes your application script, <app>, to invoke the
L<run|CLI::Framework::Application/run()> method in your application class,
CLI::Framework::Application performs the following actions:

=over

=item 1

Parse the command request

=item 2

Validate application options

=item 3

Initialize application

=item 4

Prepare command

=item 5

Invoke command pre-dispatch hook

=item 6

Dispatch command

=back

These steps are explained in more detail below...

=head2 Request parsing

Parse the application options C<< [app-opts] >>, command name C<< <cmd> >>,
command options C<< [cmd-opts] >>, and the remaining part of the command line,
which includes command arguments C<< [cmd-args] >> for the last command and may
include multiple subcommands.  Everything between the inner brackets
(C<< { ... } >>) represents recursive subcommand processing -- the "C<...>"
represents another string of "C<< <cmd> [cmd-opts] {...} >>".

The second example above shows a command request that requires recursive
subcommand processing.  The command might cause an HTML report to be generated
with usage statistics for admin users (of some application) for the past two
days, writing the report to a file.  In one line, it would look like this:

    $ gen-report --html stats --role=admin usage --time='2d' '/tmp/stats.html'

This fictional gen-report application could be designed with such an interface
because it could offer various types of reports (as opposed to the statistics
report).  There might be other statistics reports (as opposed to 'usage').  The
stats might be available for users with other roles.  The usage report might
need to accept custom time frames.

CLIF allows you to choose whether various parts of your data should be supplied
as options or as arguments -- these interface decisions are left to your
discretion.  CLIF also makes it easy to validate command requests and to provide
usage information so users know what to change if a command request fails
validation.

In general, if a command request is not well-formed, it is replaced with the
default command and any arguments present are ignored.  The default command
prints a help or usage message (you may change this behavior if desired).

=head2 Validation of application options

Your application class can optionally define the
L<validate_options|CLI::Framework::Application/validate_options( $options_hash )>
method.

If your application class does not override this method, validation is
skipped -- any received options are considered to be valid.

=head2 Application initialization

Your application class can optionally override the
L<init|CLI::Framework::Application/init( $options_hash )> method.  This is a
hook that can be used to perform any application-wide initialization that needs
to be done independent of individual commands.  For example, your application
may use the L<init|CLI::Framework::Application/init( $options_hash )> method to
connect to a database and store a connection handle which may be needed by some
or all of the commands in your application.

=head2 Preparing the command

The requested command is now loaded (if not already done).
The command's L<cache|CLI::Framework::Command/SHARED CACHE DATA> is set (using
a reference to the same L<cache object|CLI::Framework::Application/cache()> used
by the application).

=head2 Command pre-dispatch

Your application class can optionally have a
L<pre_dispatch|CLI::Framework::Application/pre_dispatch( $command_object )>
method that is called with one parameter: the Command object that is about to be
dispatched.

=head2 Dispatching the command

CLIF uses the L<dispatch|CLI::Framework::Command/dispatch( $cmd_opts, @args )>
method to actually dispatch a specific command.  That method is responsible
for running the command or delegating responsibility to a subcommand, if
applicable.

=head1 INTERACTIVITY

After building your CLIF application, in addition to basic
non-interactive functionality, you will instantly benefit from the ability to
(optionally) run your application in interactive mode.  A readline-enabled
application command console with an event loop, a command menu, and built-in
debugging commands is provided by default.

Inside interactive mode, only steps 4, 5, and 6 above
(L<APPLICATION RUN SEQUENCE|/APPLICATION RUN SEQUENCE>) are performed for each
command request.

Supporting interactivity in your application is as simple as adding the
built-in command L<CLI::Framework::Command::Console> to your
L<command_map|CLI::Framework::Application/command_map()>.

=head1 BUILT-IN COMMANDS INCLUDED IN THIS DISTRIBUTION

This distribution comes with some default built-in commands, and more
CLIF built-ins can be installed as they become available on CPAN.

Use of the built-ins is optional in most cases, but certain features require
specific built-in commands (e.g. the Help command is a fundamental feature of
all applications and the Menu command is required in interactive mode).  You can
override any of the built-ins.

A new application that does not override the
L<command_map|CLI::Framework::Application/command_map()> hook will include all
of the built-ins listed below.

The existing built-ins and their corresponding packages are as follows:

=over

=item help: Print application or command-specific usage messages

L<CLI::Framework::Command::Help>

B<Note>: This command is registered automatically.  All CLIF applications must have
the "help" command defined (though this built-in can replaced by your subclass
to change the "help" command behavior or to do nothing if you specifically do
not want a help command).

=item list: Print a list of commands available to the running application

L<CLI::Framework::Command::List>

=item dump: Show the internal state of a running application

L<CLI::Framework::Command::Dump>

=item tree: Display a tree representation of the commands that are currently registered with the running application

L<CLI::Framework::Command::Tree>

=item alias: Display the command aliases that are in effect for the running application and its commands

L<CLI::Framework::Command::Alias>

=item console: Invoke CLIF's interactive mode

L<CLI::Framework::Command::Console>

=item menu: Show a command menu including the commands that are available to the running application

L<CLI::Framework::Command::Menu>

B<Note>: This command is registered automatically when an application runs in
interactive mode.  This built-in may be replaced by a user-defined "menu"
command, but any command class to be used for the "menu" command MUST be a
subclass of this one.

=back

=head1 CLIF ARCHITECTURE AT A GLANCE

The class diagram below shows the relationships of the major classes of
CLI Framework, including some of their methods.  This is not intended to be a
comprehensive diagram, only an aid to understanding CLIF at a glance.

=begin html

<p><center><img src="http://cpansearch.perl.org/src/KERISMAN/CLI-Framework-0.04/docs/images/cli-framework.jpg" alt="class diagram from docs/images dir" /></center></p>

=end html

=head1 SEE ALSO

L<CLI::Framework::Application>

L<CLI::Framework::Command>

L<CLI::Framework::Tutorial>

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2009 Karl Erisman (kerisman@cpan.org). All rights reserved.

This is free software; you can redistribute it and/or modify it under the same
terms as Perl itself. See perlartistic.

=head1 AUTHOR

Karl Erisman (kerisman@cpan.org)

=cut
