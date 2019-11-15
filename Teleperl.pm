package Teleperl;

=head1 SYNOPSYS

  Telegram client

  Provides high-level API for Telegram

=cut

use Modern::Perl;

use Telegram;
use Teleperl::UpdateManager;
use Teleperl::PeerCache;
use Teleperl::Storage;

use base 'Class::Event';

use AnyEvent;
use Data::DPath 'dpath';
use Data::Dumper;

use Telegram::Help::GetConfig;

use Telegram::Auth::SendCode;
use Telegram::Auth::SignIn;
use Telegram::Auth::SignUp;
use Telegram::Auth::ExportAuthorization;
use Telegram::Auth::ImportAuthorization;
use Telegram::Auth::CheckPassword;
use Telegram::InputCheckPasswordSRP;

use Telegram::Account::GetPassword;
use TeleCrypt::SRP;

use Telegram::Message;
use Telegram::Peer;

use Telegram::InputFileLocation;
use Telegram::Upload::GetFile;

use constant ROTTEN_SESSION_TIMEOUT => 864000;  # TODO dynamically by future_salts

sub new
{
    my ($self, %arg) = @_;

    $self = bless( {}, $self ) unless ref $self;
    $self->init_object_events;

    my $new_session = $arg{force_new_session} // 0;
    AE::log debug => "force_new_session?=".$new_session;
    $self->{_force_new_session} = $new_session;

    croak("Teleperl::Storage required")
        unless defined $arg{storage} and $arg{storage}->isa('Teleperl::Storage');
    my $storage = $arg{storage};
    $self->{_storage} = $storage;

    $self->{_config} = $storage->get(session => '/config');
    $self->{home_dc} = $storage->get(session => '/home_dc');

    $self->{_upd} = Teleperl::UpdateManager->new( $new_session ? {} : $storage->get('update_state') );
    $self->{_cache} = Teleperl::PeerCache->new( session => $storage->get('cache') );
    $self->{_storage} = $storage;

    # purge senile sessions
    my $sesspace = $storage->get('session');
    for my $dc (keys %{ $sesspace->{sessions} }) {
        my $sdc = $sesspace->{sessions}->{$dc};
        $sdc = [ grep { ($_->{time}//0) > time() - ROTTEN_SESSION_TIMEOUT } @$sdc ];
    }

    $self->{_tg} = $self->_spawn_tg( $self->{home_dc} // 0, 1 );
    
    $self->{_upd}->reg_cb( query => sub { shift; $self->invoke(@_) } );
    $self->{_upd}->reg_cb( cache => sub { shift; $self->{_cache}->cache(@_) } );
    $self->{_upd}->reg_cb( update => sub { shift; $self->_handle_update(@_) } );
    $self->{_upd}->reg_cb( message => sub { shift; $self->_handle_message(@_) } );

    if ( not defined $arg{online} or $arg{online} ) {
        my $interval = $arg{online_interval} // 60;
        $self->{_online_timer} = AE::timer 0, $interval, sub { $self->update_status };
    }

    $self->{_file_part_size} = 2 ** 19;
    $self->{autofetch} = $arg{autofetch} // 0;
    $self->{noupdate} = $arg{noupdate} // 0;

    # example of filters XXX TODO should think of chaining filters e.g. to capture page id
    if ($self->{autofetch} > 1) {
        $self->register_filter_event('update',
            webpage_photo   => "//.[isa('Telegram::WebPage')]//.[isa('Telegram::Photo')]"
        );
        $self->register_filter_event('update',
            webpage_document=> "//.[isa('Telegram::WebPage')]//.[isa('Telegram::Document')]"
        );
        $self->reg_cb( update_webpage_photo => sub {
            shift;
            $self->_handle_photo( webpage => 1, @_ );
        } );
        $self->reg_cb( update_webpage_document => sub {
            shift;
            $self->_handle_document( webpage => 1, @_ );
        } );
    }

    return $self;
}

sub start
{
    my $self = shift;
    $self->{_tg}->start;
    
    my $guard;
    $guard = $self->{_tg}->reg_cb( connected => sub {
            # get config once
            $self->{_tg}->unreg_cb($guard);
            $self->{_tg}->invoke(Telegram::Help::GetConfig->new, sub {
                    my $config = shift;
                    if ( $config->isa('Telegram::Config') ) {
                        # assume this is home dc
                        unless (defined $self->{home_dc}) {
                            $self->{home_dc} = $config->{this_dc};
                            # save session
                            $self->{_storage}->get("session")->{home_dc} = $self->{home_dc};
                        }
                        # save auth
                        my $authdc = $self->{_storage}->get(auth => "/dc/$config->{this_dc}");
                        unless ( $authdc ) {
                            $authdc = $self->{_tg}{authdc};
                        }
                        $self->{_config} = $config;
                    }
                }
            );
        }
    );
}

sub _spawn_tg
{
    my ($self, $dc, $main) = @_;

    AE::log debug => "spawn new Telegram for DC#$dc%s", $main ? " as main" : "";

    my %param = %{ $self->{_storage}->get('config') };

    if ($dc && !($main && %{$self->{_config}}==0)) { # if ($dc) XXX tmp migrate when home_dc known but Getconfig not yet
        my @options = grep { $_->{id} == $dc } @{$self->{_config}{dc_options}};

        if (defined $param{proxy}) {
            @options = grep { defined $_->{static} } @options;
        }
        unless (@options) {
            AE::log error => "no defined options for DC#$dc";
            $self->event( error => { error_message => "no address for DC#$dc" } );
            return;
        }
        $param{dc}{addr} = $options[0]{ip_address};
        $param{dc}{port} = $options[0]{port};
    }

    my $dc_auth = $dc ? $self->{_storage}->get(auth => "/dc/$dc") : {};
    unless (defined $dc_auth) {
        my $adc = $self->{_storage}->get(auth => "/dc");
        $adc->{$dc} = $dc_auth = {};
    }
    my $main_sid = $self->{_storage}->get(session => '/main_session_id');
    my $dc_sessi = $self->{_storage}->get(session => "/sessions/$dc");
    my $session = (grep { $main ? ($_->{id} eq $main_sid) : 1 } @$dc_sessi)[0];
    $session = {} unless $session;
    # TODO full-fledged session manager instead of one (first) per-dc session

    my $tg = Telegram->new( %param,
        force_new_session => $self->{_force_new_session},
        keepalive => 1,
        authdc => $dc_auth,
        session => $session,
        noupdate => (!$main or $self->{noupdate}),
    );
    
    if ($main) {
        $tg->reg_cb( new_session => sub { $self->{_upd}->sync } );
        $tg->reg_cb( connected => sub {
                my $sesspace =  $self->{_storage}->get('session');
                if (not defined $sesspace->{main_session_id}) {
                    $sesspace->{main_session_id} = $session->{id};
                    push @$dc_sessi, $session
                        unless grep { $_->{id} eq $session->{id} } @$dc_sessi;
                }
                AE::log info => "connected";
                $self->{_upd}->sync
        });
        $tg->reg_cb( error => sub { shift; $self->event( error => @_ ) } );
        $tg->reg_cb( update => sub { shift; $self->{_upd}->handle_updates(@_) } );

        $tg->reg_cb( auth => sub { $self->event('auth') } );
        $tg->reg_cb( banned => sub { $self->event('banned') } );

        # translate Telegram states
        $tg->reg_cb( state => sub { shift; $self->event( 'tg_state', @_ ) } );

        $tg->reg_cb( migrate => sub { shift; $self->_migrate(@_) } );
    }
    else {
        push @$dc_sessi, $session unless defined $session->{id};
    }
    return $tg;
}

sub _migrate
{
    my ($self, $dc, $req) = @_;

    undef $self->{_tg};

    unless ( defined $self->{_config} ) {
        AE::log error => "forced to migrate to $dc, but no config";
        $self->event( error => { error_message => "Nowhere to migrate" } );
        return;
    }
    $self->{home_dc} = $dc;
    $self->{_storage}->get("session")->{home_dc} = $self->{home_dc};
    $self->{_tg} = $self->_spawn_tg( $dc, 1 );
    $self->{_tg}->start;
    $self->{_tg}->invoke( $req->{query}, $req->{cb} );
}

## process filters from specified table and emit events
sub _run_filters
{
    my ($self, $table, $data) = @_;

    for my $rule (@{ $self->{_filters}{$table} }) {
        if (my @res = $rule->{filter}->match($data)) {
            $self->event( $table . '_' . $rule->{name}, @res );
        }
    }
}

## allow user add new filters to table
sub register_filter_event {
    my ($self, $table, $evname, $expression) = @_;

    # XXX TODO support more tables?
    die "unsupported filter table"
        unless grep { $table eq $_ } ('raw', 'update');

    push @{ $self->{_filters}{$table} }, +{
            name    => $evname,
            filter  => dpath($expression),
        };
}

sub _handle_update
{
    my ($self, $update) = @_;

    # fix this shit to always be uniform full Telegram::Message before
    # handling, if it is not yet XXX TODO wtf UpdateShortSentMessage ?! docs:
    # 'chat has to be EXTRACTED FROM THE METHOD CALL THAT RETURNED THIS OBJECT'
    # so not here?.. >_<
    if ( $update->isa('Telegram::UpdateNewMessage') or
         $update->isa('Telegram::UpdateNewChannelMessage')
    ) {
        $self->_handle_message( $update->{message} );
    }
    elsif ($update->isa('Telegram::UpdateShortMessage')) {
        my $m = Telegram::Message->new;
        local $_;
        $m->{$_} = $update->{$_}
            for qw/out mentioned media_unread silent id date message fwd_from via_bot_id reply_to_msg_id entities/;

        if ($update->{out}) {
            $m->{to_id} = Telegram::PeerUser->new( user_id => $update->{user_id} );
            $m->{from_id} = $self->{_cache}->self_id;
        }
        else {
            $m->{to_id} = Telegram::PeerUser->new( user_id => $self->{_cache}->self_id );
            $m->{from_id} = $update->{user_id};
        }
        $self->_handle_message($m);
    }
    elsif ($update->isa('Telegram::UpdateShortChatMessage')) {
        my $m = Telegram::Message->new;
        local $_;
        $m->{$_} = $update->{$_}
            for qw/out mentioned media_unread silent id date message fwd_from via_bot_id reply_to_msg_id entities/;

        $m->{from_id} = $update->{from_id};
        $m->{to_id} = Telegram::PeerChat->new(chat_id => $update->{chat_id});
        
        $self->_handle_message($m);
    }

    # XXX
    $self->event( update => $update );

    AE::log trace => "update: ". Dumper($update);

    $self->_run_filters(update => $update);
}

sub _handle_message
{
    my ($self, $mesg) = @_;

    $self->event( update => $mesg );

    if ( $self->{autofetch} and defined $mesg->{media} ) {
        if ( $mesg->{media}->isa('Telegram::MessageMediaDocument') ) {
            my $doc = $mesg->{media}{document};
            $self->_handle_document($doc, msg_id => $mesg->{id});
        }
        elsif ( $mesg->{media}->isa('Telegram::MessageMediaPhoto') ) {
            my $photo = $mesg->{media}{photo};
            $self->_handle_photo($photo, msg_id => $mesg->{id} );
        }
    }
    AE::log trace => "message: ". Dumper($mesg);
}

sub _handle_document
{
    my ($self, $doc, %param) = @_;

    my $filename = $self->{_storage}{files};
    $filename .= $doc->{dc_id} .'_'. $doc->{id};

    $self->fetch_file(
        dst => $filename,
        type => 'doc',
        dc => $doc->{dc_id},
        id => $doc->{id},
        reference => $doc->{file_reference},
        access_hash => $doc->{access_hash},
        cb => sub {
            $self->event( 'fetch', name => $filename, %param, @_ )
        }
    );
}

sub _handle_photo
{
    my ($self, $photo, %param) = @_;

    for my $sz ( @{$photo->{sizes}} ) {
        my $filename = $self->{_storage}{files};
        $filename .= $self->{_config}{home_dc} .'_'. $photo->{id};
        $filename .= '_'. $sz->{w} .'x'. $sz->{h};

        $self->fetch_file(
            dst => $filename,
            type => 'file',
            dc => $sz->{location}{dc_id},
            volume_id => $sz->{location}{volume_id},
            local_id => $sz->{location}{local_id},
            secret => $sz->{location}{secret},
            reference => $sz->{location}{file_reference},
            access_hash => $photo->{access_hash},
            cb => sub {
                $self->event( 'fetch', name => $filename, %param, @_ )
            }
        );
    }
}

sub _recursive_input_access_fix
{
    my ($self, $obj) = @_;

    AE::log debug => "fixing ".ref($obj);

    local $_;
    for (values %$obj) {
        if ($_->isa('Telegram::InputChannel') or $_->isa('Telegram::InputPeerChannel')) {
            $_->{access_hash} = $self->{_cache}->access_hash($_->{channel_id})
        }
        elsif ($_->isa('Telegram::InputUser') or $_->isa('Telegram::InputPeerUser')) {
            $_->{access_hash} = $self->{_cache}->access_hash($_->{user_id})
        }
        elsif ($_->isa('TL::Object')) {
            $self->_recursive_input_access_fix($_) or return 0;
        }
    }
    return 1;
}

# when fix_input option is set to 1 access_hash from peer cache
# is added recursively to every InputPeer
sub invoke
{
    my ($self, $query, $cb, %param) = @_;

    my $fix_input = delete($param{fix_input}) // 0;
    if ($fix_input) {
        $self->_recursive_input_access_fix($query) or return;
    }
    # XXX delete noqueue (don't allow it for user) here?
    $self->{_tg}->invoke($query, $cb, %param);
}

sub auth
{
    my ($self, %arg) = @_;

    if ($arg{phone}) {
        $self->{_phone} = $arg{phone};
        my %param = %{ $self->{_storage}->get('config') };
        $self->{_tg}->invoke(
            Telegram::Auth::SendCode->new(
                phone_number => $arg{phone},
                api_id => $param{app}{api_id},
                api_hash => $param{app}{api_hash},
            ),
            sub {
                my $res = shift;
                if ($res->isa('Telegram::Auth::SentCode')) {
                    $self->{_code_hash} = $res->{phone_code_hash};
                    $self->{_registered} = $res->{phone_registered};
                    my $type = ref $res->{type};
                    $type =~ s/Telegram::Auth::SentCodeType//;
                    $arg{cb}->( sent => $type, registered => $self->{_registered} ) if defined $arg{cb};
                }
                elsif ($res->isa('MTProto::RpcError')) {
                    $arg{cb}->(error => $res->{error_message}) if defined $arg{cb};
                }
                else {
                    $arg{cb}->(error => 'UNKNOWN') if defined $arg{cb};
                }
            },
            noqueue => 1
        );
    }
    elsif ($arg{code}) {
        if ($self->{_registered}) {
            $self->{_tg}->invoke(
                Telegram::Auth::SignIn->new(
                    phone_number => $self->{_phone},
                    phone_code_hash => $self->{_code_hash},
                    phone_code => $arg{code}
                ), sub {
                    my $res = shift;
                        say Dumper $res;
                    if ($res->isa('MTProto::RpcError')) {
                        $arg{cb}->( error => $res->{error_message} ) if defined $arg{cb};
                    }
                    elsif ($res->isa('Telegram::Auth::Authorization')) {
                        $arg{cb}->( auth => $res->{user}{id} ) if defined $arg{cb};
                        $self->{_tg}->flush;
                    }
                    else {
                        say Dumper $res;
                    }
                },
                noqueue => 1
            );
        }
        else {
            my $name = $arg{first_name};
            unless (defined $arg{first_name}) {
                require FantasyName;
                $name = FantasyName::generate("<s|B|Bv|v><V|s|'|V><s|V|C>");
                $name =~ s/(\w+)/\u\L$1/;
            }

            $self->{_tg}->invoke(
                Telegram::Auth::SignUp->new(
                    phone_number => $self->{_phone},
                    phone_code_hash => $self->{_code_hash},
                    phone_code => $arg{code},
                    first_name => $name,
                    last_name => $arg{last_name} // ""
                ), sub {
                    my $res = shift;
                    if ($res->isa('MTProto::RpcError')) {
                        $arg{cb}->( error => $res->{error_message} ) if defined $arg{cb};
                    }
                    elsif ($res->isa('Telegram::Auth::Authorization')) {
                        $arg{cb}->( auth => $res->{user}{id} ) if defined $arg{cb};
                        $self->{_tg}->flush;
                    }
                    else {
                        say Dumper $res;
                    }
                },
                noqueue => 1
            );
        }
    }
    elsif ($arg{passwd}) {
        $self->{_tg}->invoke( Telegram::Account::GetPassword->new, 
            sub {
                my $pwd = shift;
                if ( $pwd->isa('MTProto::RpcError') ) {
                    $arg{cb}->( error => $pwd->{error_message} ) if defined $arg{cb};
                    return;
                }
                unless ( $pwd->{has_password} ) {
                    $arg{cb}->( error => "No password is set" ) if defined $arg{cb};
                    return;
                }
                my $algo = $pwd->{current_algo};
                my ($g_a, $srp_m1) = TeleCrypt::SRP::side_a( 
                    $algo->{p}, $algo->{g}, $pwd->{srp_B},
                    $algo->{salt1}, $algo->{salt2}, $arg{passwd}
                );
                $self->{_tg}->invoke( Telegram::Auth::CheckPassword->new(
                        password => Telegram::InputCheckPasswordSRP->new(
                            srp_id => $pwd->{srp_id},
                            A => $g_a,
                            M1 => $srp_m1
                        )
                    ), sub {
                        my $res = shift;
                        if ($res->isa('MTProto::RpcError')) {
                            $arg{cb}->( error => $res->{error_message} ) if defined $arg{cb};
                        }
                        elsif ($res->isa('Telegram::Auth::Authorization')) {
                            $arg{cb}->( auth => $res->{user}{id} ) if defined $arg{cb};
                            $self->{_tg}->flush;
                        }
                        else {
                            say Dumper $res;
                        }
                    },
                    noqueue => 1
                );
            },
            noqueue => 1
        );
    }
}

sub update_status
{
    my $self = shift;
    $self->invoke( Telegram::Account::UpdateStatus->new( offline => 0 ) );
}

## fetch file
##
## named arguments:
##  type - location type: file, doc, etc.
##  dc - hosting DC id
##  reference - file_reference field
##
## for doc type:
##  access_hash field of a document
##  id of a document
##
## for file type (photo file, to be deprecated)
##  volume_id, local_id and secret fields
##
sub fetch_file
{
    my ($self, %file) = @_;

    my $roam = $self->_spawn_tg( $file{dc}, 0 );
    $roam->start;
    # TODO use cached exported auth and reuse by session manager instead of $roam
    if ( $file{dc} != $self->{home_dc} ) {
        $self->{_tg}->invoke( 
            Telegram::Auth::ExportAuthorization->new( dc_id => $file{dc} ),
            sub {
                my $auth = shift;
                if ( $auth->isa('MTProto::RpcError') ) {
                    $file{cb}->( error => $auth->{error_message} );
                }
                else {
                    my $adc = $self->{_storage}->get(auth => "/dc");
                    $adc->{$file{dc}}->{exported} = $auth;
                    $roam->invoke(
                        Telegram::Auth::ImportAuthorization->new(
                            id => $auth->{id},
                            bytes => $auth->{bytes}
                        ),
                        sub {
                            $self->_fetch_file( $roam, %file );
                        }
                    );
                }
            }
        );
    } else {
        $self->_fetch_file( $roam, %file );
    }
}

sub _fetch_file
{
    my ($self, $tg, %file) = @_;
    
    my $loc;
    # L91 types (to be deprecated)
    if ( $file{type} eq 'doc' ) 
    {
        $loc = Telegram::InputDocumentFileLocation->new(
            id => $file{id},
            access_hash => $file{access_hash},
            file_reference => $file{reference}
        );
    }
    elsif ( $file{type} eq 'file' ) {
        $loc = Telegram::InputFileLocation->new(
            volume_id => $file{volume_id},
            local_id => $file{local_id},
            secret => $file{secret},
            file_reference => $file{reference}
        );
    } 
    else {
        $file{cb}->( error => "unknown type $file{type}" ) 
            if defined $file{cb};
        return;
    }
    my $file;
    open( $file, '>', $file{dst} );
    binmode $file;
    $self->_fetch_file_part( $file, $tg, $loc, 0, 0, $file{cb} );
}

# XXX: maybe use IO::AIO
sub _fetch_file_part
{
    my ($self, $file, $tg, $loc, $part, $size, $cb) = @_;
    
    $tg->invoke(
        Telegram::Upload::GetFile->new(
            location => $loc,
            offset => $part * $self->{_file_part_size},
            limit => $self->{_file_part_size}
        ),
        sub {
            if ($_[0]->isa('MTProto::RpcError')) {
                return $cb->( error => $_[0]->{error_message} )
                    if defined $cb;
            }
            print $file $_[0]->{bytes};
            my $part_size = length( $_[0]->{bytes} );
            $size += $part_size;
            if ( $part_size == $self->{_file_part_size}) {
                return $self->_fetch_file_part( $tg, $part+1, $size, $cb );
            }
            else {
                close $file;
                return $cb->( size => $size ) if defined $cb;
            }
        }
    ); 
}

# XXX: compatability methods, to be deprecated
sub peer_name
{
    my $self = shift;
    $self->{_cache}->peer_name(@_);
}

sub name_to_id
{
    my $self = shift;
    $self->{_cache}->name_to_id(@_);
}

sub peer_from_id
{
    my $self = shift;
    $self->{_cache}->peer_from_id(@_);
}

sub input_peer
{
    my $self = shift;
    $self->{_cache}->input_peer(@_);
}

sub cached_nicknames
{
    my $self = shift;
    $self->{_cache}->cached_nicknames(@_);
}

sub cached_usernames
{
    my $self = shift;
    $self->{_cache}->cached_usernames(@_);
}

sub send_text_message
{
    my ($self, %arg) = @_;

    my $msg = Telegram::Messages::SendMessage->new(
        map {
            $arg{$_} ? ( $_ => $arg{$_} ) : ()
        } qw(no_webpage silent background clear_draft reply_to_msg_id entities)
    );

    $msg->{message} = $arg{message};    # TODO check utf8
    $msg->{random_id} = int(rand(65536));

    my $peer = $self->{_cache}->peer_from_id($arg{to});

    $msg->{peer} = $peer;

    $self->invoke( $msg ) if defined $peer;
}

sub _cache_users
{
    my ($self, @users) = @_;
    $self->{_cache}->_cache_users(@users);
}

sub _cache_chats
{
    my ($self, @chats) = @_;
    $self->{_cache}->_cache_chats(@chats);
}
1;

