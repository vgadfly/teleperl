# teleperl
Pure perl mtproto/telergam client

## DEPENDS
- Modern::Perl
- Config::Tiny
- AnyEvent
- IO::Socket::Socks
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

For GUI application (currently minimal almost unusable quick & dirty proof-of-work):
- Tcl
- Tkx
- a Tcl/Tk distribution for these two (out of the box in ActivePerl), see https://tkdocs.com/tutorial/install.html

Not yet used but discussed:
- Template::Toolkit
- CBOR::XS
- DBD::SQLite

## PREPARE
- generate parser using yapp: `yapp -m TL -s tl.yp`
- generate MTProto and Telegram TL packages: `perl tl-gen.pl MTProto res/mtproto.tl` and `perl tl-gen.pl Telegram res/layer78.tl`
- edit config file to put your own API id/hashm, phone number and possibly proxy
- if needed, create new session (session.dat for apps) with `auth.pl`: enter to it code sent by SMS or in other session, and then press ^C

## NOTES
Telegram.pm API is subject to change; do UTF-8 decode yourself.
