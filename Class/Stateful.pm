use Modern::Perl;

package Class::Stateful;

use Object::Event;

use fields qw(_state _states);
use base 'Object::Event';

sub new
{
    my $class = shift;
    
    #my $self = fields::new( ref $class || $class );
    my $self = bless ( {}, ref $class || $class );
    $self = $self->SUPER::new;

    return $self;
}

sub _stateful
{
    my $self = shift;
    my $prefix = shift;

    my $method = $prefix . $self->{_state};
    # can get @ISA and check each package for method defined or just eval
    eval { $self->$method(@_) };
    if ($@) {
        $self->{_state} = '_FATAL_';
        $self->event(fatal => $@)
    }
}

sub _state
{
    my ($self, $state) = @_;
    if ( exists $self->{_states}{$state} ) {
        $self->{_state} = $state;
        $self->event(state => $state);
    }
    else {
        $self->{_state} = '_FATAL_';
        $self->event(fatal => "Unknown state $state");
    }
}

sub _set_states
{
    my $self = shift;
    local $_;
    $self->{_states} = { map { $_ => undef } @_ };
}

1;

