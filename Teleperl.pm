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

sub new
{
    my ($self, %arg) = @_;

    $self = bless( {}, $self ) unless ref $self;
    $self->init_object_events;

    my $new_session = $arg{force_new_session} // 0;
    AE::log debug => "force_new_session?=".$new_session;

    croak("Teleperl::Storage required") 
        unless defined $arg{storage} and $arg{storage}->isa('Teleperl::Storage');
    my $storage = $arg{storage};

    $self->{_tg} = Telegram->new( $storage->tg_param, $storage->tg_state, force_new_session => $new_session, keepalive => 1 );
    $self->{_upd} = Teleperl::UpdateManager->new( $new_session ? {} : $storage->upd_state );
    $self->{_cache} = Teleperl::PeerCache->new( session => $storage->peer_cache );
    $self->{_storage} = $storage;

    $self->{_tg}->reg_cb( new_session => sub { $self->{_upd}->sync } );
    $self->{_tg}->reg_cb( connected => sub {
            AE::log info => "connected";
            $self->{_upd}->sync 
    });
    $self->{_tg}->reg_cb( error => sub { shift; $self->{_storage}->save; $self->event( error => @_ ) } );
    $self->{_tg}->reg_cb( update => sub { shift; $self->{_upd}->handle_updates(@_) } );
    
    $self->{_upd}->reg_cb( query => sub { shift; $self->invoke(@_) } );
    $self->{_upd}->reg_cb( cache => sub { shift; $self->{_cache}->cache(@_) } );
    $self->{_upd}->reg_cb( update => sub { shift; $self->_handle_update(@_) } );

    # translate Telegram states
    $self->{_tg}->reg_cb( state => sub { shift; $self->event( 'tg_state', @_ ) } );

    return $self;
}

sub start
{
    shift->{_tg}->start;
}

sub _handle_update
{
    my ($self, $update) = @_;

    # XXX
    $self->event( update => $update );

    AE::log trace => "update: ". Dumper($update);

    #if ( $update->isa('Telegram::Message') ) {
    #    ...
    #}
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

1;

