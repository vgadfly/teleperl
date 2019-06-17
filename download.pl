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

my ($dc, $vol, $id, $secret) = @ARGV;

my $old = retrieve('session.dat');
my $config = Config::Tiny->read('teleperl.conf');

my $home = Telegram->new(
    dc => $config->{dc},
    app => $config->{app},
    proxy => $config->{proxy},
    session => $old,
    reconnect => 1,
    keepalive => 1,
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

$home->invoke(
    Telegram::Auth::ExportAuthorization->new( dc_id => $dc ),
    sub {
        my $eauth = $_[0];
        say Dumper $eauth;
        if ($eauth->isa('MTProto::RpcError')) {
            my $new = dclone $old;
            # XXX
            $new->{mtproto}{session_id} = Crypt::OpenSSL::Random::random_pseudo_bytes(8);
            $new->{mtproto}{seq} = 0;
            my $roam = Telegram->new(
                dc => $config->{dc},
                app => $config->{app},
                proxy => $config->{proxy},
                session => $new,
                reconnect => 1,
                keepalive => 1,
            );
            $roam->start;
            
                    my $fl = Telegram::InputFileLocation->new(
                        volume_id => $vol,
                        local_id => $id,
                        secret => $secret
                    );

                    $roam->invoke(
                        Telegram::Upload::GetFile->new(
                            location => $fl,
                            offset => 0,
                            limit => 4096
                        ),
                        sub {
                            say Dumper @_;
                            #$cv->send;
                        }
                    );
        }
        if ($eauth->isa('Telegram::Auth::ExportedAuthorization')) {
            my $dca = { 
                addr => $dc_pool->{$dc}{static}[0]{ip_address},
                port => $dc_pool->{$dc}{static}[0]{port},
            };
            say "DC $dc: $dca->{addr}:$dca->{port}";
            my $roam = Telegram->new(
                dc => $dca,
                app => $config->{app},
                proxy => $config->{proxy},
                session => {},
                reconnect => 1,
                keepalive => 1,
            );
            $roam->start;
            
            $roam->invoke(
                Telegram::Auth::ImportAuthorization->new( 
                    id => $eauth->{id},
                    bytes => $eauth->{bytes}
                ),
                sub {
                    say Dumper @_;
                    my $fl = Telegram::InputFileLocation->new(
                        volume_id => $vol,
                        local_id => $id,
                        secret => $secret
                    );

                    $roam->invoke(
                        Telegram::Upload::GetFile->new(
                            location => $fl,
                            offset => 0,
                            limit => 4096
                        ),
                        sub {
                            say Dumper @_;
                            #$cv->send;
                        }
                    );
                }
            );
        }
    }
);

$cv->recv;

