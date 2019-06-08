use Modern::Perl;

package Class::Stateful;

use Object::Event;
#use AnyEvent;

use fields qw( _state _states _fatal );
use base 'Object::Event';

sub new
{
    my $class = shift;
    
    #my $self = fields::new( ref $class || $class );
    my $self = bless ( {}, ref $class || $class );
    $self = $self->SUPER::new;
    $self->{_states} = { map { $_ => undef } @_ };
    $self->{_states}{fatal} = undef;

    return $self;
}

sub _stateful
{
    my $self = shift;
    my $prefix = shift;

    my $method = $prefix . $self->{_state};
    # can get @ISA and check each package for method defined or just eval
    # XXX: all exceptions are caught here
    eval { $self->$method(@_) };
    if ($@) {
        $self->{_state} = 'fatal';
        $self->event( fatal => $@ );
        die;
    }
}

sub _state
{
    my ($self, $state) = @_;
    return $self->{_state} unless defined $state;

    if ( exists $self->{_states}{$state} ) {
        $self->{_state} = $state;
        $self->event( state => $state );
    }
    else {
        $self->{_state} = 'fatal';
        $self->event( fatal => "Unknown state $state" );
    }
}

sub _set_states
{
    my $self = shift;
    $self->{_states} = { map { $_ => undef } @_ };
    $self->{_states}{fatal} = undef;
}

sub _fatal
{
    my ($self, $fatal) = @_;
    
    $self->{_fatal} = $fatal;
    $self->_state('fatal');
    $self->event( fatal => $fatal );
}

1;

