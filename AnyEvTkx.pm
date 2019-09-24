package AnyEvTkx;

# FIXME it's a quick hack, inherit most from Impl::Perl

use AnyEvent (); BEGIN { AnyEvent::common_sense }
use AnyEvent::Loop;
use Tkx;

our $VERSION = $AnyEvent::VERSION;

# time() is provided via AnyEvent::Base

*AE::now        = \&AnyEvent::Loop::now;
*AE::now_update = \&AnyEvent::Loop::now_update;
*AE::io         = \&AnyEvent::Loop::io;
*AE::timer      = \&AnyEvent::Loop::timer;
*AE::idle       = \&AnyEvent::Loop::idle;
*loop           = \&MainLoop;           # compatibility with AnyEvent < 6.0
*Tkx::MainLoop  = \&MainLoop;
*now_update     = \&AnyEvent::Loop::now_update;

sub now { $AnyEvent::Loop::NOW }

sub _poll {
    Tkx::i::DoOneEvent(0);
}

my $ae_idle = 0;
sub return_to_perl_event_loop {
    Tkx::after(40, \&return_to_perl_event_loop);
    $ae_idle = 0;
    AnyEvent::Loop::one_event while not $ae_idle;
}

sub MainLoop () {
    # don't wait too much in AE's select() if nothing - guard timer
    my $ae_interrupt = AnyEvent->timer(
        after => 0.2,
        interval => 1/20,
        cb => sub { 1 },
    );
    my $ae_to_tk = AnyEvent->idle(
        cb => sub {
            $ae_idle = 1;
    });
    Tkx::after(20, \&return_to_perl_event_loop);
    while (eval { local $Tkx::TRACE; local $SIG{__DIE__}; Tkx::i::call("winfo", "exists", ".") }) {
        Tkx::i::DoOneEvent(0);
    }
}

sub io {
   my (undef, %arg) = @_;

   AnyEvent::Loop::io $arg{fh}, $arg{poll} eq "w", $arg{cb}
}

sub timer {
   my (undef, %arg) = @_;

   AnyEvent::Loop::timer $arg{after}, $arg{interval}, $arg{cb}
}

sub idle {
   my (undef, %arg) = @_;

   AnyEvent::Loop::idle $arg{cb}
}

1;
