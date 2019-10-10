use Modern::Perl;

package Teleperl::Storage;

use Config::Tiny;
use Storable qw( store retrieve freeze thaw );
use Data::Dumper;

use constant {
    SESSION_FILE => 'session.dat',
    AUTH_FILE => 'auth.dat',
    CACHE_FILE => 'cache.dat',
    UPDATES_FILE => 'upd.dat',
    TCONF_FILE => 'tconf.dat',
};

sub new
{
    my ($self, %arg) = @_;

    $self = bless( {}, $self ) unless ref $self;

    my $prefix = $arg{dir} // '.';
    $prefix .= '/';

    $self->{_dir} = $arg{dir};
    $self->{_file}{session} = $prefix . SESSION_FILE;
    $self->{_file}{auth} = $prefix . AUTH_FILE;
    $self->{_file}{cache} = $prefix . CACHE_FILE;
    $self->{_file}{tconf} = $prefix . TCONF_FILE;
    $self->{_file}{update_state} = $prefix . UPDATES_FILE;

    for my $state (qw/session auth cache update_state tconf/) {
        if (-e $self->{_file}{$state}) {
            $self->{$state} = retrieve $self->{_file}{$state}
        }
        else {
            $self->{$state} = {}
        }
    }

    $self->{files} = $prefix . ( $arg{files} // 'file_cache/' );
    if ( $self->{files} =~ m@/$@ ) {
        mkdir $self->{files} unless -d $self->{files}
    }
    $self->{config} = Config::Tiny->read("teleperl.conf");

    return $self;
}

sub save
{
    my $self = shift;
    my %flags = @_;

    $flags{session} = 0 unless defined $flags{session};
    $flags{auth} = 1 unless defined $flags{auth};
    $flags{cache} = 1 unless defined $flags{cache};
    $flags{tconf} = 1 unless defined $flags{tconf};
    $flags{update_state} = 0 unless defined $flags{update_state};

    mkdir $self->{_dir} unless -d $self->{_dir};

    for my $state (qw/session auth cache update_state tconf/) {
        store ( $self->{$state}, $self->{_file}{$state} ) 
            if $flags{$state} and defined $self->{$state};
    }
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

sub config
{
    shift->{tconf}
}

1;
