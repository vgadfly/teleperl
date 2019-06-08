use Modern::Perl;

package TeleUpd;

## This package handles updates

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

use fields qw( session _tg _q _lock );

use Scalar::Util qw/weaken/;
use AnyEvent;
use Data::Dumper;

use Telegram::Updates::GetState;
use Telegram::Updates::GetDifference;
use Telegram::Updates::GetChannelDifference;

sub new
{
    my ($class, $session, $tg) = @_;
    my $self = fields::new( ref $class || $class );
    
    weaken $tg;
    $self->{_tg} = $tg;
    $self->{session} = $session;
    $self->_lock;

    return $self;
}

sub sync
{
    my ($self, $force) = @_;

    $self->_lock;

    if (not exists $self->{session} or $force) {
        $self->{_tg}->invoke( Telegram::Updates::GetState->new, 
            sub {
                my $us = shift;
                if ($us->isa('Telegram::Updates::State')) {
                    $self->{session}{seq} = $us->{seq};
                    $self->{session}{pts} = $us->{pts};
                    $self->{session}{date} = $us->{date};
                }
                $self->_unlock;
            }
        );
    }
    else {
        $self->{_tg}->invoke( 
            Telegram::Updates::GetDifference->new( 
                   date => $self->{session}{date},
                   pts => $self->{session}{pts},
                   qts => -1,
            ), 
            sub {
                $self->_handle_upd_diff(@_);
            }
        );
    }
}

sub _lock
{
    my $self = shift;
    AE::log warn => "locking updates queue";
    $self->{_lock} = 1;
}

sub _unlock
{
    my $self = shift;
    local $_;

    AE::log warn => "unlocking updates queue";
    # process queue
    $self->_do_handle_updates($_) while ($_ = shift @{$self->{_q}});
    
    $self->{_lock} = 0;
}

sub _check_pts
{
    my ($self, $pts, $count, $channel) = @_;

    my $local_pts = defined $channel ? 
        $self->{session}{channel_pts}{$channel} :
        $self->{session}{pts};

    if (defined $local_pts and $local_pts + $count < $pts) {
        AE::log debug => "local_pts=$local_pts, pts=$pts, count=$count, channel=".($channel//"");
        if (defined $channel) {
            my $channel_peer = $self->{_tg}->peer_from_id( $channel );
            $self->{_tg}->invoke( Telegram::Updates::GetChannelDifference->new(
                channel => $channel_peer,
                filter => Telegram::ChannelMessagesFilterEmpty->new,
                pts => $local_pts,
                limit => 0
            ),
            sub { $self->_handle_channel_diff( $channel, @_ ) }
            ) if defined $channel_peer;
        }
        else {
            $self->{_tg}->invoke( Telegram::Updates::GetDifference->new( 
                date => $self->{session}{date},
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
            $self->{session}{channel_pts}{$channel} = $pts;
        }
        else {
            $self->{session}{pts} = $pts;
        }
        return 1;
    }
}

sub _debug_print_update
{
    my ($self, $upd) = @_;

    AE::log warn => __LINE__ . " " . ref $upd;
    
    if ($upd->isa('Telegram::Update::UpdateNewChannelMessage')) {
        my $ch_id = $upd->{message}{to_id}{channel_id};
        AE::log debug => "chan=$ch_id pts=$upd->{pts}(+$upd->{pts_count}) last=$self->{session}{channel_pts}{$ch_id}"
            if (exists $upd->{pts});
    }
    elsif ($upd->isa('Telegram::Update::UpdateNewMessage')) {
        AE::log debug => "pts=$upd->{pts}(+$upd->{pts_count}) last=$self->{session}{pts}"
            if (exists $upd->{pts});
    }
    AE::log warn => "seq=$upd->{seq}" if (exists $upd->{seq} and $upd->{seq} > 0);

}

sub _handle_update
{
    my ($self, $upd) = @_;

    #say ref $upd;

    $self->_debug_print_update($upd);
    
    if ($upd->isa('Telegram::UpdateChannelTooLong')) {
        my $channel = $self->{_tg}->peer_from_id( $upd->{channel_id} );
        my $local_pts = $self->{session}{channel_pts}{$upd->{channel_id}};
        AE::log warn => "rcvd ChannelTooLong for $upd->{channel_id} but no local pts thus no updates"
            unless defined $local_pts;
        $self->{_tg}->invoke(
            Telegram::Updates::GetChannelDifference->new(
                channel => $channel,
                filter => Telegram::ChannelMessagesFilterEmpty->new,
                pts => $local_pts,
                limit => 0
            ),
            sub { $self->_handle_channel_diff( $upd->{channel_id}, @_ ) }
        ) if defined $channel and $local_pts;
        return;
    }
    
    my $pts_good;
    if (
        $upd->isa('Telegram::UpdateNewChannelMessage') or
        $upd->isa('Telegram::UpdateEditChannelMessage')
    ) {
        my $chan = exists $upd->{message}{to_id} ? $upd->{message}{to_id}{channel_id} : undef;
        AE::log warn => "chanmsg without dest ".Dumper $upd unless defined $chan;
        $pts_good = $self->_check_pts( $upd->{pts}, $upd->{pts_count}, $chan
        ) if defined $chan;
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
            $self->{_tg}{on_update}->($upd->{message}) if $self->{_tg}{on_update};
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
    $self->{_tg}{on_update}->( $in_msg ) if $self->{_tg}{on_update};
}

## store seq and date
sub _store_seq_date
{
    my ($self, $seq, $date) = @_;
    if ($seq > 0) {
        if ($seq > $self->{session}{seq} + 1) {
            # update hole
            AE::log warn => "\rupdate seq hole\n";
        }
        $self->{session}{seq} = $seq;
    }
    $self->{session}{date} = $date;
}

sub _handle_upd_diff
{
    my ($self, $diff) = @_;
    my $unlock = 1;

    #say ref $diff;

    unless ( $diff->isa('Telegram::Updates::DifferenceABC') ) {
        AE::log warn => "not diff: " . ref $diff;
        $self->_unlock;
        return;
    }
    return $self->_unlock if $diff->isa('Telegram::Updates::DifferenceEmpty');

    #my @t = localtime;
    #print "---\n", join(":", map {"0"x(2-length).$_} reverse @t[0..2]), " : ";
    #say ref $diff;
  
    my $upd_state;
    if ($diff->isa('Telegram::Updates::Difference')) {
        $upd_state = $diff->{state};
    }
    if ($diff->isa('Telegram::Updates::DifferenceSlice')) {
        $unlock = 0;
        $upd_state = $diff->{intermediate_state};
        $self->{_tg}->invoke( Telegram::Updates::GetDifference->new( 
                    date => $upd_state->{date},
                    pts => $upd_state->{pts},
                    qts => -1,
            ),
            sub { $self->_handle_upd_diff(@_) }
        );
    }
    unless (defined $upd_state) {
        AE::log warn => "bad update state " . Dumper $diff;
        $self->_unlock;
        return;
    }
    #say "new pts=$upd_state->{pts}, last=$self->{session}{pts}";
    $self->{session}{seq} = $upd_state->{seq};
    $self->{session}{date} = $upd_state->{date};
    $self->{session}{pts} = $upd_state->{pts};
    
    $self->{_tg}->_cache_users(@{$diff->{users}});
    $self->{_tg}->_cache_chats(@{$diff->{chats}});
    
    for my $upd (@{$diff->{other_updates}}) {
        $self->_handle_update( $upd );
    }
    for my $msg (@{$diff->{new_messages}}) {
        #say ref $msg;
        $self->{_tg}{on_update}->($msg) if $self->{_tg}{on_update};
    }

    $self->_unlock if $unlock;
}

sub _handle_channel_diff
{
    my ($self, $channel, $diff) = @_;

    #say ref $diff;
    
    unless ( $diff->isa('Telegram::Updates::ChannelDifferenceABC') ) {
        AE::log warn => "not diff: " . ref $diff;
        return;
    }
    return if $diff->isa('Telegram::Updates::ChannelDifferenceEmpty');

    #my @t = localtime;
    #print "---\n", join(":", map {"0"x(2-length).$_} reverse @t[0..2]), " : ";
    #say ref $diff;
  
    if ($diff->isa('Telegram::Updates::ChannelDifferenceTooLong')) {
        AE::log warn => "ChannelDifferenceTooLong";
        $self->{_tg}->_cache_users(@{$diff->{users}});
        $self->{_tg}->_cache_chats(@{$diff->{chats}});
        $self->{session}{channel_pts}{$channel} = $diff->{pts};  
        AE::log info => "old pts=",$self->{session}{channel_pts}{$channel};
        AE::log info => "new pts=$diff->{pts}";
        for my $msg (@{$diff->{messages}}) {
           #say ref $msg;
           $self->{_tg}{on_update}->($msg) if $self->{_tg}{on_update};
        }

        #$self->{_tg}->invoke( Telegram::Updates::GetChannelDifference->new(
        #    channel => $channel_peer,
        #    filter => Telegram::ChannelMessagesFilterEmpty->new,
        #    pts => $local_pts,
        #    limit => 0
        #),
        #sub { $self->_handle_channel_diff( $channel, @_ ) }
        #) if defined $channel_peer;
        return;
    }
    AE::log debug => "channel=$channel, new pts=$diff->{pts}" ;
    $self->{session}{channel_pts}{$channel} = $diff->{pts};  

    $self->{_tg}->_cache_users(@{$diff->{users}});
    $self->{_tg}->_cache_chats(@{$diff->{chats}});
    
    for my $upd (@{$diff->{other_updates}}) {
        $self->_handle_update( $upd );
    }
    for my $msg (@{$diff->{new_messages}}) {
        #say ref $msg;
        $self->{_tg}{on_update}->($msg) if $self->{_tg}{on_update};
    }
}

## process one Telegram::Updates
## enqueue if Updater is busy processing seq hole or diff

sub handle_updates
{
    my ($self, $updates) = @_;

    if ( $self->{_lock} ) {
        push @{$self->{_q}}, $updates;
    }
    else {
        $self->_do_handle_updates($updates);
    }
}

sub _do_handle_updates
{
    my ($self, $updates) = @_;

    # short spec updates
    # ShortSentMessage?
    if ( $updates->isa('Telegram::UpdateShortMessage') or
        $updates->isa('Telegram::UpdateShortChatMessage') )
    {
        $self->_store_seq_date( 0, $updates->{date} );
        if ( $self->_check_pts( $updates->{pts}, $updates->{pts_count} ) ) {
            $self->_handle_short_update( $updates );
        }
    }

    # XXX: UpdatesCombined
    # regular updates
    if ( $updates->isa('Telegram::Updates') ) {
        $self->{_tg}->_cache_users( @{$updates->{users}} );
        $self->{_tg}->_cache_chats( @{$updates->{chats}} );
        $self->_store_seq_date( $updates->{seq}, $updates->{date} );
        
        for my $upd ( @{$updates->{updates}} ) {
            $self->_handle_update($upd);
        }
    }

    # short generic updates
    if ( $updates->isa('Telegram::UpdateShort') ) {
        $self->_store_seq_date( 0, $updates->{date} );
        $self->_handle_update( $updates->{update} );
    }
    
    if ( $updates->isa('Telegram::UpdatesTooLong') ) {
        $self->{_tg}->invoke( Telegram::Updates::GetDifference->new( 
                date => $self->{session}{date},
                pts => $self->{session}{pts},
                qts => -1,
            ), 
            sub { $self->_handle_upd_diff(@_) } 
        );
    }
}

# XXX: exists only for unification, handle short updates elsewhere
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

1;

