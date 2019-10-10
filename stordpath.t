#!/usr/bin/env perl

use Modern::Perl '2014';
use Teleperl::Storage;
use Data::DPath qw(dpath dpathr);
use Storable qw(retrieve);

use Test::Simple tests => 7;

use Data::Dumper;
$Data::Dumper::Indent = 1;
use Scalar::Util qw(reftype refaddr);

our $self = {
    session     => retrieve('../session.dat'),
    auth        => {},
    test        => {
        a_scalar    => 'a string',
        an_array    => [ 'zero', 'one', 'two' ],
    },
};
bless $self, 'Teleperl::Storage'; $self->_migrate2019fall();

$Data::Dumper::Varname = 'start'; say Dumper $self;
delete $self->{cache}->{users};

my ($filter, $orig, @ret, $ret, $parameter);

$parameter = '/an_array/*[2]';
$filter = dpath($parameter);
@ret = $filter->match($self->{test});
$Data::Dumper::Varname = 'ret';
say "ret=@ret ".Dumper(@ret);
$ret = (@ret)[0];

ok( $ret eq 'two', 'one value' )
    or say $ret;

$parameter = '/an_array';
$filter = dpath($parameter);
@ret = $filter->match($self->{test});
$Data::Dumper::Varname = 't2ret';
say "ret2=@ret ".Dumper(@ret);
$ret = (@ret)[0];

ok( reftype $ret eq 'ARRAY', 'one array ref' )
    or say reftype $ret;

$parameter = '/dc/2/permkey';
say 'refaddr(permkey)='.refaddr($self->{auth}{dc}{2}{permkey}). ' reftype(permkey)='.reftype($self->{auth}{dc}{2}{permkey});
$filter = dpath($parameter);
@ret = $filter->match($self->{auth});
$Data::Dumper::Varname = 'tr3ret';
say "ret3=@ret ".Dumper(@ret);
$ret = (@ret)[0];
$ret->{salt} = 'abyrvalg';
say 'refaddr($ret)='.refaddr($ret). ' reftype($ret)='.reftype($ret);
$Data::Dumper::Varname = 't3after'; say Dumper $self->{auth};

ok( $self->{auth}{dc}{2}{permkey}->{salt} eq 'abyrvalg', 'change salt' )
    or say Dumper $self->{auth};

$parameter = '/an_array/*[2]';
$filter = dpath($parameter);
@ret = $filter->match($self->{test});
$Data::Dumper::Varname = 'ret';
say "ret=@ret ".Dumper(@ret);
$ret = (@ret)[0];
$ret = "whooy";

ok( $self->{test}{an_array}->[2] eq 'whooy', 'non-ref change one value' )
    or say Dumper $self->{test};

$parameter = '/an_array/*[2]';
$filter = dpathr($parameter);
@ret = $filter->match($self->{test});
$Data::Dumper::Varname = 'ret';
say "ret=@ret ".Dumper(@ret);
$ret = (@ret)[0];
$$ret = "whooy";

ok( $self->{test}{an_array}->[2] eq 'whooy', 'ref change one value' )
    ;say Dumper $self->{test};

$parameter = '/sessions/2/*/id[value eq "nonexist"]/..';
$filter = dpath($parameter);
@ret = $filter->match($self->{session});
$Data::Dumper::Varname = 'sess';
say "ret=@ret ".Dumper(@ret);
$ret = (@ret)[0];
say 'refaddr($ret)='.refaddr($ret). ' reftype($ret)='.reftype($ret);

ok( $ret->{time} == 123, 'grep session by literal id' )
    or say Dumper $self->{session};

$Data::Dumper::Varname = 'IN_FILTER';
#$parameter = '/sessions/2/*/id[value ne "nonexist" && print(Dumper($p))]/..';
$parameter = '/sessions/2/*/id[value eq ${$p->parent->parent->parent->parent->ref}->{main_session_id} ]/..';
$filter = dpath($parameter);
@ret = $filter->match($self->{session});
$Data::Dumper::Varname = 'sess';
say "ret=@ret ".Dumper(@ret);
$ret = (@ret)[0];
say 'refaddr($ret)='.refaddr($ret). ' reftype($ret)='.reftype($ret);

ok( $ret->{time} == 1570499041, 'grep session by main id HACK' )
    or say Dumper $self->{session};

