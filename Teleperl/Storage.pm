use Modern::Perl;

package Teleperl::Storage;

use Config::Tiny;
use Storable qw( store retrieve freeze thaw );

sub new
{
    my ($self, %arg) = @_;

    $self = bless( {}, $self ) unless ref $self;
   
    # XXX: split session into instance data (keys) and 
    # session data (session id) and update state
    $self->{session} = retrieve "session.dat";
    $self->{config} = Config::Tiny->read("teleperl.conf");

    return $self;
}

sub tg_param
{
    return %{shift->{config}};
}

sub tg_state
{
    return (session => shift->{session});
}

sub upd_state
{
    return shift->{session}{update_state};
}

sub peer_cache
{
    return shift->{session};
}

1;
