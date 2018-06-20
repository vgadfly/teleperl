#!/usr/bin/env perl5

use strict;
use warnings;

use Data::Dumper;
use TL;

my %builtin = map {$_ => undef} 
qw( string bytes int long int128 int256 double Bool true date );

sub _lex 
{
    my $input = $_[0]->YYData->{DATA};
    # print " lexer:". substr($$input, pos($$input)). "\n";
   
    # EOF
    return ('', undef) if pos($$input) >= length($$input);

    # Skip blanks
    $$input =~ m{\G((?:
                \s+
            |   //[^\n]*
            |   /\*.*?\*/
            )+)}xsgc and do {
        # blank handling here
        # ...
        return ('', undef) if pos($$input) >= length($$input);
    };

    $$input =~ /\G(---functions---)/gc and return ('FUNCTIONS', $1); 
    $$input =~ /\G(---types---)/gc and return ('TYPES', $1); 
    $$input =~ /\G([a-z][a-zA-Z0-9_]*)/gc and return ('LC_ID', $1); 
    $$input =~ /\G([A-Z][a-zA-Z0-9_]*)/gc and return ('UC_ID', $1);
    $$input =~ /\G(\d+)/gc and return ('NUM', $1);
    $$input =~ /\G(\#[0-9a-fA-F]{1,8})/gc and return ('ID_HASH', $1);

    $$input =~ /\G(.)/gc or die "Match (.) failed"; 
    return ($1, $1);
}

my $parser = TL->new;

$parser->YYData->{types} = [];
$parser->YYData->{funcs} = [];

my $input;
{
    local $/ = undef;
    $input = <>;
}
pos($input) = 0;
$parser->YYData->{DATA} = \$input; 
$parser->YYParse( 
    #yydebug => 0x1f, 
    yylex => \&_lex, yyerror => sub {
        print "Unexpected ".$_[0]->YYCurtok.", expecting one of:".join(',', $_[0]->YYExpect)."\n";
    } ) or die;

# class generator

# Vector templates
for my $type (@{$parser->YYData->{types}}) {
    for my $arg (@{$type->{args}}) {
        if ($arg->{type}{name} =~ '^[Vv]ector$' and exists $arg->{type}{t_args}) {
            $arg->{type}{name} = $arg->{type}{t_args}[0];
            $arg->{type}{vector} = 1;
            delete $arg->{type}{template};
            delete $arg->{type}{t_args};
        }
    }
}

my @types = grep {!exists $builtin{$_->{type}{name}} } @{$parser->YYData->{types}};
my @funcs = grep {!exists $builtin{$_->{type}{name}} } @{$parser->YYData->{funcs}};

print Dumper(\@types);

push @types, @funcs;
for my $type (@types) {
    my $constr = ucfirst $type->{id};
    my $hash = $type->{hash}; # crc
    $hash =~ s/^\#//;

    open my $f, ">auto/$constr.pm" or die "$!";
    print $f "package $constr;\nuse base TLObject;\n\n";

    print $f "our \$parent = '$type->{type}{name}';\n";
    print $f "our \$hash = 0x$hash;\n\n";

    my %argtypes = map { ucfirst($_) => undef } 
        grep { !exists $builtin{$_} } 
        map { $_->{type}{name}} 
        @{$type->{args}};

    print $f "# used types\n";
    print $f "use $_;\n" for keys %argtypes;
    print $f "\n# subs\n";

    print $f "sub new\n{\nreturn bless {};\n}\n\n";

    print $f "sub pack\n{\n";
    print $f "  my \$self = shift;\n";
    print $f "  my \@stream;\n";
    print $f "  local \$_;\n";

    print $f "  push \@stream, pack( 'L<', \$hash );\n";
    for my $arg (@{$type->{args}}) {
        if (exists $arg->{type}{vector}) {
            print $f "  push \@stream, pack('L<', 0x1cb5c415);\n";
            print $f "  push \@stream, pack('L<', scalar \@{\$self->{$arg->{name}}});\n";
            if (exists $builtin{$arg->{type}{name}}) {
                print $f "  push \@stream, \$self->SUPER::pack_$arg->{type}{name}( \$_ ) for \@{\$self->{$arg->{name}}};\n"
            }
            else {
                print $f "  push \@stream, \$_->pack() for \@{\$self->{$arg->{name}}};\n"
            }
        }
        else {
            if (exists $builtin{$arg->{type}{name}}) {
                print $f "  push \@stream, \$self->SUPER::pack_$arg->{type}{name}( \$self->{$arg->{name}} );\n"
            }
            else {
                print $f "  push \@stream, \$self->{$arg->{name}}->pack();\n"; 
            }
        }
    }
    print $f "  return \@stream;\n";
    print $f "}\n\n";

    print $f "sub unpack\n{\n";
    print $f "  my (\$class, \$stream) = \@_;\n";
    print $f "  local \$_;\n";
    print $f "  my \@_v;\n";
    print $f "  my \$self = bless {};\n";

    for my $arg (@{$type->{args}}) {
        if (exists $arg->{type}{vector}) {
            print $f "  shift \@\$stream; #0x1cb5c415\n";
            print $f "  \$_ = unpack 'L<', shift \@\$stream;\n";
            print $f "  \@_v = ();\n";
            if (exists $builtin{$arg->{type}{name}}) {
                print $f "  push \@_v, \$self->SUPER::unpack_$arg->{type}{name}( \$stream ) while (\$_--);\n";
            }
            else {
                print $f "  push \@_v, \$self->SUPER::unpack_obj( \$stream ) while (\$_--); # $arg->{type}{name}\n";
            }
            print $f "  \$self->{$arg->{name}} = [ \@_v ];\n";
        }
        else {
            if (exists $builtin{$arg->{type}{name}}) {
                print $f "  \$self->{$arg->{name}} = \$self->SUPER::unpack_$arg->{type}{name}( \$stream );\n";
            }
            else {
                print $f "  \$self->{$arg->{name}} = \$self->SUPER::unpack_obj( \$stream ); # $arg->{type}{name}\n";
            }
        }
    }
    print $f "return \$self;\n}\n\n";
    
    print $f "\n1;\n";
    close $f;
}

open my $f, ">TLTable.pm" or die "$!";

print $f "package TLTable;\nour %tl_type = (\n";
for my $type (@types) {
    my $constr = ucfirst $type->{id};
    my $hash = $type->{hash}; # crc
    $hash =~ s/^\#//;
    print $f "  0x$hash => '$constr',\n";
}
print $f ");\n1;\n";
close $f;
