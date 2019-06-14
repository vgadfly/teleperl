use Modern::Perl;

package Class::Event;

## field-complaint wrapper of Obect::Event

use parent 'Object::Event';
use fields qw(
    __oe_cb_gen __oe_cbs __oe_events __oe_exception_cb
    __oe_exception_rec __oe_forward_stop __oe_forwards
);

sub new
{
    my $self = shift;
    unless (ref $self) {
        $self = fields::new($self);
    }
    $self->init_object_events;
    return $self;
}

1;

