use Modern::Perl;

package Class::Stateful;

use base 'Class::Event';
use fields qw( _state _states _fatal );

use constant {
    ON_ENTER => 0,
    ON_LEAVE => 1
};

sub new
{
    my $self = shift;
    unless (ref $self) {
        $self = fields::new($self);
    }
    $self->SUPER::new;
    $self->{_states} = { @_ };
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

    my $current = $self->{_state};
    if ( exists $self->{_states}{$current}[ON_LEAVE] ) {
        $self->{_states}{$current}[ON_LEAVE]->();
    }

    if ( exists $self->{_states}{$state} ) {
        $self->{_state} = $state;
        $self->event( state => $state );
        if ( exists $self->{_states}{$state}[ON_ENTER] ) {
            $self->{_states}{$state}[ON_ENTER]->();
        }
    }
    else {
        $self->{_state} = 'fatal';
        $self->{_fatal} = "Unknown state $state"; 
        $self->event( fatal => "Unknown state $state" );
    }
}

sub _set_states
{
    my $self = shift;
    $self->{_states} = { @_ };
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

