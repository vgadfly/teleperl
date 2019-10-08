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

use Telegram::Message;
use Telegram::Peer;


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

    $self->{_config} = $storage->config;

    $self->{_upd} = Teleperl::UpdateManager->new( $new_session ? {} : $storage->upd_state );
    $self->{_cache} = Teleperl::PeerCache->new( session => $storage->peer_cache );
    $self->{_storage} = $storage;

    $self->{_tg} = $self->_spawn_tg( $self->{_config}{home_dc} // 0, 1 );
    
    $self->{_upd}->reg_cb( query => sub { shift; $self->invoke(@_) } );
    $self->{_upd}->reg_cb( cache => sub { shift; $self->{_cache}->cache(@_) } );
    $self->{_upd}->reg_cb( update => sub { shift; $self->_handle_update(@_) } );
    $self->{_upd}->reg_cb( message => sub { shift; $self->_handle_message(@_) } );

    if ( not defined $arg{online} or $arg{online} ) {
        my $interval = $arg{online_interval} // 60;
        $self->{_online_timer} = AE::timer 0, $interval, sub { $self->update_status };
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

    my $tg = Telegram->new( %param,
        force_new_session => $self->{_force_new_session},
        keepalive => 1,
        auth => $dc ? $self->{_storage}->mt_auth->{$dc} : {},
        session => ($main and $dc) ? $self->{_storage}->mt_session : {}
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
    $self->{_tg} = $self->_spawn_tg( $self->{_home_dc}, 1 );
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

    # XXX
    $self->event( update => $update );

    AE::log trace => "update: ". Dumper($update);

}

sub _handle_message
{
    my ($self, $mesg) = @_;

    $self->event( update => $mesg );

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

    unless ($arg{code}) {
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
    else {
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
}

sub update_status
{
    my $self = shift;
    $self->invoke( Telegram::Account::UpdateStatus->new( offline => 0 ) );
}

sub fetch_file
{
    my ($self, $dst, %file) = @_;

    
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
1;

