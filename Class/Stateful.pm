use Modern::Perl;

package Class::Stateful;

use fields qw(_state _states);

sub _stateful
{
    my $self = shift;
    my $prefix = shift;

    my $method = $prefix . $self->{_state};
    # can get @ISA and check each package for method defined or just eval
    eval { $self->$method(@_) };
    if ($@) {
        $self->{_state} = '_FATAL_';
        #emit FATAL
    }
}

sub _state
{
    my ($self, $state) = @_;
    if ( exists $self->{_states}{$state} ) {
        $self->{_state} = $state;
        #emit STATE
    }
    else {
        $self->{_state} = '_FATAL_';
        #emit FATAL
    }
}

sub _set_states
{
    my $self = shift;
    local $_;
    $self->{_states} = { map { $_ => undef } @_ };
}

1;

