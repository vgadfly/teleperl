package CLI::Framework::Command::Console;
use base qw( CLI::Framework::Command::Meta );

use strict;
use warnings;

our $VERSION = 0.01;

#-------

sub usage_text { 
    q{
    console: invoke interactive command console
    }
}

sub run {
    my ($self, $opts, @args) = @_;

    my $app = $self->get_app(); # metacommand is app-aware

    $app->run_interactive();

    return;
}

#-------
1;

__END__

=pod

=head1 NAME

CLI::Framework::Command::Console - CLIF built-in command supporting
interactive mode

=head1 SEE ALSO

L<run_interactive|CLI::Framework::Application/run_interactive( [%param] )>

L<CLI::Framework::Command::Menu>

L<CLI::Framework::Command>

=cut
