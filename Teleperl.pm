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
use Data::Dumper;

use Telegram::Help::GetConfig;

use Telegram::Auth::SendCode;
use Telegram::Auth::SignIn;
use Telegram::Auth::SignUp;
use Telegram::Auth::ExportAuthorization;
use Telegram::Auth::ImportAuthorization;
use Telegram::Auth::CheckPassword;
use Telegram::InputCheckPasswordSRP;
use Telegram::Auth::ImportBotAuthorization;

use Telegram::Account::GetPassword;
use TeleCrypt::SRP;

use Telegram::Message;
use Telegram::Peer;

use Telegram::InputFileLocation;
use Telegram::Upload::GetFile;
use Telegram::Upload::SaveFilePart;
use Telegram::Upload::SaveBigFilePart;
use Telegram::Messages::SendMedia;
use Telegram::InputFile;
use Telegram::InputPeer;
use Telegram::InputMedia;
use Telegram::InputPhoto;

use Telegram::Messages::SetInlineBotResults;
use Telegram::Messages::UploadMedia;
use Telegram::InputBotInlineResult;
use Telegram::InputBotInlineMessage;

use Digest::MD5 qw(md5);
use IO::File;

sub new
{
    my ($self, %arg) = @_;

    AE::log trace => "Teleperl::new( %s )", Dumper \%arg;

    $self = bless( {}, $self ) unless ref $self;
    $self->init_object_events;

    my $new_session = $arg{force_new_session} // 0;
    AE::log debug => "force_new_session?=".$new_session;
    $self->{_force_new_session} = $new_session;
    $self->{_bot_token} = $arg{bot_token};

    croak("Teleperl::Storage required")
        unless defined $arg{storage} and $arg{storage}->isa('Teleperl::Storage');
    my $storage = $arg{storage};
    $self->{_storage} = $storage;

    $self->{_config} = $storage->config;

    $self->{_upd} = Teleperl::UpdateManager->new( $new_session ? {} : $storage->upd_state );
    $self->{_cache} = Teleperl::PeerCache->new( session => $storage->peer_cache );
    $self->{_storage} = $storage;

    $self->{_tg} = $self->_spawn_tg( $self->{_config}{home_dc} // 0, 1 );
    
    $self->{_upd}->reg_cb( query => sub { shift; $self->invoke(@_) } );
    $self->{_upd}->reg_cb( cache => sub { shift; $self->{_cache}->cache(@_) } );
    $self->{_upd}->reg_cb( update => sub { shift; $self->_handle_update(@_) } );
    $self->{_upd}->reg_cb( message => sub { shift; $self->_handle_message(@_) } );

    unless (defined $self->{_bot_token}) {
        AE::log trace => "bot token not specified, starting update_status timer";
        if ( not defined $arg{online} or $arg{online} ) {
            my $interval = $arg{online_interval} // 60;
            $self->{_online_timer} = AE::timer 0, $interval, sub { $self->update_status };
        }
    }
    $self->{_file_part_size} = 2 ** 19;
    $self->{autofetch} = $arg{autofetch} // 0;

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
                        $self->{_config}{home_dc} = $config->{this_dc}
                            unless defined $self->{_config}{home_dc};
                        # save auth
                        unless ( $self->{_storage}->mt_auth->{$config->{this_dc}} ) {
                            $self->{_storage}->mt_auth->{$config->{this_dc}} = 
                                $self->{_tg}{auth};
                        }
                        $self->{_config}{config} = $config 
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

    my %param = $self->{_storage}->tg_param;

    if ($dc) {
        my @options = grep { $_->{id} == $dc } @{$self->{_config}{config}{dc_options}};

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

    my $dc_auth = $dc ? $self->{_storage}->mt_auth->{$dc} : {};
    unless (defined $dc_auth) {
        $self->{_storage}->mt_auth->{$dc} = $dc_auth = {};
    }
    my $tg = Telegram->new( %param,
        force_new_session => $self->{_force_new_session},
        keepalive => 1,
        auth => $dc_auth,
        session => ($main and $dc) ? $self->{_storage}->mt_session : {},
        bot => defined $self->{_bot_token} ? 1 : undef
    );
    
    if ($main) {
        $tg->reg_cb( new_session => sub { $self->{_upd}->sync } );
        $tg->reg_cb( connected => sub {
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
    if ($self->{_bot_token}) {
        AE::log debug => "Import Bot Auth %s", $self->{_bot_token};
        my $bot_auth = Telegram::Auth::ImportBotAuthorization->new(
            flags => 0,
            api_id => $param{app}{api_id},
            api_hash => $param{app}{api_hash},
            bot_auth_token => $self->{_bot_token},
        );
        # XXX: handle errors
        $tg->invoke( $bot_auth );
    }
    return $tg;
}

sub _migrate
{
    my ($self, $dc, $req) = @_;

    undef $self->{_tg};

    unless ( defined $self->{_config}{config} ) {
        AE::log error => "forced to migrate to $dc, but no config";
        $self->event( error => { error_message => "Nowhere to migrate" } );
        return;
    }
    $self->{_config}{home_dc} = $dc;
    $self->{_tg} = $self->_spawn_tg( $dc, 1 );
    $self->{_tg}->start;
    $self->{_tg}->invoke( $req->{query}, $req->{cb} );
}

sub _handle_update
{
    my ($self, $update) = @_;

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
    elsif ($update->isa('Telegram::UpdateBotInlineQuery')){
        $self->event( 'query', 
                inline => 1, id => $update->{query_id},
                query => $update->{query}, user_id => $update->{user_id}
        );
    }

    # XXX
    $self->event( update => $update );

    AE::log trace => "update: ". Dumper($update);

}

sub _handle_message
{
    my ($self, $mesg) = @_;

    $self->event( update => $mesg );

    if ( $self->{autofetch} and defined $mesg->{media} ) {
        if ( $mesg->{media}->isa('Telegram::MessageMediaDocument') ) {
            my $doc = $mesg->{media}{document};
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
                    $self->event( 'fetch', msg_id => $mesg->{id}, name => $filename, @_ )
                }
            );
        }
        elsif ( $mesg->{media}->isa('Telegram::MessageMediaPhoto') ) {
            my $photo = $mesg->{media}{photo};
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
                        $self->event( 'fetch', msg_id => $mesg->{id}, name => $filename, @_ )
                    }
                );
            }
        }
    }
    AE::log trace => "message: ". Dumper($mesg);
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

sub invoke
{
    my ($self, $query, $cb, %param) = @_;

    my $fix_input = $param{fix_input} // 0;
    if ($fix_input) {
        $self->_recursive_input_access_fix($query) or return;
    }
    $self->{_tg}->invoke($query, $cb);
}

sub auth
{
    my ($self, %arg) = @_;

    if ($arg{phone}) {
        $self->{_phone} = $arg{phone};
        my %param = $self->{_storage}->tg_param;
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
            1
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
                1
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
                1
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
                    1
                );
            },
            1
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

    if ( $file{dc} != $self->{_config}{home_dc} ) {
        $self->{_tg}->invoke( 
            Telegram::Auth::ExportAuthorization->new( dc_id => $file{dc} ),
            sub {
                my $auth = shift;
                if ( $auth->isa('MTProto::RpcError') ) {
                    $file{cb}->( error => $auth->{error_message} );
                }
                else {
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

sub upload_media
{
    my ($self, $type, $file, $cb) = @_;

    $self->_upload_file( filename => $file, cb => sub 
        {
            if ($type eq 'photo') {
                my $q = 
                    Telegram::Messages::UploadMedia->new(
                        peer => Telegram::InputPeerSelf->new,
                        media => Telegram::InputMediaUploadedPhoto->new(
                            file => $_[0]
                        )
                    )
                ;
		# AE::log debug => "UploadMedia %s", Dumper($q);
                $self->invoke( $q,
                    sub {
                        # MessageMedia
                        my $media = @_[0];
                        say ref $media;
                        if ($media->isa('Telegram::MessageMediaABC') and defined $cb) {
                            $cb->($media);
                        }
                    }
                );
            }
        }
    );
}

sub _upload_file
{
    my ($self, %farg) = @_;
    
    my $roam = $self->_spawn_tg( $self->{_config}{home_dc}, 0 );
    $roam->start;
     
    my $file = {
        id => int(rand(2**31)),
        md => Digest::MD5->new,
        size => -s $farg{filename},
        partsize => $self->{_file_part_size} // 2 ** 19,
    };
    $file->{total_parts} = int( ($file->{size} + $file->{partsize} - 1) / $file->{partsize} );


    if ($file->{size}) {
        $file->{handle} = IO::File->new($farg{filename}) or return; # XXX: error callback
        AE::log trace => "upload file %s", Dumper($file);
        $self->_upload_file_part( $roam, $file, 0, sub 
            {
                close $file->{handle};
                my $file = $file->{size} < 10 * 2 ** 20 ? 
                    Telegram::InputFile->new(
                        id => $file->{id},
                        parts => $file->{total_parts},
                        name => $farg{filename},
                        md5_checksum => $file->{md}->digest()
                    ) :
                    Telegram::InputFileBig->new(
                        id => $file->{id},
                        parts => $file->{total_parts},
                        name => $farg{filename},
                    );

                $farg{cb}->($file) if defined $farg{cb};
            }
        );
    }
}

sub _upload_file_part
{
    my ($self, $tg, $file, $part, $cb ) = @_;
    AE::log trace => "upload %s (%d)", Dumper($file), $part;
    my $sizeleft = $file->{size} - $part * $file->{partsize};
    my $size = $sizeleft < $file->{partsize} ? $sizeleft : $file->{partsize};
   
    # upload complete
    if ($sizeleft <= 0) {
        $cb->() if defined $cb;
        return;
    }

    my $data;
    # XXX: error handling
    $file->{handle}->read( $data, $size ) or return;

    $file->{md}->add($data);
    
    my $q = ($file->{size} < 10 * 2 ** 20) ? 
        Telegram::Upload::SaveFilePart->new(
            file_id => $file->{id},
            file_part => $part,
            bytes => $data
        ) 
        : 
        Telegram::Upload::SaveBigFilePart->new(
            file_id => $file->{id},
            file_part => $part,
            file_total_parts => $file->{total_parts},
            bytes => $data
        );

    $tg->invoke( $q,
        sub {
            unless ($_[0]->isa('MTProto::RpcError')) {
                AE::log debug => "part $part/$file->{total_parts} uploaded";
                return $self->_upload_file_part( $tg, $file, $part+1, $cb );
            }
            else {
                AE::log warning => "uploading part $part/$file->{total_parts} failed";
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
    my $users = $self->{session}{users};
    my $chats = $self->{session}{chats};

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

sub send_inline_results
{
    my ($self, %results) = @_;
    my @tg_results;

    for my $result ( $results{results}->@* ) {
        if ($result->[0] eq 'text') {
            my $msg = $result->[1]{message};
            AE::log trace => "pushing inline result text <<%s>>", $msg;

            push @tg_results, Telegram::InputBotInlineResult->new(
                id => $result->[1]{id},
                type => 'article',
                title => substr($msg, 0, 16),
                send_message => Telegram::InputBotInlineMessageText->new(
                    message => $msg
                )
            ) if $msg;
        }
        elsif ($result->[0] eq 'photo') {
            push @tg_results, Telegram::InputBotInlineResultPhoto->new(
                id => $result->[1]{id},
                type => 'photo',
                photo => Telegram::InputPhoto->new(
                    id => $result->[1]{photo_id},
                    access_hash => $result->[1]{access_hash},
                    file_reference => $result->[1]{file_reference}
                ),
                send_message => Telegram::InputBotInlineMessageMediaAuto->new(
                    message => ''
                )
            );
        }
    }

    $self->invoke( Telegram::Messages::SetInlineBotResults->new(
            query_id => $results{query_id},
            cache_time => $results{cache_time} // 0,
            results => [ @tg_results ]
        ) );

}

1;

