package CLI::Framework::Command::Menu;
use base qw( CLI::Framework::Command::Meta );

use strict;
use warnings;

our $VERSION = 0.01;

#-------

sub usage_text { 
    q{
    menu: menu of available commands
    }
}

sub run {
    my ($self, $opts, @args) = @_;

    return $self->menu_txt(@args);
}

sub menu_txt {
    my ($self) = @_;

    my $app = $self->get_app();

    # Build a numbered list of visible commands...
    my @cmd = $app->get_interactive_commands();

    my $txt;
    my %new_aliases = $app->command_alias();
    for my $i (0..$#cmd) {
        my $alias = $i+1;
        $txt .= $alias . ') ' . $cmd[$i] . "\n";
        $new_aliases{$alias} = $cmd[$i];
    }
    # Add numerical aliases corresponding to menu options to the original
    # command aliases defined by the application...
    {
        no strict 'refs'; no warnings;
        *{ (ref $app).'::command_alias' } = sub { %new_aliases };
        return "\n".$txt;
    }
}

sub line_count {
    my ($self) = @_;

    my $menu = $self->menu_txt();
    my $line_count = 0;
    $line_count++ while $menu =~ /\n/g;
    return $line_count;
}

#-------
1;

__END__

=pod

=head1 NAME

CLI::Framework::Command::Menu - CLIF built-in command to show a command menu
including the commands that are available to the running application

=head1 COMMAND SUBCLASS HOOKS

=head2 menu_txt( $cmd_succeeded )

Returns the menu text. The first time it is called without any arguments
(i.e. C<undef>). Then, C<$cmd_succeeded> will be true or false, regarding
success of failure of last interactively entered command-line. This gives
the possibility for subclasses to customize the menu (or even to suppress
it entirely) based on this fact (note that failure can occur not only due
to empty user input or misspelled command name, but also due to runtime
errors of otherwise syntactically valid command request).

=head2 line_count()

Returns the number of lines in output of C<menu_txt()> called without any
arguments - this value used as the default if C<invalid_request_threshold>
parameter is not given explicitly to application's C<run_interactive()>
method.

=head1 SEE ALSO

L<run_interactive|CLI::Framework::Application/run_interactive( [%param] )>

L<CLI::Framework::Command::Console>

L<CLI::Framework::Command>

=cut
