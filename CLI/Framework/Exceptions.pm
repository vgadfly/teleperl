package CLI::Framework::Exceptions;

use strict;
use warnings;

our $VERSION = 0.02;

# Make it possible to use aliases directly in client code...
use Exporter qw( import );
our @EXPORT_OK = qw(
    throw_clif_exception
    throw_app_hook_exception
    throw_app_opts_parse_exception
    throw_app_opts_validation_exception
    throw_app_init_exception
    throw_invalid_cmd_exception
    throw_cmd_registration_exception
    throw_type_exception
    throw_cmd_opts_parse_exception
    throw_cmd_validation_exception
    throw_cmd_run_exception
);

our %EXPORT_TAGS = ( all => \@EXPORT_OK );

# Create exception class hierarchy...
use Exception::Class (
    'CLI::Framework::Exception' => {
        description =>  'General CLIF error',
        alias       =>  'throw_clif_exception',
    },
    'CLI::Framework::Exception::AppHookException' => {
        isa         => 'CLI::Framework::Exception',
        description => 'Application hook method failed preconditions',
        alias       => 'throw_app_hook_exception',
    },
    'CLI::Framework::Exception::AppOptsParsingException' => {
        isa         => 'CLI::Framework::Exception',
        description => 'Failed parsing of application options',
        alias       => 'throw_app_opts_parse_exception'
    },
    'CLI::Framework::Exception::AppOptsValidationException' => {
        isa         => 'CLI::Framework::Exception',
        description => 'Failed validation of application options',
        alias       => 'throw_app_opts_validation_exception'
    },
    'CLI::Framework::Exception::AppInitException' => {
        isa         => 'CLI::Framework::Exception',
        description => 'Failed application initialization',
        alias       => 'throw_app_init_exception'
    },
    'CLI::Framework::Exception::InvalidCmdException' => {
        isa         => 'CLI::Framework::Exception',
        description => 'Invalid command',
        alias       => 'throw_invalid_cmd_exception'
    },
    'CLI::Framework::Exception::CmdRegistrationException' => {
        isa         => 'CLI::Framework::Exception',
        description => 'Failed command registration',
        alias       => 'throw_cmd_registration_exception',
    },
    'CLI::Framework::Exception::TypeException' => {
        isa         => 'CLI::Framework::Exception',
        description => 'Object is not of the proper type',
        alias       => 'throw_type_exception',
    },
    'CLI::Framework::Exception::CmdOptsParsingException' => {
        isa         => 'CLI::Framework::Exception',
        description => 'Failed parsing of command options',
        alias       => 'throw_cmd_opts_parse_exception'
    },
    'CLI::Framework::Exception::CmdValidationException' => {
        isa         => 'CLI::Framework::Exception',
        description => 'Failed validation of command options/arguments',
        alias       => 'throw_cmd_validation_exception'
    },
    'CLI::Framework::Exception::CmdRunException' => {
        isa         => 'CLI::Framework::Exception',
        description => 'Failure to run command',
        alias       => 'throw_cmd_run_exception'
    },
);

#-------
1;

__END__

=pod

=head1 NAME

CLI::Framework::Exceptions - Exceptions used by CLIF

=head1 EXCEPTION TYPES

This package defines the following exception types.  These exception objects
are created using L<Exception::Class> and are subtypes of
L<Exception::Class::Base>.

=head2 CLI::Framework::Exception

=over

=item description

General CLIF error

=item alias

C<throw_clif_exception>

=back

=head2 CLI::Framework::Exception::AppHookException

=over

=item description

Application hook method failed preconditions

=item alias

C<throw_app_hook_exception>

=back

=head2 CLI::Framework::Exception::AppOptsParsingException

=over

=item description

Failed parsing of application options

=item alias

C<throw_app_opts_parse_exception>

=back

=head2 CLI::Framework::Exception::AppOptsValidationException

=over

=item description

Failed validation of application options

=item alias

C<throw_app_opts_validation_exception>

=back

=head2 CLI::Framework::Exception::AppInitException

=over

=item description

Failed application initialization

=item alias

C<throw_app_init_exception>

=back

=head2 CLI::Framework::Exception::InvalidCmdException

=over

=item description

C<Invalid command>

=item alias

C<throw_invalid_cmd_exception>

=back

=head2 CLI::Framework::Exception::CmdRegistrationException

=over

=item description

Failed command registration

=item alias

C<throw_cmd_registration_exception>

=back

=head2 CLI::Framework::Exception::TypeException

=over

=item description

Object is not of the proper type

=item alias

C<throw_type_exception>

=back

=head2 CLI::Framework::Exception::CmdOptsParsingException

=over

=item description

Failed parsing of command options

=item alias

C<throw_cmd_opts_parse_exception>

=back

=head2 CLI::Framework::Exception::CmdValidationException

=over

=item description

Failed validation of command options/arguments

=item alias

C<throw_cmd_validation_exception>

=back

=head2 CLI::Framework::Exception::CmdRunException

=over

=item description

Failure to run command

=item alias

C<throw_cmd_run_exception>

=back

=head1 EXPORTS

All aliases are available for use by client code (but none are exported by
default).  The ':all' tag causes all of the C<alias>es to be exported.

=head1 SEE ALSO

L<Exception::Class>

L<CLI::Framework::Application>

=cut
