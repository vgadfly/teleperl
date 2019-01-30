package Telegram;

=head1 SYNOPSYS

  Telegram API client

=cut

use Modern::Perl;
use Data::Dumper;
use Carp;

use IO::Socket;
use Net::SOCKS;

use AnyEvent;

# This module should use MTProto for communication with telegram DCs

use MTProto;
use MTProto::Ping;

## Telegram API

# Layer and Connection
use Telegram::InvokeWithLayer;
use Telegram::InitConnection;

# Auth
use Telegram::Auth::SendCode;
use Telegram::Auth::SentCode;
use Telegram::Auth::SignIn;

# Updates
use Telegram::Updates::GetState;
use Telegram::Updates::GetDifference;
use Telegram::Updates::GetChannelDifference;

use Telegram::ChannelMessagesFilter;
use Telegram::Account::UpdateStatus;

# Messages
use Telegram::Message;
use Telegram::Messages::GetMessages;
use Telegram::Messages::SendMessage;

# input
use Telegram::InputPeer;

use fields qw( _mt _dc _code_cb _app _proxy _timer _first _code_hash _rpc_cbs 
    reconnect session on_update on_error debug keepalive noupdate error );

# args: DC, proxy and stuff
sub new
{
    my @args = qw( on_update on_error noupdate debug keepalive reconnect );
    my ($class, %arg) = @_;
    my $self = fields::new( ref $class || $class );
    
    $self->{_dc} = $arg{dc};
    $self->{_proxy} = $arg{proxy};
    $self->{_app} = $arg{app};
    $self->{_code_cb} = $arg{on_auth};

    @$self{@args} = @arg{@args};

    # XXX: handle old session files
    my $session = $arg{session};
    $session->{mtproto} = {} unless exists $session->{mtproto};
    $self->{session} = $session;
    $self->{_first} = 1;

    return $self;
}

# connect, start session
sub start
{
    my $self = shift;

    my $sock;
    if (defined $self->{_proxy}) {
        my $proxy = new Net::SOCKS( 
            socks_addr => $self->{_proxy}{addr},
            socks_port => $self->{_proxy}{port}, 
            user_id => $self->{_proxy}{user},
            user_password => $self->{_proxy}{pass}, 
            protocol_version => 5,
        );

        # XXX: don't die
        $sock = $proxy->connect( 
            peer_addr => $self->{_dc}{addr}, 
            peer_port => $self->{_dc}{port} 
        ) or die;
    }
    else {
        $sock = IO::Socket::INET->new(
            PeerAddr => $self->{_dc}{addr}, 
            PeerPort => $self->{_dc}{port},
            Proto => 'tcp'
        ) or die;
    }
    
    $self->{_mt} = MTProto->new( socket => $sock, session => $self->{session}{mtproto},
            on_error => $self->_get_err_cb, on_message => $self->_get_msg_cb,
            debug => $self->{debug}
    );

    $self->run_updates unless $self->{noupdate};
}

sub run_updates {
    my $self = shift;

    $self->{_timer} = AnyEvent->timer( after => 45, interval => 45, cb => $self->_get_timer_cb );
    
    unless (exists $self->{session}{update_state}) {
        $self->invoke( Telegram::Updates::GetState->new, sub {
            my $us = shift;
            if ($us->isa('Telegram::Updates::State')) {
                $self->{session}{update_state}{seq} = $us->{seq};
                $self->{session}{update_state}{pts} = $us->{pts};
                $self->{session}{update_state}{date} = $us->{date};
            }
        } );
    }
    else {
        $self->invoke( Telegram::Updates::GetDifference->new( 
                    date => $self->{session}{update_state}{date},
                    pts => $self->{session}{update_state}{pts},
                    qts => -1,
            ), 
            sub {
                $self->_handle_upd_diff(@_);
            }
        );
    }
}
## layer wrapper

sub invoke
{
    my ($self, $query, $res_cb) = @_;
    my $req_id;

    say Dumper $query if $self->{debug};
    if ($self->{_first}) {
        
        # Wrapper conn
        my $conn = Telegram::InitConnection->new( 
                api_id => $self->{_app}{api_id},
                device_model => $self->{_app}{device} // 'IBM PC/AT',
                system_version => $self->{_app}{sys_ver} // 'DOS 6.22',
                app_version => $self->{_app}{version} // '0.01',
                system_lang_code => 'en',
                lang_pack => '',
                lang_code => 'en',
                query => $query
        );

        $req_id = $self->{_mt}->invoke( Telegram::InvokeWithLayer->new( layer => 76, query => $conn ) );

        $self->{_first} = 0;
    }
    else {
        $req_id = $self->{_mt}->invoke( $query );
    }

    # store handler for this query result
    $self->{_rpc_cbs}{$req_id} = $res_cb if defined $res_cb;
    return $req_id;
}

sub auth
{
    my ($self, %arg) = @_;

    unless ($arg{code}) {
        $self->{session}{phone} = $arg{phone};
        $self->invoke(
            Telegram::Auth::SendCode->new( 
                phone_number => $arg{phone},
                api_id => $self->{_app}{api_id},
                api_hash => $self->{_app}{api_hash},
                flags => 0
        ));
    }
    else {
        $self->invoke(
            Telegram::Auth::SignIn->new(
                phone_number => $self->{session}{phone},
                phone_code_hash => $self->{_code_hash},
                phone_code => $arg{code}
        ));
    }
}

sub update
{
    my $self = shift;

    $self->invoke( Telegram::Account::UpdateStatus->new( offline => 0 ) );
    $self->invoke( Telegram::Updates::GetState->new, sub {
            my $us = shift;
            if ($us->isa('Telegram::Updates::State')) {
                $self->{session}{update_state}{seq} = $us->{seq};
                $self->{session}{update_state}{pts} = $us->{pts};
                $self->{session}{update_state}{date} = $us->{date};
            }
        } );
}

sub _check_pts
{
    my ($self, $pts, $count, $channel) = @_;

    my $local_pts = defined $channel ? 
        $self->{session}{update_state}{channel_pts}{$channel} :
        $self->{session}{update_state}{pts};

    if (defined $local_pts and $local_pts + $count < $pts) {
        say "local_pts=$local_pts, pts=$pts, count=$count, channel=$channel" if $self->{debug};
        my $channel_peer = $self->peer_from_id( $channel );
        if (defined $channel_peer) {
            $self->invoke( Telegram::Updates::GetChannelDifference->new(
                channel => $channel_peer,
                filter => Telegram::ChannelMessagesFilterEmpty->new,
                pts => $local_pts,
                limit => 0
            ),
            sub { $self->_handle_channel_diff( $channel, @_ ) }
            );
        }
        else {
            $self->invoke( Telegram::Updates::GetDifference->new( 
                date => $self->{session}{update_state}{date},
                pts => $local_pts,
                qts => -1,
            ), 
            sub {$self->_handle_upd_diff(@_) }
        );
        }
        return 0;
    }
    else {
        if (defined $channel) {
            $self->{session}{update_state}{channel_pts}{$channel} = $pts;
        }
        else {
            $self->{session}{update_state}{pts} = $pts;
        }
        return 1;
    }
}

sub _debug_print_update
{
    my ($self, $upd) = @_;

    say ref $upd;
    
    if ($upd->isa('Telegram::Update::UpdateNewChannelMessage')) {
        my $ch_id = $upd->{message}{to_id}{channel_id};
        say "pts=$upd->{pts}(+$upd->{pts_count}) last=$self->{session}{update_state}{channel_pts}{$ch_id}"
            if (exists $upd->{pts});
    }
    elsif ($upd->isa('Telegram::Update::UpdateNewMessage')) {
        say "pts=$upd->{pts}(+$upd->{pts_count}) last=$self->{session}{update_state}{pts}"
            if (exists $upd->{pts});
    }
    say "seq=$upd->{seq}" if (exists $upd->{seq} and $upd->{seq} > 0);

    #if ($upd->isa('Telegram::Updates')) {
    #    for my $u (@{$upd->{updates}}) {
    #        $self->_debug_print_update($u);
    #    }
    #}
}

sub _handle_update
{
    my ($self, $upd) = @_;

    #say ref $upd;

    #$self->_debug_print_update($upd);
    
    if ($upd->isa('Telegram::UpdateChannelTooLong')) {
        my $channel = $self->peer_from_id( $upd->{channel_id} );
        $self->invoke(
            Telegram::Updates::GetChannelDifference->new(
                channel => $channel,
                filter => Telegram::ChannelMessagesFilterEmpty->new,
                pts => $self->{session}{update_state}{channel_pts}{$upd->{channel_id}},
                limit => 0
            ),
            sub { $self->_handle_channel_diff( $upd->{channel_id}, @_ ) }
        ) if defined $channel;
        return;
    }
    
    my $pts_good;
    if (
        $upd->isa('Telegram::UpdateNewChannelMessage') or
        $upd->isa('Telegram::UpdateEditChannelMessage')
    ) {
        $pts_good = $self->_check_pts( 
            $upd->{pts}, $upd->{pts_count}, 
            $upd->{message}{to_id}{channel_id}
        );
    }
    if (
        $upd->isa('Telegram::UpdateDeleteChannelMessages') or 
        $upd->isa('Telegram::UpdateChannelWebPage') 
    ) {
        $pts_good = $self->_check_pts( $upd->{pts}, $upd->{pts_count}, $upd->{channel_id} );
    }
    if ( 
        $upd->isa('Telegram::UpdateNewMessage') or
        $upd->isa('Telegram::UpdateEditMessage') or
        $upd->isa('Telegram::UpdateDeleteMessages') or 
        $upd->isa('Telegram::UpdateWebPage') 
    ) {
        $pts_good = $self->_check_pts( $upd->{pts}, $upd->{pts_count} );
    }

    if ($pts_good) {    
        if ( 
            $upd->isa('Telegram::UpdateNewChannelMessage') or
            $upd->isa('Telegram::UpdateNewMessage')
        ) {
            &{$self->{on_update}}($upd->{message}) if $self->{on_update};
        }
    }
        # TODO: separate messages from other updates
    #if ( $upd->isa('Telegram::UpdateChatUserTyping') ) {
    #    &{$self->{on_update}}($upd) if $self->{on_update};
    #}
}

sub _handle_short_update
{
    my ($self, $upd) = @_;

    my $in_msg = $self->message_from_update( $upd );
    &{$self->{on_update}}( $in_msg ) if $self->{on_update};
}

sub _handle_upd_seq_date
{
    my ($self, $seq, $date) = @_;
    if ($seq > 0) {
        if ($seq > $self->{session}{update_state}{seq} + 1) {
            # update hole
            warn "\rupdate seq hole\n";
        }
        $self->{session}{update_state}{seq} = $seq;
    }
    $self->{session}{update_state}{date} = $date;
}

sub _handle_upd_diff
{
    my ($self, $diff) = @_;

    #say ref $diff;

    unless ( $diff->isa('Telegram::Updates::DifferenceABC') ) {
        warn "not diff: " . ref $diff;
        return;
    }
    return if $diff->isa('Telegram::Updates::DifferenceEmpty');

    #my @t = localtime;
    #print "---\n", join(":", map {"0"x(2-length).$_} reverse @t[0..2]), " : ";
    #say ref $diff;
  
    my $upd_state;
    if ($diff->isa('Telegram::Updates::Difference')) {
        $upd_state = $diff->{state};
    }
    if ($diff->isa('Telegram::Updates::DifferenceSlice')) {
        $upd_state = $diff->{intermediate_state};
        $self->invoke( Telegram::Updates::GetDifference->new( 
                    date => $upd_state->{date},
                    pts => $upd_state->{pts},
                    qts => -1,
            ),
            sub { $self->_handle_upd_diff(@_) }
        );
    }
    unless (defined $upd_state) {
        warn "bad update state";
        say Dumper $diff;
        return;
    }
    #say "new pts=$upd_state->{pts}, last=$self->{session}{update_state}{pts}";
    $self->{session}{update_state}{seq} = $upd_state->{seq};
    $self->{session}{update_state}{date} = $upd_state->{date};
    $self->{session}{update_state}{pts} = $upd_state->{pts};
    
    $self->_cache_users(@{$diff->{users}});
    $self->_cache_chats(@{$diff->{chats}});
    
    for my $upd (@{$diff->{other_updates}}) {
        $self->_handle_update( $upd );
    }
    for my $msg (@{$diff->{new_messages}}) {
        #say ref $msg;
        &{$self->{on_update}}($msg) if $self->{on_update};
    }
}

sub _handle_channel_diff
{
    my ($self, $channel, $diff) = @_;

    #say ref $diff;
    
    unless ( $diff->isa('Telegram::Updates::ChannelDifferenceABC') ) {
        warn "not diff: " . ref $diff;
        return;
    }
    return if $diff->isa('Telegram::Updates::ChannelDifferenceEmpty');

    #my @t = localtime;
    #print "---\n", join(":", map {"0"x(2-length).$_} reverse @t[0..2]), " : ";
    #say ref $diff;
  
    if ($diff->isa('Telegram::Updates::ChannelDifferenceTooLong')) {
        warn "don't now how to handle ChannelDifferenceTooLong";
        return;
    }
    say "channel=$channel, new pts=$diff->{pts}" if $self->{debug};
    $self->{session}{update_state}{channel_pts}{$channel} = $diff->{pts};  

    $self->_cache_users(@{$diff->{users}});
    $self->_cache_chats(@{$diff->{chats}});
    
    for my $upd (@{$diff->{other_updates}}) {
        $self->_handle_update( $upd );
    }
    for my $msg (@{$diff->{new_messages}}) {
        #say ref $msg;
        &{$self->{on_update}}($msg) if $self->{on_update};
    }
}


##  On updates
##
##  To subscribe to updates client perform any "high level API query".
##
##  Telegram server (and client) mantains updates state.
##  Client may call to Updates.GetState to obtain server updates state.
##
##  Each update MAY contain sequence number, but there is no way to get missing updates by seq.
##
##  Updates state contains:
##      - pts   -   some number concerning messages, excluding channels, 
##                  "number of actions in message box", the magic number of updates
##      - qts   -   same, but in secret chats
##      - date  -   not sure, if used anywhere
##      - seq   -   number on sent updates (not content-related)
##
##  Channels (and supergroups) mantain own pts, used in GetChannelDifference call.
##
##  GetDifference and GetChannelDifference are used to request missing updates.
##
sub _handle_updates
{
    my ($self, $updates) = @_;
    #my @t = localtime;
    #print "---\n", join(":", map {"0"x(2-length).$_} reverse @t[0..2]), " : ";
    #$self->_debug_print_update($updates);

    # short spec updates
    # ShortSentMessage?
    if ( $updates->isa('Telegram::UpdateShortMessage') or
        $updates->isa('Telegram::UpdateShortChatMessage') )
    {
        $self->_handle_upd_seq_date( 0, $updates->{date} );
        if ( $self->_check_pts( $updates->{pts}, $updates->{pts_count} ) ) {
            $self->_handle_short_update( $updates );
        }
    }

    # XXX: UpdatesCombined
    # regular updates
    if ( $updates->isa('Telegram::Updates') ) {
        $self->_cache_users( @{$updates->{users}} );
        $self->_cache_chats( @{$updates->{chats}} );
        $self->_handle_upd_seq_date( $updates->{seq}, $updates->{date} );
        
        for my $upd ( @{$updates->{updates}} ) {
            $self->_handle_update($upd);
        }
    }

    # short generic updates
    if ( $updates->isa('Telegram::UpdateShort') ) {
        $self->_handle_upd_seq_date( 0, $updates->{date} );
        $self->_handle_update( $updates->{update} );
    }
    
    if ( $updates->isa('Telegram::UpdatesTooLong') ) {
        $self->invoke( Telegram::Updates::GetDifference->new( 
                date => $self->{session}{update_state}{date},
                pts => $self->{session}{update_state}{pts},
                qts => -1,
            ), 
            sub { $self->_handle_upd_diff(@_) } 
        );
    }
}

sub _handle_rpc_result
{
    my ($self, $res) = @_;

    my $req_id = $res->{req_msg_id};
    say "Got result for $req_id" if $self->{debug};
    if (defined $self->{_rpc_cbs}{$req_id}) {
        &{$self->{_rpc_cbs}{$req_id}}( $res->{result} );
        delete $self->{_rpc_cbs}{$req_id};
    }
    if ($res->{result}->isa('MTProto::RpcError')) {
        $self->_handle_rpc_error($res->{result});
    }
}

sub _handle_rpc_error
{
    my ($self, $err) = @_;

    &{$self->{on_error}} if defined $self->{on_error};
    $self->{error} = $err;

    if ($err->{error_message} eq 'USER_DEACTIVATED') {
        $self->{_timer} = undef;
    }
    if ($err->{error_message} eq 'AUTH_KEY_UNREGISTERED') {
        $self->{_timer} = undef;
    }
}

sub _get_err_cb
{
    my $self = shift;
    return sub {
            my %err = @_;
            # TODO: log
            warn "Error: $err{message}" if ($err{message});
            warn "Error: $err{code}" if ($err{code});

            if ($self->{reconnect}) {
                print "reconnecting" if $self->{debug};
                undef $self->{_mt};
                $self->start;
                $self->update;
            }
            else {
                my $e = {
                    error_message => $err{message},
                    error_code => $err{code}
                };
                $self->_handle_rpc_error(bless($e, 'MTProto::NetError'));
            }
    }
}

sub _get_msg_cb
{
    my $self = shift;
    return sub {
        my $msg = shift;
        say Dumper $msg->{object} if $self->{debug};

        # RpcResults
        $self->_handle_rpc_result( $msg->{object} )
            if ( $msg->{object}->isa('MTProto::RpcResult') );

        # RpcErrors
        $self->_handle_rpc_error( $msg->{object} )
            if ( $msg->{object}->isa('MTProto::RpcError') );

        # Updates
        $self->_handle_updates( $msg->{object} )
            if ( $msg->{object}->isa('Telegram::UpdatesABC') );
    }
}

sub message_from_update
{
    my ($self, $upd) = @_;
    
    local $_;
    my %arg;

    for ( qw( out mentioned media_unread silent id fwd_from via_bot_id 
        reply_to_msg_id date message entities ) ) 
    {
        $arg{$_} = $upd->{$_} if exists $upd->{$_};
    }
    # some updates have user_id, some from_id
    $arg{from_id} = $upd->{user_id} if (exists $upd->{user_id});
    $arg{from_id} = $upd->{from_id} if (exists $upd->{from_id});

    # chat_id
    $arg{to_id} = $upd->{chat_id} if (exists $upd->{chat_id});

    return Telegram::Message->new( %arg );
}

sub get_messages
{
    local $_;
    my $self = shift;
    my @input;
    for (@_) {
        push @input, Telegram::InputMessageID->new( id => $_ );
    }
    $self->invoke( Telegram::Messages::GetMessages->new( id => [@input] ) );
}

sub send_text_message
{
    my ($self, %arg) = @_;
    my $msg = Telegram::Messages::SendMessage->new;
    my $users = $self->{session}{users};
    my $chats = $self->{session}{chats};

    $msg->{message} = $arg{message};
    $msg->{random_id} = int(rand(65536));

    my $peer;
    if (exists $users->{$arg{to}}) {
        $peer = Telegram::InputPeerUser->new( 
            user_id => $arg{to}, 
            access_hash => $users->{$arg{to}}{access_hash}
        );
    }
    if (exists $chats->{$arg{to}}) {
        $peer = Telegram::InputPeerChannel->new( 
            channel_id => $arg{to}, 
            access_hash => $chats->{$arg{to}}{access_hash}
        );
    }

    if ($arg{to}->isa('Telegram::PeerChannel')) {
        $peer = Telegram::InputPeerChannel->new( 
            channel_id => $arg{to}->{channel_id}, 
            access_hash => $chats->{$arg{to}->{channel_id}}{access_hash}
        );
    }
    unless (defined $peer) {
        $peer = Telegram::InputPeerChat->new( chat_id => $arg{to} );
    }

    $msg->{peer} = $peer;

    say Dumper $msg if defined $self->{debug};
    $self->invoke( $msg ) if defined $peer;
}

sub _cache_users
{
    my ($self, @users) = @_;
    
    for my $user (@users) {
        $self->{session}{users}{$user->{id}} = { 
            access_hash => $user->{access_hash},
            username => $user->{username},
            first_name => $user->{first_name},
            last_name => $user->{last_name}
        };
    }
}

sub _cache_chats
{
    my ($self, @chats) = @_;
    
    for my $chat (@chats) {
        next if $chat->isa('Telegram::ChannelForbidden');
        if (exists $self->{session}{chats}{$chat->{id}}) {
            # old regular chats don't have access_hash o_O
            if (exists $chat->{access_hash}) {
                $self->{session}{chats}{$chat->{id}}{access_hash} = $chat->{access_hash};
                $self->{session}{chats}{$chat->{id}}{username} = $chat->{username};
                $self->{session}{chats}{$chat->{id}}{title} = $chat->{title};   
            } 
            else {
                $self->{session}{chats}{$chat->{id}}{title} = $chat->{title};
            }

        }
        else {
            # old regular chats don't have access_hash o_O
            if (exists $chat->{access_hash}) {
                $self->{session}{chats}{$chat->{id}} = {
                    access_hash => $chat->{access_hash},
                    username => $chat->{username},
                    title => $chat->{title}
                };
            }
            else {
                $self->{session}{chats}{$chat->{id}} = {
                    title => $chat->{title}
                };
            }
        }
    }
}

sub cached_usernames
{
    my $self = shift;
    
    return map { ($_->{first_name} // '').' '.($_->{last_name} // '') } 
           grep { $_->{first_name} or $_->{last_name} } 
           values %{$self->{session}{users}};
}

sub cached_nicknames
{
    my $self = shift;

    my $users = $self->{session}{users};
    my $chats = $self->{session}{chats};
    
    return map { '@'.$_->{username} } grep { $_->{username} } 
          ( values %$users, values %$chats );
}

sub name_to_id
{
    my ($self, $nick) = @_;

    my $users = $self->{session}{users};
    my $chats = $self->{session}{chats};

    if ($nick =~ /^@/) {
        $nick =~ s/^@//;
        for my $uid (keys %$users) {
            return $uid if defined $users->{$uid}{username} and $users->{$uid}{username} eq $nick;
        }
        for my $uid (keys %$chats) {
            return $uid if defined $chats->{$uid}{username} and $chats->{$uid}{username} eq $nick;
        }
    }
    else {
        for my $uid (keys %$users) {
            return $uid if ($users->{$uid}{first_name} // '').' '.($users->{$uid}{last_name} // '') eq $nick;
        }
    }

    return undef;
}

sub peer
{
    my ($self, $nick) = @_;

    my $users = $self->{session}{users};
    my $chats = $self->{session}{chats};

    if ($nick =~ /^@/) {
        $nick =~ s/^@//;
        for my $uid (keys %$users) {
            return Telegram::InputPeerUser->new( 
                user_id => $uid, 
                access_hash => $users->{$uid}{access_hash}
            ) if defined $users->{$uid}{username} and $users->{$uid}{username} eq $nick;
        }
        for my $uid (keys %$chats) {
            return Telegram::InputPeerChat->new( 
                chat_id => $uid, 
                access_hash => $chats->{$uid}{access_hash}
            ) if defined $chats->{$uid}{username} and $chats->{$uid}{username} eq $nick;
        }
    }
    return undef;
}

sub peer_from_id
{
    my ($self, $id) = @_;
    croak unless defined $id;

    my $users = $self->{session}{users};
    my $chats = $self->{session}{chats};

    if (exists $users->{$id}) {
        return Telegram::InputPeerUser->new( 
            user_id => $id, 
            access_hash => $users->{$id}{access_hash}
        );
    }
    if (exists $chats->{$id}) {
        if (defined $chats->{$id}{access_hash}) {
            return Telegram::InputPeerChannel->new( 
                channel_id => $id, 
                access_hash => $chats->{$id}{access_hash}
            );
        }
        else {
            return Telegram::InputPeerChat->new( 
                chat_id => $id, 
            );
        }
    }
    return undef;
}

sub peer_name
{
    my ($self, $id) = @_;
    croak unless defined $id;

    my $users = $self->{session}{users};
    my $chats = $self->{session}{chats};

    if (exists $users->{$id}) {
        say "found user ", Dumper($users->{$id}) if $self->{debug};
        return ($users->{$id}{first_name} // '' ).' '.($users->{$id}{last_name} // '');
    }
    if (exists $chats->{$id}) {
        say "found chat ", Dumper($chats->{$id}) if $self->{debug};
        return ($chats->{$id}{title} // "chat $id");
    }
    return undef;
}

sub _get_timer_cb
{
    my $self = shift;
    return sub {
        say "timer tick" if $self->{debug};
        $self->invoke( Telegram::Account::UpdateStatus->new( offline => 0 ) );
        #        $self->invoke( Telegram::Updates::GetDifference->new( 
        #            date => $self->{session}{update_state}{date},
        #            pts => $self->{session}{update_state}{pts},
        #            qts => -1,
        #    ), 
        #    sub {
        #        $self->_handle_upd_diff(@_);
        #    }) unless $self->{noupdate};
        #$self->invoke( Telegram::Updates::GetState->new ) unless $self->{noupdate};
        $self->{_mt}->invoke( MTProto::Ping->new( ping_id => rand(2**31) ) ) if $self->{keepalive};
    }
}

1;

