#!/usr/bin/perl
# Loads LWMediaRemote.dylib into Apple's perl (allowed to read system Now Playing) and runs it.
# Usage: /usr/bin/perl lwmr.pl /path/to/LWMediaRemote.dylib
use strict;
use warnings;
use DynaLoader;

my $path = shift or die "usage: lwmr.pl <LWMediaRemote.dylib>\n";
my $lib = DynaLoader::dl_load_file($path, 0) or die DynaLoader::dl_error();
my $sym = DynaLoader::dl_find_symbol($lib, "lw_stream") or die DynaLoader::dl_error();
DynaLoader::dl_install_xsub("main::lw_stream", $sym);
lw_stream();
