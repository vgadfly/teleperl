package AnyEvMiniFSM;

use Modern::Perl;

=head1 SYNOPSIS

    package Some::Custom::FSM;
    use base 'AnyEvMiniFSM';

    sub state_map {
        +{
            begin => {
                signal1 => [state1 => qw(method1 method2 method3)],
                signal2 => [state2 => qw(method4)]
            },
            state1 => {
                signal3 => [state3 => qw(method5 method6)],
            },
            state2 => {},
            state3 => {},
        };
    }

    sub cbs {
        +{
            method1 => {},
            method2 => {},
            method4 => { retries => 2 },
            method5 => { retries => 1 },
            method6 => { cb => 'writelog' },
        }
    }

    sub method1 {
        my ($self, %opts) = @_;
        my $signal_param = $opts{signal_param};
        ...
        return {
            signal => 'signal3',
            signal_param => { ... },
            delay => 60,
        };
    }

    sub method2 { ... }
    sub method3 { ... }
    sub method4 { ... }
    sub method5 { ... }
    sub writelog { ... }
...

in user:

    my $fsm = Some::Custom::FSM->create(...)
            ->push_signal(signal_name => {signal => 'parameters'})
            ->start();
    my $fsm_id = $fsm->id;


Callbacks map is HASH with parameters:

=over 1

=item [cb] - name of callback method, or take it from state map if not specified

=back

Callbacks are called on object before going to new state with following arguments:

=over 1

=item old_state -  string

=item new_state - string

=item signal - string

=item signal_param - HASH ref

=item ae_param - ARRAY ref with arguments passed by AE to it's callback, if called from AE

=item closure - additional arguments from call to ae_cb, if any

=back

Method must return HASH reference which may contain information about
new signal for continuing FSM:

=over 1

=item signal - new signal name

=item signal_param - hash of params to pass to new signal handler

=back

Signals are pushed into FIFO-queue and processed sequentially.
If signal is not found for current state, it is skipped.

TODO

MAY BE RETHINK

=cut

=pod

    sub state_map { +{
        begin => {
            connect_direct   => [ connecting_dc => ...],
            connect_to_proxy => [ connecting_proxy => ... ],
        },
        connecting_proxy => {
            success_conn     => [ connecting_dc => tell_proxy_where_to_go ],
            fail_conn        => [ retry_proxy   => set_retry_timer ],
        
        },
        connecting_dc => {
            success_conn     => [ dc_connected => start_mtproto_on_sock ],
            fail_conn        => [ retry_dc => set_retry_timer ],
        },
        retry_dc => {
            retry_timer_fire => [ connecting_dc => ... ],
            fail_conn        => [ begin => check_retry_limit ],
            
        },
        dc_connected => {
            req_updates      => [ run => tg_run_updates ],
            run              => [ run => (XXX) ],
        },
        run => {
            run              => [ run => (XXX) ],
            signal_on_read   => [ run => do_read ],
            signal_on_write  => [ run => sub { $_[0]->{_lock}=0; $_[0]->_dequeue } ],
            signal_on_error  => [ run => on_error ],
            shutdown         => [ final => qw(send_close save_session) ],
        },
        final => {}
        ...
    } }

    ...

    sub start_mtproto_on_sock {
        ...

        $aehandle->on_read(  $fsm->ae_cb('signal_on_read') );
        $aehandle->on_error( $fsm->ae_cb('signal_on_error', \$ipaddr, \$port) );
        $aehandle->on_drain( $fsm->ae_cb('signal_on_write') );
        ...
    }

    sub on_error {
        my ($self, %opts) = @_;
        ...

        tell_caller_cooldown_this_addr(@{ $opts{closure} });

        return {
            signal => 'shutdown',
            signal_param => { ... },
        }
    ...

=cut


$TO_BE_INVENTED = 1;