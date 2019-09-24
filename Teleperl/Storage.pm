use Modern::Perl;

package Teleperl::Storage;

use Config::Tiny;
use Storable qw( store retrieve freeze thaw );

use constant {
    SESSION_FILE => 'session.dat',
    AUTH_FILE => 'auth.dat',
    CACHE_FILE => 'cache.dat',
    UPDATES_FILE => 'upd.dat',
};

sub new
{
    my ($self, %arg) = @_;

    $self = bless( {}, $self ) unless ref $self;
   
    $self->{session} = retrieve SESSION_FILE if -e SESSION_FILE;
    $self->{auth} = retrieve AUTH_FILE if -e AUTH_FILE;
    $self->{cache} = retrieve CACHE_FILE if -e CACHE_FILE;
    $self->{update_state} = retrieve UPDATES_FILE if -e UPDATES_FILE;

    $self->{config} = Config::Tiny->read("teleperl.conf");

    return $self;
}

sub save
{
    my $self = shift;
    my %flags = @_;

    my $save_session = $flags{session} // 0;
    my $save_cache = $flags{cache} // 1;
    my $save_auth = $flags{auth} // 1;
    my $save_updates = $flags{updates} // 0;

    store( $self->{session}, SESSION_FILE ) if $save_session;
    store( $self->{cache}, CACHE_FILE ) if $save_cache;
    store( $self->{update_state}, UPDATES_FILE ) if $save_updates;
    store( $self->{auth}, AUTH_FILE ) if $save_auth;
}

sub tg_param
{
    %{shift->{config}}
}

sub mt_session
{
    shift->{session}
}

sub mt_auth
{
    shift->{auth}
}

sub upd_state
{
    shift->{update_state}
}

sub peer_cache
{
    shift->{cache}
}

1;
