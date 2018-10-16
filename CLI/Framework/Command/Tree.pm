package CLI::Framework::Command::Tree;
use base qw( CLI::Framework::Command::Meta );

use strict;
use warnings;

our $VERSION = 0.01;

#-------

sub usage_text {
    q{
    tree: tree view of the names of only those commands that are currently registered in the application
    }
}

sub run {
    my ($self, $opts, @args) = @_;
    
    my $app = $self->get_app(); # metacommand is app-aware

    my $tree = command_tree( $app );
    $tree =~ s/^/\t/gm;
    return $tree;
}

#-------

sub command_tree {
    my ($app, $root, $indent, $tree) = @_;

    $root   ||= $app;
    $indent ||= 0;

    # (output object)
    $tree = { text => '' } unless ref $tree;

    $indent += 4 if( $root->isa( 'CLI::Framework::Command' ) );

    # For every command registered into the root object (either a CLIF
    # Application or a CLIF Command), append its tree representation to the
    # output object...

    # Use proper accessors for object type...
    my $registered_command_names_accessor = 'registered_command_names';
    my $registered_command_obj_accessor = 'registered_command_object';
    if( $root->isa('CLI::Framework::Command') ) {
        $registered_command_names_accessor = 'registered_subcommand_names';
        $registered_command_obj_accessor = 'registered_subcommand_object';
    }
    my @command_names;
    {   no strict 'refs';
        @command_names = $root->$registered_command_names_accessor;
    }
    for my $command_name (@command_names) {
#XXX-ALTERNATIVE: show a tree of command names
#        $tree->{text} .= ' 'x$indent . $command_name . "\n";

        my $command_obj;
        {   no strict 'refs';
            $command_obj = $root->$registered_command_obj_accessor( $command_name );
        }

#XXX-ALTERNATIVE: show a tree of Perl package names defining the commands (including
#   source files they were defined in):
my $source = Class::Inspector->loaded_filename( ref $command_obj );
$source ||= 'defined inline';
my $x = ref ($command_obj) . " ($source)";
$tree->{text} .= ' 'x$indent . $x . "\n";

        # Recursive call (NOTE: passing output object reference which will act
        # as an accumulator)...
        command_tree( $app, $command_obj, $indent, $tree );
    }
    return $tree->{text} . "\n";
}

#-------
1;

__END__

=pod

=head1 NAME

CLI::Framework::Command::Tree - CLIF built-in command to display a tree
representation of the commands that are currently registered with the running
application

=head1 SEE ALSO

L<CLI::Framework::Command>

=cut
