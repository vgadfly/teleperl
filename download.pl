use Modern::Perl;

use AnyEvent;
use Config::Tiny;
use Storable qw( store retrieve freeze thaw dclone );

use Telegram;
use Telegram::Help::GetConfig;
use Telegram::InputFileLocation;
use Telegram::Upload::GetFile;
use Telegram::Auth::ExportAuthorization;
use Telegram::Auth::ImportAuthorization;

use Crypt::OpenSSL::Random;

use Data::Dumper;

my ($type, $dc, $vol, $id, $secret) = @ARGV;
my $filename = $type eq 'f' ? "$dc-$vol-$id" : "$dc-$vol";

if ($type eq 'd') {
    $secret = $id;
    $id = $vol;
}
my $partsize = 2 ** 19;

my $old = retrieve('session.dat');
my $config = Config::Tiny->read('teleperl.conf');

my $home = Telegram->new(
    dc => $config->{dc},
    app => $config->{app},
    proxy => $config->{proxy},
    session => $old,
    reconnect => 1,
    keepalive => 1,
    noupdate => 1
);

my $dc_pool = {};
my $cv = AE::cv;

$home->start;

$home->invoke(
    Telegram::Help::GetConfig->new,
    sub {
        die unless $_[0]->isa('Telegram::Config');
        my $dcs = $_[0];
        for my $opt (@{$dcs->{dc_options}}) {
            my $type = $opt->{static} ? 'static' : 'dynamic';
            $dc_pool->{$opt->{id}}{$type} = [] 
                unless exists $dc_pool->{$opt->{id}}{$type};
            push @{$dc_pool->{$opt->{id}}{$type}}, $opt;
        }
        $cv->send;
    }
);

$cv->recv;
$cv = AE::cv;
open my $file, ">$filename";
binmode $file;

sub load_part
{
    my ($roam, $part, $cb) = @_;
    
    my $loc = ($type eq "f") ? 
        Telegram::InputFileLocation->new(
            volume_id => $vol,
            local_id => $id,
            secret => $secret
        )
        :
        Telegram::InputDocumentFileLocation->new(
            id => $id,
            access_hash => $secret,
            version => 0 # XXX
        );
    say Dumper $loc;
    $roam->invoke(
        Telegram::Upload::GetFile->new(
            location => $loc,
            offset => $part * $partsize,
            limit => $partsize
        ),
        sub {
            if ($_[0]->isa('MTProto::RpcError')) {
                die Dumper @_;
            }
            print $file $_[0]->{bytes};
            if (length($_[0]->{bytes}) == $partsize) {
                return load_part( $roam, $part+1, $cb );
            }
            else {
                return $cb->();
            }
        }
    );
}

$home->invoke(
    Telegram::Auth::ExportAuthorization->new( dc_id => $dc ),
    sub {
        my $eauth = $_[0];
        say Dumper $eauth;
        my $roam;
        if ($eauth->isa('MTProto::RpcError')) {
            my $new = dclone $old;
            # XXX
            $new->{mtproto}{session_id} = Crypt::OpenSSL::Random::random_pseudo_bytes(8);
            $new->{mtproto}{seq} = 0;
            $roam = Telegram->new(
                dc => $config->{dc},
                app => $config->{app},
                proxy => $config->{proxy},
                session => $new,
                reconnect => 1,
                keepalive => 1,
                noupdate => 1
            );
            $roam->start;
            load_part($roam, 0, sub { $cv->send });
        }
        if ($eauth->isa('Telegram::Auth::ExportedAuthorization')) {
            my $dca = { 
                addr => $dc_pool->{$dc}{static}[0]{ip_address},
                port => $dc_pool->{$dc}{static}[0]{port},
            };
            say "DC $dc: $dca->{addr}:$dca->{port}";
            $roam = Telegram->new(
                dc => $dca,
                app => $config->{app},
                proxy => $config->{proxy},
                session => {},
                reconnect => 1,
                keepalive => 1,
                noupdate => 1
            );
            $roam->start;
            $roam->invoke(
                Telegram::Auth::ImportAuthorization->new(
                    id => $eauth->{id},
                    bytes => $eauth->{bytes}
                ),
                sub {
                    load_part($roam, 0, sub { $cv->send });
                }
            );
        }
    }
);

$cv->recv;

