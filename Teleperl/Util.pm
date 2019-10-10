package Teleperl::Util;

use Modern::Perl;
use base 'Exporter';

use Carp;
use Encode ':all';
use POSIX;
use Scalar::Util qw(reftype);
use AnyEvent::Log;

our $VERSION     = 0.01;
our @EXPORT      = qw(install_AE_log_crutch install_AE_log_SIG_WARN install_AE_log_SIG_DIE);
our @EXPORT_OK   = qw(get_AE_log_format_cb unlock_hashref_recurse);

=pod

Plain old module with misc utilities

=cut

# XXX workaround crutch of AE::log not handling utf8 & function name
sub install_AE_log_crutch
{
    no strict 'refs';
    no warnings 'redefine';
    *AnyEvent::log    = *AE::log    = sub ($$;@) {
        AnyEvent::Log::_log
          $AnyEvent::Log::CTX{ (caller)[0] } ||= AnyEvent::Log::_pkg_ctx +(caller)[0],
          $_[0],
          map { is_utf8($_) ? encode_utf8 $_ : $_ } (
               (split(/::/, (caller(1))[3]//':: '))[-1] . ':' . (caller(0))[2] . ": " . $_[1],
               (@_ > 2 ? @_[2..$#_] : ())
          );
    };
    *AnyEvent::logger = *AE::logger = sub ($;$) {
        AnyEvent::Log::_logger
          $AnyEvent::Log::CTX{ (caller)[0] } ||= AnyEvent::Log::_pkg_ctx +(caller)[0],
          $_[0],
          map { is_utf8($_) ? encode_utf8 $_ : $_ } (
               (split(/::/, (caller(1))[3]//':: '))[-1] . ':' . (caller(0))[2] . ": " . $_[1],
               (@_ > 2 ? @_[2..$#_] : ())
          );
    };
}

# catch all non-our Perl's warns to log with stack trace
# we can't just Carp::Always or Devel::Confess due to AnyEvent::Log 'warn' :(
sub install_AE_log_SIG_WARN {
    $SIG{__WARN__} = sub {
        scalar( grep /AnyEvent|\blog/, map { (caller($_))[0..3] } (1..3) )
            ? warn $_[0]
            : AE::log warn => &Carp::longmess;
    };
}

sub install_AE_log_SIG_DIE {
    $SIG{__DIE__} = sub {
        my $mess = &Carp::longmess;
        $mess =~ s/( at .*?\n)\1/$1/s;    # Suppress duplicate tracebacks
        AE::log alert => $mess;
        die $mess;
    };
}

sub get_AE_log_format_cb {
    return sub {
        my ($time, $ctx, $lvl, $msg) = @_;

        my $ts = POSIX::strftime("%H:%M:%S", localtime $time)
               . sprintf ".%04d", 1e4 * ($time - int($time));

        # XXX we need just timestamp! but AE has no cb for just time..
        # XXX so copypaste rest from AnyEvent::Log
        my $ct = " ";
        my @res;

        for (split /\n/, sprintf "%-5s %s: %s", $AnyEvent::Log::LEVEL2STR[$_[2]], $_[1][0], $_[3]) {
            push @res, "$ts$ct$_\n";
            $ct = " + ";
        }

        join "", @res
    };
}

# adapted from Hash::Util to process arrays
sub unlock_hashref_recurse {
    my $hash = shift;

    my $htype = reftype $hash;
    return unless defined $htype;
    if ($htype eq 'ARRAY') {
        foreach my $el (@$hash) {
            unlock_hashref_recurse($el)
                if defined reftype $el;
        }
        return;
    }

    foreach my $value (values %$hash) {
        my $type = reftype($value);
        if (defined($type) and ($type eq 'HASH' or $type eq 'ARRAY')) {
            unlock_hashref_recurse($value);
        }
        Internals::SvREADONLY($value,0);
    }
    Hash::Util::unlock_ref_keys($hash);
    return $hash;
}

1;
