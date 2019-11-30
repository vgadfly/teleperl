#!/usr/bin/env perl5

use strict;
use warnings;

use Data::Dumper;
use File::Basename;
use File::Path qw( make_path );
use TL;

my %builtin = map {$_ => undef} 
qw( string bytes int nat long int128 int256 double Bool true date Object vector Vector );

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

my $prefix = shift @ARGV;
my $srcfile = $ARGV[0];

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

sub pkgname($$)
{
    my $prefix = shift;
    my @chunks = map { join '', map {ucfirst} split /_/ } split /\./, shift;
    
    unshift @chunks, $prefix if $prefix;
    my $path = join('/', @chunks).'.pm';
    my $pkg = join('::', @chunks);
    if ( wantarray ) {
        return ($path, $pkg);
    }
    return $pkg;
}

# class generator

# Vector templates
sub _tmpl2vec($) {
    my $arg = shift;

    if ($arg->{type}{name} =~ '^([Vv])ector$' and exists $arg->{type}{t_args}) {
        $arg->{type}{name} = $arg->{type}{t_args}[0];
        $arg->{type}{vector} = $1;
        delete $arg->{type}{template};
        delete $arg->{type}{t_args};
    }
}

for my $type (@{$parser->YYData->{types}}) {
    # skip Vector definition
    next if $type->{type}{name} =~ '^[Vv]ector$';
    
    for my $arg (@{$type->{args}}) {
        _tmpl2vec $arg;
    }
}
for my $type (@{$parser->YYData->{funcs}}) {
    $type->{func} = 1;
    for my $arg (@{$type->{args}}) {
        _tmpl2vec $arg;
    }
    _tmpl2vec $type;    # return type of function also may be Vector
}

my @types = grep {!exists $builtin{$_->{type}{name}} } @{$parser->YYData->{types}};
#my @funcs = grep {!exists $builtin{$_->{type}{name}} } @{$parser->YYData->{funcs}};
my @funcs = @{$parser->YYData->{funcs}};

my %typeset;
for my $type (@types) {
    my ($path, $pkg) = pkgname($prefix, $type->{id});
    $typeset{$pkg} = undef;
}

push @types, @funcs;
for my $type (@types) {
    my ($path, $pkg) = pkgname($prefix, $type->{id});
    my ($basepath, $basepkg) = pkgname($prefix, $type->{type}{name});
    $basepkg .= 'ABC'; # Abstract Base Class
    my $hash = $type->{hash}; # crc
    $hash =~ s/^\#//;
    $path = $basepath unless $type->{func};
    
    print "Generating $pkg in $path\n";
    make_path(dirname($path)); 
    open my $f, ">>$path" or die "$!";

    unless ($type->{func}) {
        unless (exists $typeset{$basepkg}) {
            print $f "package $basepkg;\nour \$VERSION='$srcfile';\n\n";
            $typeset{$basepkg} = undef;
        }
    }
    print $f "package $pkg;\nuse base 'TL::Object';\n\n";

    unless ($type->{func}) {
        print $f 'push @ISA, \''.$basepkg."';\n" 
            unless $basepkg eq $pkg;
        print $f "our \$parent = '$basepkg';\n";
    }
    print $f "our \$hash = 0x$hash;\n\n";

    my %argtypes = map { scalar pkgname($prefix, $_) => undef } 
        grep { !exists $builtin{$_} } 
        map { $_->{type}{name} } 
        @{$type->{args}};

    my @params = map { $_->{name} } @{$type->{args}};

    #print $f "# used types\n";
    #print $f "use $_;\n" for keys %argtypes;

    print $f "use fields qw( ". join( " ", @params )." );\n";
    print $f "\nour %TYPES = (\n";
    for my $arg (@{$type->{args}}) {
        printf $f "  %-17s => { type => ", $arg->{name};
        if (exists $builtin{$arg->{type}{name}}) {
            print $f "'" . $arg->{type}{name} . "', builtin => 1, ";
        } elsif ($arg->{type}{bang}) {
            print $f "'" . $arg->{type}{name} . "', ";
        } else {
            my (undef, $basepkg) = pkgname($prefix, $arg->{type}{name});
            print $f "'$basepkg', ";
        }
        print $f "vector => 1, " if exists $arg->{type}{vector};
        print $f "bang => 1, " if exists $arg->{type}{bang};
        print $f "optional => '$arg->{cond}{name}.".int(log( $arg->{cond}{bitmask})/log(2))."', "
            if $arg->{cond};
        print $f "},\n";
    }
    print $f ");\n";

    print $f "\n# subs\n";

    print $f "sub new\n{\n  my \$class = shift;\n";
    print $f "  my \$self = fields::new( ref \$class || \$class );\n";
    print $f "  \$self->SUPER::new(\@_);\n}\n\n";

    print $f "sub pack\n{\n";
    print $f "  my \$self = shift;\n";
    print $f "  my \@stream;\n";
    print $f "  \$self->validate if \$TL::Object::VALIDATE & 1;\n";
    print $f "  local \$_;\n";

    print $f "  push \@stream, pack( 'L<', \$hash );\n";

    # flags
    for my $arg (@{$type->{args}}) {
        print "$pkg: anonymous parameter of type $arg->{type}{name}!\n" unless exists $arg->{name} and defined $arg->{name};
        if ( $arg->{type}{name} eq 'nat' ) {
            print $f "  \$self->{$arg->{name}} = 0 unless defined \$self->{$arg->{name}};\n";
        }
        if ( $arg->{cond} ) {
            print $f "  \$self->{$arg->{cond}{name}} |= $arg->{cond}{bitmask} if defined \$self->{$arg->{name}};\n";
        }
    }

    for my $arg (@{$type->{args}}) {
        print "$pkg: anonymous parameter of type $arg->{type}{name}!\n" unless exists $arg->{name} and defined $arg->{name};
        if ( $arg->{cond} ) {
            print $f "  if ( \$self->{$arg->{cond}{name}} & $arg->{cond}{bitmask} ) {\n";
        }
        if (exists $arg->{type}{vector}) {
            print $f "  push \@stream, pack('L<', 0x1cb5c415);\n" if $arg->{type}{vector} eq 'V';
            print $f "  push \@stream, pack('L<', scalar \@{\$self->{$arg->{name}}});\n";
            if (exists $builtin{$arg->{type}{name}} and $arg->{type}{name} ne 'Object') {
                print $f "  push \@stream, TL::Object::pack_$arg->{type}{name}( \$_ ) for \@{\$self->{$arg->{name}}};\n"
            }
            elsif ($arg->{type}{name} =~ /^[a-z]/) { # XXX see below in unpack
                my @bares = grep { $_->{id} eq $arg->{type}{name} } @types;
                die "bare count for $arg->{type}{name} is not 1" unless @bares == 1;
                my (undef, $pkg) = pkgname($prefix, $bares[0]->{id});
                print $f "  BEGIN { require $pkg; }\n";
                print $f "  push \@stream, $pkg\->pack() for \@{\$self->{$arg->{name}}};\n";
            }
            else {
                print $f "  push \@stream, \$_->pack() for \@{\$self->{$arg->{name}}};\n"
            }
        }
        else {
            if (exists $builtin{$arg->{type}{name}} and $arg->{type}{name} ne 'Object') {
                print $f "  push \@stream, TL::Object::pack_$arg->{type}{name}( \$self->{$arg->{name}} );\n"
            }
            else {
                print $f "  push \@stream, \$self->{$arg->{name}}->pack();\n"; 
            }
        }
        if ( $arg->{cond} ) {
            print $f "  }\n";
        }
    }
    print $f "  return \@stream;\n";
    print $f "}\n\n";

    print $f "sub unpack\n{\n";
    print $f "  my (\$class, \$stream) = \@_;\n";
    print $f "  local \$_;\n";
    print $f "  my \@_v;\n";
    print $f "  my \$self = fields::new(\$class);\n";

    for my $arg (@{$type->{args}}) {
        if ( $arg->{cond} ) {
            print $f "  if ( \$self->{$arg->{cond}{name}} & $arg->{cond}{bitmask} ) {\n";
        }
        # XXX: TMP DEBUG
        #print $f "  print \"unpacking $arg->{name}\\n\";\n";
        if (exists $arg->{type}{vector}) {
            # as this is definitely synchronization loss earlier, check
            # regardless of validation setting - connection should be aborted
            print $f "  shift \@\$stream eq qq'\\x15\\xc4\\xb5\\x1c' or die 'expected Vector';\n"
                if $arg->{type}{vector} eq 'V';
            print $f "  \$_ = unpack 'L<', shift \@\$stream;\n";
            # XXX: TMP DBG
            #print $f "  print \"  vector of size \$_\\n\";\n";
            print $f "  \@_v = ();\n";
            if (exists $builtin{$arg->{type}{name}} and $arg->{type}{name} ne 'Object') {
                print $f "  push \@_v, TL::Object::unpack_$arg->{type}{name}( \$stream ) while (\$_--);\n";
            }
            elsif ($arg->{type}{name} =~ /^[a-z]/) {
                # XXX docs: Bare type is a type whose values do not contain a
                # constructor number, which is implied instead. A bare type
                # identifier always coincides with the name of the implied
                # constructor (and therefore, begins with a lowercase letter)
                my @bares = grep { $_->{id} eq $arg->{type}{name} } @types;
                die "bare count for $arg->{type}{name} is not 1" unless @bares == 1;
                my (undef, $pkg) = pkgname($prefix, $bares[0]->{id});
                print $f " BEGIN { require $pkg; }\n";
                print $f "  push \@_v, $pkg\->unpack( \$stream ) while \$_--;\n";
            }
            else {
                print $f "  push \@_v, TL::Object::unpack_obj( \$stream ) while (\$_--); # $arg->{type}{name}\n";
            }
            print $f "  \$self->{$arg->{name}} = [ \@_v ];\n";
        }
        else {
            if (exists $builtin{$arg->{type}{name}} and $arg->{type}{name} ne 'Object') {
                print $f "  \$self->{$arg->{name}} = TL::Object::unpack_$arg->{type}{name}( \$stream );\n";
            }
            else {
                print $f "  \$self->{$arg->{name}} = TL::Object::unpack_obj( \$stream ); # $arg->{type}{name}\n";
            }
        }
        if ( $arg->{cond} ) {
            print $f "  }\n";
        }
    }
    print $f "  \$self->validate if \$TL::Object::VALIDATE & 2;\n";
    print $f "  return \$self;\n}\n\n";
    
    print $f "\n1;\n";
    close $f;
}

open my $f, ">$prefix/ObjTable.pm" or die "$!";

print $f "package ".$prefix."::ObjTable;\nour \$GENERATED_FROM='$srcfile';\nour %tl_type = (\n";
for my $type (@types) {
    my ($path, $pkg) = pkgname($prefix, $type->{id});
    my ($basepath, $basepkg) = pkgname($prefix, $type->{type}{name});
    my $hash = $type->{hash}; # crc
    $hash =~ s/^\#//;
    $path = $basepath unless $type->{func};
    print $f "  0x$hash => { file => '$path', class => '$pkg',";
    if ($type->{func}) {
        print $f " func => '$type->{id}',";
        my @bang = grep { $_->{type}{bang} } @{$type->{args}};
        if (@bang) {
            print $f " bang => '$bang[0]->{name}',";
        } else {
            print $f " returns => ";
            if (exists $builtin{$type->{type}{name}}) {
                print $f "'" . $type->{type}{name} . "',";
            } else {
                print $f "'$basepkg',";
            }
        }
        print $f " vector => 1," if $type->{type}{vector};
    }
    print $f " },\n";
}
print $f ");\n1;\n";
close $f;
