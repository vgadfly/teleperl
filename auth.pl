use Modern::Perl;

use Teleperl;
use Teleperl::Storage;

use EV;
use AnyEvent;
use Carp;
use Data::Dumper;

$SIG{__DIE__} = sub {
    say Carp::confess;
    die;
};

my $phone = shift or die "phone required";

my $auth = 0;
my $cv = AE::cv;
my $storage = Teleperl::Storage->new(dir => $phone);
my $t = Teleperl->new( force_new_session => 1, storage => $storage );

$t->reg_cb( error => sub { $cv->send } );
$t->reg_cb( auth => sub {

    # only run once
    return if $auth == 1;
    $auth = 1;

    my %param = $storage->tg_param;

    $t->auth( phone => $phone, cb => sub {

            my %res = @_;

            if (defined $res{sent}) {
                say 'phone '.($res{registered} ? '' : 'un').'registered';
                say 'Code sent, type: '.$res{sent};
                say 'enter code';
                chomp( my $pc = <> );
                $t->auth( code => $pc, cb => sub {
                        my %res = @_;

                        if (defined $res{auth}) {
                            say "Auth successfull, uid: $res{auth}";
                            $storage->save;
                        }
                        elsif (defined $res{error}) {
                            say "Auth error: $res{error}";
                        }

                        $cv->send;
                    });
            }
            elsif (defined $res{error}) {
                say "Error $res{error}";
                $cv->send;
            }

        } );

});

$t->start;
$cv->recv;

