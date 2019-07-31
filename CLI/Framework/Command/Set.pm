use strict;
use warnings;
use 5.012;

package CLI::Framework::Command::Set;

use base 'CLI::Framework::Command::Meta';

sub run
{
    my ($self) = @_;
    my %env = $self->get_app()->get_env;
    local $_;

    say "$_=$env{$_}" for sort keys %env;
}

1;

