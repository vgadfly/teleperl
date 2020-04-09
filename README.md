# teleperl
Pure perl mtproto/telergam client library

## DEPENDS
- Modern::Perl
- Config::Tiny
- AnyEvent
- Object::Event
- Data::DPath
- Data::Validate::IP
- NetAddr::IP
- Crypt::OpenSSL::Bignum
- Crypt::OpenSSL::RSA
- Crypt::OpenSSL::Random
- Crypt::OpenSSL::AES
- Parse::Yapp
- Math::Prime::Util
- PBKDF2::Tiny

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

Not yet used but discussed:
- Template::Toolkit
- DBD::SQLite

## PREPARE
- generate parser using yapp: `yapp -m TL -s tl.yp`
- generate MTProto and Telegram TL packages: `perl tl-gen.pl MTProto res/mtproto.tl` and `perl tl-gen.pl Telegram res/<schemelayerNN>.tl` (see notes)
- edit config file to put your own API id/hash, phone number and possibly proxy
- login: create new session (session.dat for apps) with `auth` command of `cli.pl`: enter to it code sent by SMS or in other session

## NOTES / WARNS
Telegram.pm API is very unstable and subject to change greatly :) Other parts, too: note that official Telegram docs are mostly outdated and incomplete even for that parts - so often code is done by trial-and-error, which leads to many bugs. Beware. Here be dragons.

As scheme is not known to lower-level modules (there are both text strings and byte strings), do UTF-8 decode yourself (this may change after adding introspection).

Recently (August 2019) server bug was discovered in testing, when server sends constructors (CRC32 hash) from older scheme despite of requested level; you'll see `unknown object type` error (after which stream is in fact unusable so many more errors are just consequences). So you may need to experiment/generate from different layer files in `res` subdirectory. But beware that regularly updating server layer also requires changing client code logic (e.g. GUI client currently supports somehere at 78-82).

## LEGAL ISSUES
Publishing API ID/hash in source code prohibited by Telegram License / API Terms of Use. This contradicts to FLOSS principles (may be they plan to ban unofficial clients?), but that is, you won't be able to run Teleperl as-is. See https://github.com/telegramdesktop/tdesktop/blob/dev/docs/api_credentials.md for next steps.

This project is a _library_, not a feature-complete end-user client, and it's client application examples will never be. If you want to publish Teleperl-based end-user application, then you **MUST** implement features required by recent [Telegram API Terms of Use](https://core.telegram.org/api/terms).
