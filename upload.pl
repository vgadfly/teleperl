use Modern::Perl;

use AnyEvent;
use Config::Tiny;
use Storable qw( store retrieve freeze thaw dclone );

use Telegram;
use Telegram::Help::GetConfig;
use Telegram::InputFileLocation;
use Telegram::Upload::GetFile;
use Telegram::Upload::SaveFilePart;
use Telegram::Messages::SendMedia;
use Telegram::InputFile;
use Telegram::InputPeer;
use Telegram::InputMedia;
use Telegram::Auth::ExportAuthorization;
use Telegram::Auth::ImportAuthorization;
use Telegram::DocumentAttribute;

use Crypt::OpenSSL::Random;
use Digest::MD5 qw(md5);

use Data::Dumper;

my ($chan, $filename, $filesize) = @ARGV;

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
    noupdate => 1
);
$roam->start;

my $data;
open my $file, $filename;
read $file, $data, $filesize;
close $file;

my $file_id = rand(2**31);

$roam->invoke(
    Telegram::Upload::SaveFilePart->new(
        file_id => $file_id,
        file_part => 0,
        bytes => $data
    ),
    sub {
        say Dumper @_;
        unless ($_[0]->isa('MTProto::RpcError')) {
            my $peer = $home->peer_from_id($chan);
            my $media = Telegram::InputMediaUploadedDocument->new(
                file => Telegram::InputFile->new(
                    id => $file_id,
                    parts => 1,
                    name => $filename,
                    md5_checksum => md5($data)
                ),
                mime_type => 'application/octet-stream',
                attributes => [
                    Telegram::DocumentAttributeFilename->new(
                        file_name => $filename
                    )
                ]
            );

            $home->invoke(
                Telegram::Messages::SendMedia->new(
                    peer => $peer,
                    media => $media,
                    random_id => rand(2**31),
                    message => ''
                ),
                sub {
                    say Dumper @_;
                    $cv->send;
                }
            );
        }
    }

);

$cv->recv;

