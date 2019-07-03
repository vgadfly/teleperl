# teleperl
Pure perl mtproto/telergam client

## DEPENDS
- Modern::Perl
- Config::Tiny
- AnyEvent
- IO::Socket::Socks
- Data::Validate::IP
- NetAddr::IP
- Crypt::OpenSSL::Bignum
- Crypt::OpenSSL::RSA
- Crypt::OpenSSL::Random
- Crypt::OpenSSL::AES
- Parse::Yapp
- Math::Prime::Util

For both interactive application's examples:
- Getopt::Long::Descriptive
- Class::Inspector

For CLI application:
- Term::ReadLine::Gnu
- Exception::Class

For GUI application (currently minimal almost unusable quick & dirty proof-of-work):
- Tcl
- Tkx
- a Tcl/Tk distribution for these two (out of the box in ActivePerl, else see https://tkdocs.com/tutorial/install.html), with following Tcl/Tk packages:
  * Tclx
  * BWidget
  * Tktable
  * treectrl
  * tklib (ctext tooltip widget)

Not required in minimal run (optional for extra features), but may be moved to core in future:
- CBOR::XS
- Data::DPath

Not yet used but discussed:
- Template::Toolkit
- DBD::SQLite

## PREPARE
- generate parser using yapp: `yapp -m TL -s tl.yp`
- generate MTProto and Telegram TL packages: `perl tl-gen.pl MTProto res/mtproto.tl` and `perl tl-gen.pl Telegram res/layer82-tdesktop.tl`
- edit config file to put your own API id/hash, phone number and possibly proxy
- if needed, create new session (session.dat for apps) with `auth.pl`: enter to it code sent by SMS or in other session, and then press ^C

## NOTES / WARNS
Telegram.pm API is very unstable and subject to change greatly :) Other parts, too: note that official Telegram docs are mostly outdated and incomplete even for that parts - so often code is done by trial-and-error, which leads to many bugs. Beware. Here be dragons.

As scheme is not known to lower-level modules (there are both text strings and byte strings), do UTF-8 decode yourself (this may change after adding introspection).

*LEGAL ISSUES*: Publishing API ID/hash in source code prohibited by Telegram License / API Terms of Use. This contradicts to FLOSS principles (may be they plan to ban unofficial clients?), but that is, you won't be able to run Teleperl as-is. See https://github.com/telegramdesktop/tdesktop/blob/dev/docs/api_credentials.md for next steps.
