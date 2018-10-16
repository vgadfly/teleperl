package CLI::Framework::Command::Dump;
use base qw( CLI::Framework::Command::Meta );

use strict;
use warnings;

use Data::Dumper;

our $VERSION = 0.01;

#-------

sub usage_text {
    q{
    dump: print a dump of the application object using Data::Dumper
    }
}

sub run {
    my ($self, $opts, @args) = @_;

    my $result = Dumper($self->get_app()) . "\n";
    return $result;
}

#-------
1;

__END__

=pod

=head1 NAME

CLI::Framework::Command::Dump - CLIF built-in command to show the internal
state of a running application

=head1 SEE ALSO

L<CLI::Framework::Command>

=cut
