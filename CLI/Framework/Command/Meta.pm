package CLI::Framework::Command::Meta;
use base qw( CLI::Framework::Command );

our $VERSION = 0.01;

sub new {
     my ($class, %args) = @_;
     my $app = $args{app};
     bless { _app => $app }, $class;
}

# (metacommands know about their application (and thus, the other commands in
# the app))
sub get_app { $_[0]->{_app} }
sub set_app { $_[0]->{_app} = $_[1] }

#-------
1;

__END__

=pod

=head1 NAME

CLI::Framework::Command::Meta - Represent "metacommands" (app-aware commands)

=head1 DESCRIPTION

This class is a subclass of CLI::Framework::Command.  It defines
"metacommands", commands that are application-aware (and thus, implicitly
aware of all other commands registered within the application).  Metacommands
have methods that set and retrieve a reference to the application within which
they are running.

This class exists as a separate class because, with few exceptions, commands
should be independent of the application they are associated with and should not
affect that application.  Metacommands represent the exception to that rule.
In the exceptional cases, your command will inherit from this one instead of
C<CLI::Framework::Command>.

=head1 WHEN TO BUILD METACOMMANDS VS REGULAR COMMANDS

See
L<tutorial advice|CLI::Framework::Tutorial/How can I create an application-aware command?>
on this topic.

=head1 METHODS

=head2 get_app() / set_app( $app )

Retrieve or set the application object associated with a metacommand object.

    $app = $command->get_app();

    $command->set_app( $app );

=head1 SEE ALSO

L<CLI::Framework::Command>

L<CLI::Framework::Application>

=cut
