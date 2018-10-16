package CLI::Framework::Command::List;
use base qw( CLI::Framework::Command::Meta );

use strict;
use warnings;

our $VERSION = 0.01;

#-------

sub usage_text { 
    q{
    list: print a concise list of the names of all commands available to the application
    }
}

sub run {
    my ($self, $opts, @args) = @_;

    my $app = $self->get_app(); # metacommand is app-aware

    # If interactive, exclude commands that do not apply in interactive mode...
    my @command_set = $app->get_interactivity_mode()
        ? $app->get_interactive_commands()
        : keys %{ $app->command_map_hashref() };

    my $result = join(', ', map { lc $_ } @command_set ) . "\n";
    return $result;
}

#-------
1;

__END__

=pod

=head1 NAME

CLI::Framework::Command::List - CLIF built-in command to print a list of
commands available to the running application

=head1 SEE ALSO

L<command_map|CLI::Framework::Application/command_map()>

L<CLI::Framework::Command>

=cut
