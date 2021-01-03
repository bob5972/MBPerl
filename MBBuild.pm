#!/usr/bin/perl
#
# MBBuild.pm -- part of MBPerl
#
# Copyright (c) 2021 Michael Banack <github@banack.net>
#
# MIT License
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.


package MBBuild;

use strict;
use warnings;

use MBBasic;
use File::Path qw(make_path);

use Exporter();
our ($VERSION, @ISA, @EXPORT, @EXPORT_OK);
# set the version for version checking
$VERSION     = 1.0;
@ISA         = qw(Exporter);
@EXPORT_OK   = qw(&Init &Exit &Configure);
@EXPORT      = qw();

my $gBuildOptions = {
    "useClang!" => { desc => "Use Clang as the compiler?",
                     default => FALSE, },
    "MBLibOutputDirPrefix=s" => { desc => "Prefix for MBLib output dirs",
                                  default => "MBLib", },
};

my $gInitialized;
my $gConfig = {};


###########################################################
# Init --
#   Initialize the library and parse the options.
###########################################################
sub Init()
{
    MBBasic::LoadOptions($gBuildOptions, __PACKAGE__);
    MBBasic::Init();
    $gInitialized = TRUE;
}

###########################################################
# Exit --
#   Clean up anything on the way out.
###########################################################
sub Exit()
{
    $gInitialized = FALSE;
    MBBasic::Exit();
}

###########################################################
# Configure --
#   Clean up anything on the way out.
###########################################################
sub Configure(;$)
{
    my $callerOpts = shift;

    ASSERT(!defined($callerOpts) || ref($callerOpts) eq 'HASH');
    ASSERT($gInitialized);

    my @defines;

    # Load static defaults
    $gConfig->{'BUILDROOT'} = 'build';
    $gConfig->{'DEBUG'} = TRUE;
    $gConfig->{'DEVEL'} = TRUE;

    # Load environment defaults
    foreach my $x ('BUILDROOT', 'TMPDIR', 'DEPROOT',
                   'MBLIB_BUILDDIR', 'MBLIB_DEPDIR',
                   'MBLIB_SRCDIR', 'DEBUG', 'DEFAULT_CFLAGS',
                   'CC', 'CXX') {
        if (defined($ENV{$x})) {
            $gConfig->{$x} = $ENV{$x};
        }
    }

    # Load dynamic defaults
    if (!$gConfig->{'TMPDIR'}) {
        $gConfig->{'TMPDIR'} = catfile($gConfig->{'BUILDROOT'}, 'tmp');
    }

    if (!$gConfig->{'DEPROOT'}) {
        $gConfig->{'DEPROOT'} = catfile($gConfig->{'BUILDROOT'}, 'deps');
    }

    if (!$gConfig->{'MBLIB_BUILDDIR'}) {
        $gConfig->{'MBLIB_BUILDDIR'} =
            catdir($gConfig->{'BUILDROOT'}, $OPTIONS->{'MBLibOutputDirPrefix'});
    }

    if (!$gConfig->{'MBLIB_DEPDIR'}) {
        $gConfig->{'MBLIB_DEPDIR'} =
            catdir($gConfig->{'DEPROOT'}, $OPTIONS->{'MBLibOutputDirPrefix'});
    }

    if (!$gConfig->{'MBLIB_SRCDIR'}) {
        $gConfig->{'MBLIB_SRCDIR'} =
            catdir('.', $OPTIONS->{'MBLibOutputDirPrefix'});
    }

    if ( $^O eq 'linux') {
        $gConfig->{'LINUX'} = TRUE;
        $gConfig->{'DEFAULT_CFLAGS'} .= " -D _GNU_SOURCE";
    } elsif ($^O eq 'darwin') {
        $gConfig->{'MACOS'} = TRUE;
    } else {
        Panic("Unknown OS: $^O\n");
    }

    $gConfig->{'DEFAULT_CFLAGS'} .= " -march=native";

    if ($gConfig->{'DEVEL'}) {
        $gConfig->{'DEFAULT_CFLAGS'} .= " -Wall -Wextra -Werror -g";
        $gConfig->{'DEFAULT_CFLAGS'} .= " -Wno-attributes";
        $gConfig->{'DEFAULT_CFLAGS'} .= " -Wno-unused-parameter";
        $gConfig->{'DEFAULT_CFLAGS'} .= " -Wno-sign-compare";
        $gConfig->{'DEFAULT_CFLAGS'} .= " -Wno-format-truncation";
        $gConfig->{'DEFAULT_CFLAGS'} .= " -Wno-unused-result";
    }

    if ($gConfig->{'DEBUG'}) {
        $gConfig->{'DEFAULT_CFLAGS'} .= " -Og -g";
        $gConfig->{'DEFAULT_CFLAGS'} .= " -fno-omit-frame-pointer";
        $gConfig->{'DEFAULT_CFLAGS'} .= " -Wno-type-limits";
    } else {
        $gConfig->{'DEFAULT_CFLAGS'} .= " -O2";
        $gConfig->{'DEFAULT_CFLAGS'} .= " -fomit-frame-pointer";
        $gConfig->{'DEFAULT_CFLAGS'} .= " -Wno-unused-variable";
        $gConfig->{'DEFAULT_CFLAGS'} .= " -Wno-unused-function";
    }

    my $dcc = $gConfig->{'CC'};
    my $dcxx = $gConfig->{'CXX'};
    if ($OPTIONS->{'useClang'}) {
        $dcc = 'clang';
        $dcxx = 'clang++';
        $gConfig->{'DEFAULT_CFLAGS'} .= " -Wno-constant-logical-operand";
        $gConfig->{'DEFAULT_CFLAGS'} .= " -Wno-unused-function";
    } else {
        $dcc = 'gcc';
        $dcxx = 'g++';
    }

    if (!$gConfig->{'CC'}) {
        $gConfig->{'CC'} = $dcc;
    }
    if (!$gConfig->{'CXX'}) {
        $gConfig->{'CXX'} = $dcxx;
    }

    # Load defaults from caller
    foreach my $x (keys(%{$callerOpts})) {
        $gConfig->{$x} = $callerOpts->{$x};
        push(@defines, $x);
    }

    if ($OPTIONS->{'verbose'}) {
        Dump($gConfig);
    }

    #Open files
    make_path($gConfig->{'MBLIB_BUILDDIR'});
    make_path($gConfig->{'TMPDIR'});
    make_path($gConfig->{'MBLIB_DEPDIR'});

    my $cMake;
    my $cHeader;
    open($cMake, '>', 'config.mk') or Panic($!);
    open($cHeader, '>', catfile($gConfig->{'BUILDROOT'}, 'config.h')) or Panic($!);

    # Save Makefile options
    foreach my $x  ('BUILDROOT', 'TMPDIR', 'DEPROOT',
                    'MBLIB_BUILDDIR', 'MBLIB_DEPDIR',
                    'MBLIB_SRCDIR', 'DEFAULT_CFLAGS',
                    'CC', 'CXX') {
        print $cMake "$x=" . $gConfig->{$x} . "\n";
        delete $gConfig->{$x};
    }

    # Save joint MakeFile/Header options
    push(@defines, 'LINUX', 'MACOS', 'DEBUG', 'DEVEL');
    foreach my $x (@defines) {
        if (defined($gConfig->{$x})) {
            print $cMake "$x=" . $gConfig->{$x} . "\n";
            print $cHeader "#define $x " . $gConfig->{$x} . "\n";
        }

        delete $gConfig->{$x};
    }

    # Check for unused keys
    foreach my $x (keys(%{$gConfig})) {
        Panic("Unused key found in gConfig: $x => " . $gConfig->{$x} . "\n");
    }
}
