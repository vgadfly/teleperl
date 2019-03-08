# teleperl
Pure perl mtproto/telergam client

## DEPENDS
- Modern::Perl
- Config::Tiny
- AnyEvent
- Net::SOCKS
- Crypt::OpenSSL::Bignum
- Crypt::OpenSSL::RSA
- Crypt::OpenSSL::Random
- Crypt::OpenSSL::AES
- Parse::Yapp
- Math::Prime::Util

For CLI application:
- Term::ReadLine::Gnu
- Getopt::Long::Descriptive
- Class::Inspector
- Exception::Class

## PREPARE
- generate parser using yapp: `yapp -m TL -s tl.yp`
- generate MTProto and Telegram TL packages: `perl tl-gen.pl MTProto res/mtproto.tl` and `perl tl-gen.pl Telegram res/layer76.tl`
