use Modern::Perl;

package Teleperl::Storage;

=head1 NAME

Teleperl::Storage - handle temporary and permanent storage for both mutable
and read-only (configuration) state for entire library.

=head1 SYNOPSIS

    my $storobj = Teleperl::Storage->new( dir => $opts->{sessdir}, %params );
    my $tg = Teleperl->new( storage => $storobj, %otheropts );

=head1 DESCRIPTION

This is unified storage object allowing different backends. There are, let us say, three size categories of data in Teleperl (Telegram): small, medium and large.

Small is an absolute minimum required for running, e.g. auth keys, cache of user id <-> name correspondence, update counters and times, etc.

Medium-sized data is what could be re-requested from server if needed but interactive application would want to cache it for responsiveness and performance reasons: message texts, webpage instant previews, etc. This could go into e.g. SQLite database.

Large-sized data is what will be stored value-per-file, that is - files. E.g. stickers, images posted to chats, user profile photos, etc.

Of course distinction is somewhat blurred and is up to application author. Teleperl is a library and could be used for GUI interactive clients, command-line apps, bots, gateways to other IM systems, and so on; in the former case, author may want to put small files like user profile photos directly to DB. in the latter cases, author may choose to avoid file storage completely and do it in-memory only.

Thus, a more granular manner is used. Within C<Teleperl::Storage> for each type of data a B<namespace> is "mounted", each with it's own backend storage instance type and settings (e.g. a file or table name). A I<namespace> is just a non-interpreted string (you may put there slashes or colons for your module name, for example), corresponding to Perl hash reference - a data tree. Later, an entire namespace or it's subtree (down to a single value) could be retrieved by C<get()> call in aplication.

In a minimal implementation, only L<Storable> and L<Config::Tiny> are supported as disk backends. Currently you'll need to subclass C<Teleperl::Storage> to add more storage types.

=head2 get( $namespace, $parameter = "", %options )

    $href = $stor->get( 'main' );
    $dc   = $stor->get( 'config', 'dc' ); say $dc->{addr}
    $int  = $stor->get( 'config', 'proxy/port' );
    $str  = $stor->get( 'mtproto', '/dc/*[2]/session/auth_key' );

Return a storage value or subtree: scalar, arrayref, hashref. In list context, all values matched by expresion are returned, in scalar context, only the first one.

Arguments:

=over 4

=item $namespace

Where to look for data. Some storage backends may interpret it as a relative path to file on disk (with slashes, without extension), for others it's just an arbitrary string.

=item $parameter

If empty, the entire hash of this C<$namespace> is returned. Otherwise, it specifies what part of C<$namespace> to get. For most backend storage types (all of default implementation), this is L<Data::DPath> expresion, see there for description of the language. Some backends, especially using L<tie()|perlfunc/tie VARIABLE,CLASSNAME,LIST>'d hashes (e.g. for SQL tables), may choose to support something more simple.

=item %options

May be empty. Currently only one key defined, C<wantref> for returning references to matched points in data structure (internally, this uses C<dpathr> instead of C<dpath>). This is useful if you are working with last level of tree and e.g. want to change leaf scalars - otherwise, a copies would be returned. Unneeded for intermediate levels where substructure is itself a HASHREF or ARRAYREF, so members will be changeable.

=back

=head2 new( [%opts] )

    $stor = Teleperl::Storage->new( dir => './cli', configfile => 'my.ini' );

    $stor = Teleperl::Storage->new(
        cfcolor     => $cmdline_opts->{colorconfig},
        spacespec   => {
            messages    => [ "memory" ],
            chatwho     => [ "Storable", 'chat_members.dat', 0 ],
            onlinehist  => [ "Storable", 'last$1.dat', 1 ],
            filters     => [ "Config::Tiny", 'filters.ini' ],
            colors      => [ "Config::Tiny", "term.ini", { arg => 'cfcolor' } ]
        } );

    $stor->new(spacespec => { myplugin => [ "memory" ] });

Initialize storage by reading from disk into Perl data structures. If called on already initialized object, then adds new namespace to list of already loaded ones (useful for plugins after the application start). The following arguments are supported:

=over

=item dir

Directory, relative to which will be other files. Defaults to '.' (surrent directory).

=item files

Directory, under C<dir>, where auto-fetched (cached) files will be created.

B<I<XXX> NOTE> this param/implementation is temporary and will be changed in future.

=item spacespec

A hashref, which is spliced into pre-defined namespaces specification, to override them or add new namespaces. The keys are namespace names, the values are array refs, of which the first element is type of storage (name of storage backend class), and others are arguments for this backend, describing file name and other options. In case C<new()> called on already initialized object, namespace name may not be one of previously used.

The currently supported storage types are:

=over

=item memory

Initialized to empty hash ref C<{}>, does nothing - discarded instead of saving. For pure in-memory temporary storage of data shared between different modules.

=item Storable

Uses L<Storable>. The second argument is file name, the third is flag for C<save()> method - whether to store this by default. For file name, additional processing is done: the substring 'C<$1>' is replaced with namespace name itself.

=item Config::Tiny

Read-only storage. The second argument is a configuration file name used by default. If third argument is a hashref, it's C<arg> key is used as a name of that key argument to C<new()> - to be used as a file name instead of default.

=back

=item configfile

=item ...others from spec

As seen from C<spacespec>, backends could be supplied name of argument to C<new()> - by default this allows C<configfile> to be passed for C<config> namespace, without typing boring spec to C<new()>.

=back

=head2 save( [%which] )

Save data from memory to disk. An arguments may be provided, as "C<< $namespace => boolean >>" pairs, specifying what to save. Defaults from C<new()> will be used for not provided namespaces.

=head1 STRUCTURE OF MINIMAL DATA, TERMINOLOGY

These are: peer cache (id / @username / first/last name correspondence), update cache (one integer per chat) and the most pain - session data.

Unfortunately, Telegram is not consistent with terminology. There are two different entities called I<session> - first, what you see in UI of official client listing "current sessions", where each session corresponds to entire device / OS. Second, is an I<MTProto session> which has sequence number of message in it and can persist between TCP conections. There could be multiple MTProto sessions running at the same time, e.g. to speed up file downloads.

Between those two I<sessions>, sits an I<authorization>. It could be said that I<UI session> is the same as I<authorization> in degenerate case, but alas, things are more comlicated. See:

=over

=item *
User on a new device first generates I<auth_key> and bounds it to account via e.g. SMS, thus an I<authorization> has been created.

=item *
This had happened inside first I<MTProto session>, which has C<session_id> in it.

=item *
At this step, combination of I<authorization> and C<session_id> could be called I<instance> - which it is in some clients and was in Teleperl at some time.

=item *
Then, client could open B<multiple> I<MTProto sessions> under the same I<auth_key> - to the same DC.

=item *
Then at one step, client needs to request file from I<another DC> - and new I<auth_key> will be generated for this DC!

=item *
To help in the fact this is not new user but same I<authorization> (I<UI session>), client uses API calls C<auth.exportAuthorization> in I<home DC> and C<auth.importAuthorization> this in new DC.

=item *
There could be multiple I<MTProto sessions> (each with own C<session_id>) to new DC under B<it's> I<auth_key>.

=item *
Moreover, client may choose to do Perfect Forward Secrecy. The every I<auth_key> above was B<permanent> key - per DC - and client may call C<auth.bindTempAuthKey> for using I<temporary> I<auth_key> - again, only one I<temp_auth_key> per DC, same for all I<MTProto sessions> to that DC.

=back

Note that I<salt> (and future salts) are also only one per I<auth_key> and shared between multiple I<MTProto sessions> to same DC.

The DC where user accont data stored and from where event updates go, is called I<home DC>, and other DCs, which are used only for file requests, are called in Teleperl I<roaming DC>. But due to the fact Telegram server occasionally may move user data to another home DC specifying C<USER_MIGRATE_X> error, at the storage level all DCs and sessions are equal, and one variable distinguishes home DC (and main (updates) session id) outside.

Thus, structure main two files are:

=head2 auth.dat

Contains sensitive crypto information (keys, salts), should be under C<chmod 600>. It's keys are:

=over

=item dc

Hash with per-DC info. It should be an array, but due to MTProxy shifted numbers are possible. So keys are DC number, values are hashes:

=over

=item permkey

Main key hash, contains C<auth_key>, C<auth_key_id>, C<auth_key_aux> fields.

=item tempkey

Same structure as I<permkey>, used if Perfect Forward Secrecy is enabled

=item salt

(current) C<salt> (I<XXX it seems salt is shared between tempkey and permkey, need to check>)

=item future_salts

An L<MTProto::FutureSalts> object with time interval for new salts, it contains it's own request time inside as C<now> member. Last time this DC was exchanged messages (may be used for changing salts) may be found in C<session.dat>.

=item exported

Cached L<Telegram::Auth::ExportedAuthorization> for this DC, if not home and was ever requested.

=back

=item other top-level keys may be added later for e.g. secret chats, passports, etc.

=back

=head2 session.dat

Carries data pertaining to overall I<UI session> and I<MTProto sessions>. Top-level keys of hash are:

=over

=item self_id

User id of account owner, just for convenience.

=item home_dc

Number of home DC.

=item main_session_id

May contain C<session_id> of main (with updates) connection (on home DC).

=item sessions

Hash where key is DC numer, value is array of per-DC I<MTProto sessions>. Array elements are per-session hashes which keys are:

=over

=item I<id>
8 random bytes, MTProto session_id

=item I<seq>
MTProto message sequence number in session

=item I<time>
when last bytes were received from socket, for purging stale sessions and salts

=back

=item config

L<Telegram::Config> object. As it may change frequently, contains it's own time in C<date> field.

=item cdnconfig

L<Telegram::CdnConfig> object.

=item cdnconfig_time

Unix time_t of when C<cdnconfig> was received (updated).

=back

=cut

use Config::Tiny;
use Storable qw( nstore retrieve freeze thaw dclone );
use File::Spec;
use Data::DPath qw(dpath dpathr);
$Data::DPath::USE_SAFE = 0; # or it will not see our classes O_o

use Data::Dumper;

my $DEF_AUTH = {
    dc => {
        '1' => { permkey => {}, tempkey => {}, salt => '', future_salts => {}, },
        '2' => { permkey => {}, tempkey => {}, salt => '', future_salts => {}, },
        '3' => { permkey => {}, tempkey => {}, salt => '', future_salts => {}, },
        '4' => { permkey => {}, tempkey => {}, salt => '', future_salts => {}, },
        '5' => { permkey => {}, tempkey => {}, salt => '', future_salts => {}, },
    },
};

my $DEF_SESS = {
        self_id         => undef,
        home_dc         => undef,
        main_session_id => '',
        sessions        => {
            '1' => [],
            '2' => [],
            '3' => [],
            '4' => [],
            '5' => [],
        },
        config          => {},
        cdnconfig       => {},
        cdnconfig_time  => 0,
};

our %DEFAULT_SPEC = (
    session     => [ 'Storable', 'session.dat', 1,    0, $DEF_SESS ],
    auth        => [ 'Storable', 'auth.dat',    0, 0600, $DEF_AUTH ],
    cache       => [ 'Storable', '$1.dat',      1       ],
    update_state=> [ 'Storable', 'upd.dat',     1       ],
    config      => [ 'Config::Tiny', "teleperl.conf", { arg => 'configfile' }],
    files       => [ "memory" ],
);

sub new
{
    my ($self, %arg) = @_;

    $self = bless( {}, $self ) unless ref $self;

    my $arg_spacespec = delete $arg{spacespec};
    my $prefix = delete($arg{dir}) // '.';
    $self->{_dir} = $prefix unless $self->{_dir};

    # support adding new namespaces after creation
    my %spec = (
        exists $self->{_spec} ? () : %DEFAULT_SPEC,
        defined $arg_spacespec ? %$arg_spacespec : (),
    );
    # but changing already loaded spaces is currently not supported
    if (defined $self->{_spec}) {
        delete $spec{$_}, warn("storage $_ already exists!")
            for keys %{ $self->{_spec} };
        $self->{_spec} = {
            %{ $self->{_spec} },
            %spec,
        } if %spec;
    }
    else {
        $self->{_spec} = { %spec };
    }

    for my $state (keys %spec) {
        $self->{$state} = {};
        my @instance = @{ $spec{$state} };
        my $backend = shift @instance;
        my $handler = {
            'Storable'      => sub {
                my @inst = @{ shift(@_) };
                my %args = @_;
                my $file = $inst[0];
                if ($file =~ /\$1/) {
                    $file =~ s/\$1/$state/;
                }
                $file = File::Spec->catfile($prefix, $file);

                if (-e $file) {
                    $self->{$state} = retrieve $file;
                }
                elsif (my $defaults = $inst[3]) {
                    $self->{$state} = dclone $inst[3];
                }
              },
            'Config::Tiny'  => sub {
                my @inst = @{ shift(@_) };
                my %args = @_;
                my $file = $inst[0];
                if (defined $inst[1] and ref $inst[1] eq 'HASH') {
                    my $arg = $inst[1]->{arg};
                    $file = $args{$arg} if defined $arg;
                }
                $self->{$state} = Config::Tiny->read($file) // {};
              },
            memory => sub { 1 },
        }->{$backend};
        if ($handler) {
            $handler->([ @instance ], %arg);
        }
        else {
            die "Unsupported backend storage '$backend'";
        }
    }

    # XXX to be deprecated
    my $files = $arg{files} // 'file_cache/';
    $self->{files} = File::Spec->catfile( $prefix, $files );
    if ( $files =~ m@/$@ ) {
        $self->{files} .= "/";
        mkdir $prefix unless -d $prefix;
        mkdir $self->{files} unless -d $self->{files}
    }

    return $self;
}

sub save
{
    my $self = shift;
    my %flags = @_;

    mkdir $self->{_dir} unless -d $self->{_dir};
    my $prefix = $self->{_dir};

    for my $state (keys %{ $self->{_spec} }) {
        my @instance = @{ $self->{_spec}{$state} };
        my $backend = shift @instance;

        next unless $backend eq 'Storable';

        my $file = $instance[0];

        if ($file =~ /\$1/) {
            $file =~ s/\$1/$state/;
        }
        $file = File::Spec->catfile($prefix, $file);
        say "saving $state to $file";
        say Dumper $self->{$state};
        $flags{$state} = $instance[1] unless defined $flags{$state};

        nstore ( $self->{$state}, $file ) 
            if $flags{$state} and defined $self->{$state};

        if (my $perm = $instance[2]) {
            chmod $perm, $file;
        }
    }
}

sub get
{
    my ($self, $namespace, $parameter, %options) = @_;

    return $self->{$namespace} unless $parameter;

    my $filter = $options{wantref}
        ? dpathr($parameter)
        : dpath ($parameter);

    return wantarray
        ? $filter->match( $self->{$namespace})
        : $filter->matchr($self->{$namespace})->[0];
}

1;
