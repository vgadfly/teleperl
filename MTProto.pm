use Modern::Perl;

package MTProto::Message;

use fields qw( msg_id seq data object );

use TL::Object;
use Time::HiRes qw/time/;
use Carp;
use Scalar::Util qw/blessed/;

sub msg_id
{
    my $time = time;
    my $hi = int( $time );
    my $lo = int ( ( $time - $hi ) * 2**32 );
    return unpack( "Q<", pack( "(LL)<", $lo, $hi ) );
}

sub new
{
    my ($class, $seq, $data, $msg_id) = @_;
    my $self = fields::new( ref $class || $class );
    $self->{msg_id} = $msg_id // msg_id() + ($seq  << 2 ); # provides uniq ids when sending many msgs in short time
    $self->{seq} = $seq;
    if (blessed $data) {
        croak "not a TL object" unless $data->isa('TL::Object');
        $self->{object} = $data;
        $self->{data} = pack "(a4)*", $data->pack;
    }
    else {
        $self->{data} = $data;
    }
    return $self;
}

sub pack
{
    my $self = shift;
    return pack( "(QLL)<", $self->{msg_id}, $self->{seq}, length($self->{data}) ).$self->{data};
}

sub unpack
{
    my ($class, $stream) = @_;
    my $self = fields::new( ref $class || $class );
    my ($msg_id, $seq, $len) = unpack( "(QLL)<", $stream );
    $self->{data} = substr($stream, 16, $len);
    $self->{msg_id} = $msg_id;
    $self->{seq} = $seq;

    #    print "unpacked msg $seq:$msg_id with $len bytes of data\n";
    my @stream = unpack( "(a4)*", $self->{data} );
    eval { $self->{object} = TL::Object::unpack_obj(\@stream); };
    my ($package, $filename, $line) = caller;
    AE::log warn => "$@ (called from $filename:$line)" if $@;

    #print unpack "H*", $self->{data} unless (defined $self->{object});
    #print ref $self->{object} if (defined $self->{object});
    #print "\n";

    return $self;
}


package MTProto;

use Data::Dumper;

use fields qw( debug session on_message on_error noack last_error 
    _lock _plain _pending _tcp_first _aeh _handle_plain _pq _queue);

use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::Socket;
use Scalar::Util;

use Carp;
use IO::Socket;
use IO::Uncompress::Gunzip qw/gunzip/;
use Crypt::OpenSSL::Bignum;
use Crypt::OpenSSL::RSA;
use Crypt::OpenSSL::Random;
use Crypt::OpenSSL::AES;
use Digest::SHA qw(sha1 sha256);

use Math::Prime::Util qw/factor/;
use List::Util qw/min max/;

use TL::Object;

use MTProto::ReqPqMulti;
use MTProto::ResPQ;
use MTProto::PQInnerData;
use MTProto::ReqDHParams;
use MTProto::SetClientDHParams;
use MTProto::ClientDHInnerData;
use MTProto::MsgsAck;
use MTProto::DestroySession;

use Keys;

sub aes_ige_enc
{
    my ($plain, $key, $iv) = @_;
    my $aes = Crypt::OpenSSL::AES->new( $key );

    my $iv_c = substr( $iv, 0, 16 );
    my $iv_p = substr( $iv, 16, 16 );

    my $cypher = '';

    for (my $i = 0; $i < length($plain); $i += 16){
        my $m = substr($plain, $i, 16);
        my $c = $aes->encrypt( $iv_c ^ $m ) ^ $iv_p;

        $iv_p = $m;
        $iv_c = $c;

        $cypher .= $c;
    }

    return $cypher;
}

sub aes_ige_dec
{
    my ($cypher, $key, $iv) = @_;
    my $aes = Crypt::OpenSSL::AES->new( $key );

    my $iv_c = substr( $iv, 0, 16 );
    my $iv_p = substr( $iv, 16, 16 );

    my $plain = '';

    for (my $i = 0; $i < length($cypher); $i += 16){
        my $c = substr($cypher, $i, 16);
        my $m = $aes->decrypt( $iv_p ^ $c ) ^ $iv_c;

        $iv_p = $m;
        $iv_c = $c;

        $plain .= $m;
    }

    return $plain;
}

sub gen_msg_key
{
    my ($self, $plain, $x) = @_;
    my $msg_key = substr( sha256(substr($self->{session}{auth_key}, 88+$x, 32) . $plain), 8, 16 );
    return $msg_key;
}

sub gen_aes_key
{
    my ($self, $msg_key, $x) = @_;
    my $sha_a = sha256( $msg_key . substr($self->{session}{auth_key}, $x, 36) );
    my $sha_b = sha256( substr($self->{session}{auth_key}, 40+$x, 36) . $msg_key );
    my $aes_key = substr($sha_a, 0, 8) . substr($sha_b, 8, 16) . substr($sha_a, 24, 8);
    my $aes_iv = substr($sha_b, 0, 8) . substr($sha_a, 8, 16) . substr($sha_b, 24, 8);
    return ($aes_key, $aes_iv);
}


sub new
{
    my @args = qw(session debug noack on_message on_error);
    my ($class, %arg) = @_;
    
    my $self = fields::new( ref $class || $class );
    
    $self->{_tcp_first} = 1;
    $self->{_plain} = 0;
    $self->{_lock} = 0;
    
    @$self{@args} = @arg{@args};

    # init AE socket wrap
    my $aeh = $arg{socket};
    $aeh->on_read( $self->_get_read_cb );
    $aeh->on_error( $self->_get_error_cb );
    $aeh->on_drain( $self->_get_write_cb );
    $self->{_aeh} = $aeh;
    
    # generate new auth_key
    $self->start_session unless defined $self->{session}{auth_key};

    return $self;
}

sub _get_read_cb
{
    my $self = shift;
    return sub {
        # all reads start with recving packet length
        $self->{_aeh}->unshift_read( chunk => 4, sub {
                my $len = unpack "L<", $_[1];
                if ($len < 16) {
                    # it is error
                    $_[0]->unshift_read( chunk => $len, sub {
                            my $error = $_[1];
                            $self->_handle_error($error);
                    } )
                } else {
                    $_[0]->unshift_read( chunk => $len, sub {
                            my $msg = $_[1];
                            if ($self->{_plain}) {
                                $self->_recv_plain($msg);
                            }
                            else {
                                $self->_handle_encrypted($msg); 
                            }
                    } )
                }
        } );
    }
}

sub _get_error_cb
{
    my $self = shift;
    return sub {
        say "Socket IO error" if $self->{debug};
        my ($hdl, $fatal, $msg) = @_;
        if ($self->{on_error}) {
            &{$self->{on_error}}( message => $msg );
        }
        $self->{last_error} = {message => $msg};
        # ignore $fatal, destroy anyway
        $hdl->destroy;
    }
}

sub _get_write_cb
{
    my $self = shift;
    return sub {
        $self->{_lock} = 0;
        $self->_dequeue;
    }
}

## generate auth key and shit
sub start_session
{
    my $self = shift;

    AE::log debug => "starting new session\n" if $self->{debug};

    $self->{_plain} = 1;
    $self->{session}{seq} = 0;

#
# STEP 1: PQ Request
#

    my $nonce = Crypt::OpenSSL::Bignum->new_from_bin(
        Crypt::OpenSSL::Random::random_pseudo_bytes(16)
    );
    my $req_pq = MTProto::ReqPqMulti->new;
    $req_pq->{nonce} = $nonce;
    $self->{_pq}{nonce} = $nonce;

    $self->{_handle_plain} = sub {
            $self->_phase_one(@_);
    };
    $self->_send_plain( pack( "(a4)*", $req_pq->pack ) );
}

## STEP 1 reply parser
## handle ResPQ

sub _phase_one 
{
    my ($self, $data) = @_;
    my $nonce = $self->{_pq}{nonce};
    
    my @stream = unpack( "(a4)*", $data );
    die unless @stream;

    my $res_pq = TL::Object::unpack_obj( \@stream );
    die unless $res_pq->isa("MTProto::ResPQ");

    AE::log debug => "got ResPQ\n" if $self->{debug};

    my $pq = unpack "Q>", $res_pq->{pq};
    my @pq = factor($pq);

#
# STEP 2: DH exchange
#

    my $pq_inner = MTProto::PQInnerData->new;
    $pq_inner->{pq} = $res_pq->{pq};
    $pq_inner->{p} = pack "L>", min @pq;
    $pq_inner->{q} = pack "L>", max @pq;

    $pq_inner->{nonce} = $nonce;
    $pq_inner->{server_nonce} = $res_pq->{server_nonce};
    my $new_nonce = Crypt::OpenSSL::Bignum->new_from_bin(
        Crypt::OpenSSL::Random::random_pseudo_bytes(32)
    );
    $pq_inner->{new_nonce} = $new_nonce;
    $self->{_pq}{new_nonce} = $new_nonce;
    $self->{_pq}{server_nonce} = $res_pq->{server_nonce};

    $data = pack "(a4)*", $pq_inner->pack;
    my $pad = Crypt::OpenSSL::Random::random_pseudo_bytes(255-20-length($data));
    $data = "\0". sha1($data) . $data . $pad;

    my @keys = grep {defined} map { Keys::get_key($_) } @{$res_pq->{server_public_key_fingerprints}};
    die "no suitable keys" unless (@keys);

    my $rsa = $keys[0];
    $rsa->use_no_padding;
    my $enc_data = $rsa->encrypt($data);

    my $req_dh = MTProto::ReqDHParams->new;
    $req_dh->{nonce} = $nonce;
    $req_dh->{server_nonce} = $res_pq->{server_nonce};
    $req_dh->{p} = $pq_inner->{p};
    $req_dh->{q} = $pq_inner->{q};
    $req_dh->{public_key_fingerprint} = Keys::key_fingerprint($rsa);
    $req_dh->{encrypted_data} = $enc_data;

    $self->{_handle_plain} = sub {
            $self->_phase_two(@_)
    };
    $self->_send_plain( pack( "(a4)*", $req_dh->pack ) );
}

## STEP 2 reply parser
## handle DH Params

sub _phase_two
{
    my ($self, $data) = @_;

    my $nonce = $self->{_pq}{nonce};
    my $new_nonce = $self->{_pq}{new_nonce};
    my $server_nonce = $self->{_pq}{server_nonce};

    my @stream = unpack( "(a4)*", $data );
    die unless @stream;

    my $dh_params = TL::Object::unpack_obj( \@stream );
    die unless $dh_params->isa('MTProto::ServerDHParamsOk');

    AE::log debug => "got ServerDHParams\n" if $self->{debug};

    my $tmp_key = sha1( $new_nonce->to_bin() . $server_nonce->to_bin ).
            substr( sha1( $server_nonce->to_bin() . $new_nonce->to_bin ), 0, 12 );

    my $tmp_iv = substr( sha1( $server_nonce->to_bin() . $new_nonce->to_bin ), -8 ).
            sha1( $new_nonce->to_bin() . $new_nonce->to_bin() ).
            substr( $new_nonce->to_bin(), 0, 4 );

    my $dh_ans = aes_ige_dec( $dh_params->{encrypted_answer}, $tmp_key, $tmp_iv );
    my $digest = substr( $dh_ans, 0, 20 );
    my $ans = substr( $dh_ans, 20 );

    # ans with padding -> can't check digest
    @stream = unpack( "(a4)*", $ans );
    die unless @stream;

    my $dh_inner = TL::Object::unpack_obj( \@stream );
    die unless $dh_inner->isa('MTProto::ServerDHInnerData');
    
    AE::log debug => "got ServerDHInnerData\n" if $self->{debug};

    die "bad nonce" unless $dh_inner->{nonce}->equals( $nonce );
    die "bad server_nonce" unless $dh_inner->{server_nonce}->equals( $server_nonce );

#
# STEP 3: Complete DH
#

    my $bn_ctx = Crypt::OpenSSL::Bignum::CTX->new;
    my $p = Crypt::OpenSSL::Bignum->new_from_bin( $dh_inner->{dh_prime} );
    my $g_a = Crypt::OpenSSL::Bignum->new_from_bin( $dh_inner->{g_a} );
    my $g = Crypt::OpenSSL::Bignum->new_from_word( $dh_inner->{g} );
    my $b = Crypt::OpenSSL::Bignum->new_from_bin(
        Crypt::OpenSSL::Random::random_pseudo_bytes( 256 )
    );

    my $g_b = $g->mod_exp( $b, $p, $bn_ctx );

    my $client_dh_inner = MTProto::ClientDHInnerData->new;
    $client_dh_inner->{nonce} = $nonce;
    $client_dh_inner->{server_nonce} = $server_nonce;
    $client_dh_inner->{retry_id} = 0;
    $client_dh_inner->{g_b} = $g_b->to_bin;

    $data = pack "(a4)*", $client_dh_inner->pack();
    $data = sha1($data) . $data;
    my $len = (length($data) + 15 ) & 0xfffffff0;
    my $pad = Crypt::OpenSSL::Random::random_pseudo_bytes($len - length($data));
    $data = $data . $pad;
    my $enc_data = aes_ige_enc( $data, $tmp_key, $tmp_iv );

    my $dh_par = MTProto::SetClientDHParams->new;
    $dh_par->{nonce} = $nonce;
    $dh_par->{server_nonce} = $server_nonce;
    $dh_par->{encrypted_data} = $enc_data;

    # session auth key
    $self->{session}{auth_key} = $g_a->mod_exp( $b, $p, $bn_ctx )->to_bin;

    $self->{_handle_plain} = sub {
        $self->_phase_three(@_)
    };
    $self->_send_plain( pack( "(a4)*", $dh_par->pack ) );
}

## STEP 3 reply parser
## check reply to DH params

sub _phase_three
{
    my ($self, $data) = @_;

    my $nonce = $self->{_pq}{nonce};
    my $new_nonce = $self->{_pq}{new_nonce};
    my $server_nonce = $self->{_pq}{server_nonce};
    my $auth_key = $self->{session}{auth_key};
    
    my @stream = unpack( "(a4)*", $data );
    die unless @stream;

    my $result = TL::Object::unpack_obj( \@stream );
    die unless $result->isa('MTProto::DhGenOk');

    AE::log debug => "DH OK\n" if $self->{debug};

    # check new_nonce_hash
    my $auth_key_aux_hash = substr(sha1($auth_key), 0, 8);
    my $auth_key_hash = substr(sha1($auth_key), -8);

    my $nnh = $new_nonce->to_bin . pack("C", 1) . $auth_key_aux_hash;
    $nnh = substr(sha1($nnh), -16);
    die "bad new_nonce_hash1" unless $result->{new_nonce_hash1}->to_bin eq $nnh;

    AE::log debug => "session started\n" if $self->{debug};

    $self->{session}{salt} = substr($new_nonce->to_bin, 0, 8) ^ substr($server_nonce->to_bin, 0, 8);
    $self->{session}{session_id} = Crypt::OpenSSL::Random::random_pseudo_bytes(8);
    #$self->{session}{auth_key} = $auth_key;
    $self->{session}{auth_key_id} = $auth_key_hash;
    $self->{session}{auth_key_aux} = $auth_key_aux_hash;
    
    # ecrypted connection established
    $self->{_plain} = 0;
    delete $self->{_pq};
    # process message queue
    $self->_dequeue;
}

## send unencrypted message
sub _send_plain
{
    my ($self, $data) = @_;
    my $datalen = length( $data );
    my $pkglen = $datalen + 20;

    # init tcp intermediate (no seq_no & crc)
    if ($self->{_tcp_first}) {
        $self->{_aeh}->push_write( pack("L", 0xeeeeeeee) );
        $self->{_tcp_first} = 0;
    }
    $self->{_aeh}->push_write( 
        pack( "(LQQL)<", $pkglen, 0, MTProto::Message::msg_id(), $datalen ) . $data
    );
}

sub _enqueue
{
    my ($self, $in_msg) = @_;
    push @{$self->{_queue}}, $in_msg;
}

sub _dequeue
{
    my $self = shift;
    local $_;

    # don't do anything if session is not yet espablished
    return unless $self->{session}{auth_key_id};

    $self->{_lock} = 0;

    $self->_real_send($_) while ($_ = shift @{$self->{_queue}});
}

## send encrypted message(s)
##
## if send buffer is empty -- writes staight to socket
## else -- pushes to internal queue, which is then processed when socket 
## becomes ready
##
## multiple messages can be packed together
##
sub send
{
    my ($self, @msg) = @_;
    local $_;

    AE::log info => "sending ".ref($_)." \n" for @msg;
    
    # XXX: just use lock in new
    # check if session is ready
    unless ($self->{session}{session_id} and $self->{session}{auth_key_id}) {
        AE::log debug => "session not ready, queueing\n" if $self->{debug};
        $self->_enqueue($_) for @msg;
        return;
    }
    if ( $self->{_lock} ) {
        $self->_enqueue($_) for @msg;
    }
    else {
        # XXX: pack multiple messages together
        $self->_real_send($_) for @msg;
    }
}

sub _real_send
{
    my ($self, $msg) = @_;
    
    $self->{_lock} = 1;

    # init tcp intermediate (no seq_no & crc)
    if ($self->{_tcp_first}) {
        $self->{_aeh}->push_write( pack( "L", 0xeeeeeeee ) );
        $self->{_tcp_first} = 0;
    }
    croak "not MTProto::Message" unless $msg->isa('MTProto::Message');
    
    my $payload = $msg->pack;
    my $pad = Crypt::OpenSSL::Random::random_pseudo_bytes( 
        -(12+length($msg->{data})) % 16 + 12 );

    my $plain = $self->{session}{salt} . $self->{session}{session_id} . $payload . $pad;

    my $msg_key = $self->gen_msg_key( $plain, 0 );
    my ($aes_key, $aes_iv) = $self->gen_aes_key( $msg_key, 0 );
    my $enc_data = aes_ige_enc( $plain, $aes_key, $aes_iv );

    my $packet = $self->{session}{auth_key_id} . $msg_key . $enc_data;

    if ($self->{debug}) {
        AE::log debug => "sending $msg->{seq}:$msg->{msg_id}, ".length($packet). " bytes encrypted\n";
    }
    $self->{_aeh}->push_write( pack("L<", length($packet)) . $packet );
}

## recv unencrypted message
sub _recv_plain
{
    my ($self, $data) = @_;

    #$$authkey = substr($data, 0, 8);
    #$$msgid = substr($data, 8, 8);
    my $len = unpack "L<", substr($data, 16, 4);
    &{$self->{_handle_plain}}( substr($data, 20, $len) );
}

## low level error reporting
sub _handle_error
{
    my ($self, $err) = @_;
    my $error = unpack( "l<", $err );
    if ($self->{on_error}) {
        &{$self->{on_error}}( code => $error );
    }
    else {
        AE::log warn => "tcp transport error: $error";
    }
    $self->{last_error} = { code => $error };
}

sub _handle_msg
{
    my ($self, $msg) = @_;

    if ($self->{debug}) {
        AE::log debug => "handle_msg $msg->{seq},$msg->{msg_id}: ";
        AE::log debug => ref $msg->{object};
    }

    # unpack msg containers
    my $objid = unpack( "L<", substr($msg->{data}, 0, 4) );
    if ($objid == 0x73f1f8dc) {
        AE::log debug => "Container\n" if $self->{debug};

        my $data = $msg->{data};
        my $msg_count = unpack( "L<", substr($data, 4, 4) );
        my $pos = 8;
        
        AE::log debug => "msg container of size $msg_count\n" if $self->{debug};
        while ( $msg_count && $pos < length($data) ) {
            my $sub_len = unpack( "L<", substr($data, $pos+12, 4) );
            my $sub_msg = MTProto::Message->unpack( substr($data, $pos) );
            $self->_handle_msg( $sub_msg );
            #print "  ", unpack( "H*", $sub_msg ), "\n";
            $pos += 16 + $sub_len;
            $msg_count--;
        }
        AE::log warn => "msg container ended prematuraly" if $msg_count;
    }
    # gzip
    elsif ($objid == 0x3072cfa1) {
        AE::log debug => "gzip\n" if $self->{debug};
        
        my @stream = unpack "(a4)*", substr($msg->{data}, 4);
        my $zdata = TL::Object::unpack_string(\@stream);
        my $objdata;
        gunzip( \$zdata => \$objdata ) or die "gunzip failure";
        
        @stream = unpack "(a4)*", $objdata;
        my $ret = TL::Object::unpack_obj(\@stream);
        
        #print "inflated: ", unpack ("H*", $objdata), "\n" if $self->{debug};
        #print ref $ret if defined $ret;
        $msg->{data} = $objdata;
        $msg->{object} = $ret;
        $self->_handle_msg( $msg ) if defined $ret;
    }
    else {
    # service msg handlers
        my $m = $msg;
        if ($m->{object}->isa('MTProto::Pong')) {
            delete $self->{_pending}{$m->{object}{msg_id}};
        }
        if ($m->{object}->isa('MTProto::MsgsAck')) {
            delete $self->{_pending}{$_} for @{$m->{object}{msg_ids}};
        }
        if ($m->{object}->isa('MTProto::BadServerSalt')) {
            $self->{session}{salt} = pack "Q<", $m->{object}{new_server_salt};
            $self->resend($m->{object}{bad_msg_id});
        }
        if ($m->{object}->isa('MTProto::BadMsgNotification')) {
            # sesssion not in sync: destroy and make new
            my $ecode = $m->{object}{error_code};
            my $bad_msg = $m->{object}{bad_msg_id};
            AE::log warn => "error $ecode recvd for $bad_msg";
            # no way to destroy current session defined
            #$self->invoke(MTProto::DestroySession->new( 
            #        session_id => unpack( "Q<", $self->{session}->{session_id} )
            #));
            $self->{session}{session_id} = Crypt::OpenSSL::Random::random_pseudo_bytes(8);
            $self->{session}{seq} = 0;
        }
        if ($m->{object}->isa('MTProto::NewSessionCreated')) {
            # seq is 1, acked below
            #$self->_ack($m->{msg_id}) if $self->{noack};
        }
        if ($m->{object}->isa('MTProto::RpcResult')) {
            # XXX: result can be packed
            delete $self->{_pending}{$m->{object}{req_msg_id}};
        }
        if (($m->{seq} & 1) and not $self->{noack}) {
            # ack content-related messages
            $self->_ack($m->{msg_id});
        }

        # pass msg to handler
        if (exists $self->{on_message} and defined $self->{on_message}) {
            &{$self->{on_message}}($m);
        }
    }

}

sub _handle_encrypted
{
    my ($self, $data) = @_;
    my @ret;

    AE::log debug => "recvd ". length($data) ." bytes encrypted\n" if $self->{debug};

    if (length($data) == 4) {
        # handle error here
        die "error ".unpack("l<", $data);
    }

    my $authkey = substr($data, 0, 8);
    my $msg_key = substr($data, 8, 16);
    my $enc_data = substr($data, 24);

    my ($aes_key, $aes_iv) = $self->gen_aes_key($msg_key, 8 );
    my $plain = aes_ige_dec( $enc_data, $aes_key, $aes_iv );
  
    my $in_salt = substr($plain, 0, 8);
    my $in_sid = substr($plain, 8, 8);
    $plain = substr($plain, 16);
    
    my $msg = MTProto::Message->unpack($plain);
    $self->_handle_msg($msg);
}

sub _ack
{
    my ($self, @msg_ids) = @_;
    my ($package, $filename, $line) = caller;
    AE::log debug => "ack ", join (",", @msg_ids), "\n" if $self->{debug};

    my $ack = MTProto::MsgsAck->new( msg_ids => \@msg_ids );
    #$ack->{msg_ids} = \@msg_ids;
    $self->invoke( $ack, 1, 1 );
}

## resend message by id, if it's pending (was not ACKed)
sub resend
{
    my ($self, $id) = @_;

    if (exists $self->{_pending}{$id}){
        $self->send( $self->{_pending}{$id} );
    }
}

## pack object and send it; return msg_id
sub invoke
{
    my ($self, $obj, $is_service, $noack) = @_;

    my $seq = $self->{session}{seq};
    $seq += 1 unless $is_service;
    my $msg = MTProto::Message->new( $seq, $obj );
    $self->{session}{seq} += 2 unless $is_service;
    $self->send($msg);
    $self->{_pending}{$msg->{msg_id}} = $msg unless $noack;
    return $msg->{msg_id};
}

1;

