use Modern::Perl;

use AnyEvent;
use Config::Tiny;
use Storable qw( store retrieve freeze thaw dclone );

use Telegram;
use Telegram::Help::GetConfig;
use Telegram::InputFileLocation;
use Telegram::Upload::GetFile;
use Telegram::Upload::SaveFilePart;
use Telegram::Upload::SaveBigFilePart;
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

$filesize = -s $filename unless defined $filesize;
die unless $filesize;

my $psize = 2 ** 19;
my $total_parts = int( ($filesize + $psize - 1) / $psize );
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
open( my $file, $filename );
my $md = Digest::MD5->new;
my $file_id = rand(2**31);

sub save_part
{
    my ($part, $cb) = @_;
    
    my $sizeleft = $filesize - $part * $psize;
    my $size = $sizeleft < $psize ? $sizeleft : $psize;

    if ($sizeleft <= 0) {
        return $cb->($part);
    }
    
    read $file, $data, $size;
    $md->add($data);

    my $q = ($filesize < 10 * 2 ** 20) ? 
        Telegram::Upload::SaveFilePart->new(
            file_id => $file_id,
            file_part => $part,
            bytes => $data
        ) 
        : 
        Telegram::Upload::SaveBigFilePart->new(
            file_id => $file_id,
            file_part => $part,
            file_total_parts => $total_parts,
            bytes => $data
        );
    $roam->invoke( $q,
        sub {
            #say Dumper @_;
            unless ($_[0]->isa('MTProto::RpcError')) {
                say "part $part/$total_parts success";
                return save_part( $part+1, $cb );
            }
            else {
                say "failed on part $part";
                $q->{bytes} = undef;
                say Dumper @_, $q;
                $cv->send;
            }
        }
    );
}

save_part( 0, 
    sub {
        my $parts = $_[0];
        my $peer = $home->peer_from_id($chan);
        my $f = ($filesize < 10 * 2 ** 20) ?
            Telegram::InputFile->new(
                id => $file_id,
                parts => $parts,
                name => $filename,
                md5_checksum => $md->digest
            )
            :
            Telegram::InputFileBig->new(
                id => $file_id,
                parts => $parts,
                name => $filename,
            );

        my $media = Telegram::InputMediaUploadedDocument->new(
            file => $f,
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
);
            
$cv->recv;

