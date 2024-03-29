#!/usr/bin/perl
#
# MBBuild.pm -- part of MBPerl
#
# Copyright (c) 2021-2022 Michael Banack <github@banack.net>
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
use File::Copy;
use File::Compare;

use Exporter();
our ($VERSION, @ISA, @EXPORT, @EXPORT_OK);
# set the version for version checking
$VERSION     = $MBBasic::VERSION;
@ISA         = qw(Exporter);
@EXPORT_OK   = qw(&Init &Exit &Configure);
@EXPORT      = qw();

my $gBuildOptions = {
    "buildType=s" => { desc => "Build Type: debug/develperf/release",
                       default => 'release', },
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
sub Configure($;$$$)
{
    my $callerTargets = shift;
    my $callerBareOptions = shift;
    my $callerConfig = shift;
    my $callerDefines = shift;

    ASSERT(!defined($callerConfig) || ref($callerConfig) eq 'HASH');
    ASSERT(!defined($callerDefines) || ref($callerDefines) eq 'HASH');
    ASSERT($gInitialized);

    my @defines;

    # Load static defaults
    $gConfig->{'BUILDROOT'} = 'build';

    if (defined($OPTIONS->{buildType})) {
        $gConfig->{'BUILDTYPE'} = $OPTIONS->{buildType};
    } else {
        $gConfig->{'BUILDTYPE'} = 'release';
    }

    # Load bareOpts
    ASSERT(!defined($callerBareOptions) || ref($callerBareOptions) eq 'ARRAY');
    if (defined($callerBareOptions) && ArrayLen($callerBareOptions) > 0) {
        VERIFY(ArrayLen($callerBareOptions) == 1, 'Too many bareOpts');
        my $bare = $callerBareOptions->[0];

        if ($bare =~ /^debug|develperf|release$/) {
            $gConfig->{'BUILDTYPE'} = $bare;
        } else {
            Panic("Unknown bare option: $bare\n");
        }
    }

    # Load callerConfig
    if (defined($callerConfig)) {
        foreach my $x (keys(%{$callerConfig})) {
            $gConfig->{$x} = $callerConfig->{$x};
        }
    }

    # Load buildType defaults
    Console("Build Type: $gConfig->{'BUILDTYPE'}\n");
    if ($gConfig->{'BUILDTYPE'} eq "debug") {
        $gConfig->{'MB_DEBUG'} = TRUE;
        $gConfig->{'MB_DEVEL'} = TRUE;
    } elsif ($gConfig->{'BUILDTYPE'} eq "develperf") {
        $gConfig->{'MB_DEBUG'} = FALSE;
        $gConfig->{'MB_DEVEL'} = TRUE;
    } elsif ($gConfig->{'BUILDTYPE'} eq "release") {
        $gConfig->{'MB_DEBUG'} = FALSE;
        $gConfig->{'MB_DEVEL'} = FALSE;
    } else {
        Panic("Unknown buildType: $gConfig->{'BUILDTYPE'}\n");
    }

    $gConfig->{'BUILDTYPE_ROOT'} = catdir($gConfig->{'BUILDROOT'},
                                          $gConfig->{'BUILDTYPE'});

    # Load dynamic defaults
    if (!defined($gConfig->{'TMPDIR'})) {
        $gConfig->{'TMPDIR'} = catfile($gConfig->{'BUILDROOT'}, 'tmp');
    }

    if (!defined($gConfig->{'DEPROOT'})) {
        $gConfig->{'DEPROOT'} = catfile($gConfig->{'BUILDTYPE_ROOT'}, 'deps');
    }

    if (!defined($gConfig->{'MBLIB_BUILDDIR'})) {
        $gConfig->{'MBLIB_BUILDDIR'} =
            catdir($gConfig->{'BUILDTYPE_ROOT'},
                   $OPTIONS->{'MBLibOutputDirPrefix'});
    }

    if (!defined($gConfig->{'MBLIB_DEPDIR'})) {
        $gConfig->{'MBLIB_DEPDIR'} =
            catdir($gConfig->{'DEPROOT'}, $OPTIONS->{'MBLibOutputDirPrefix'});
    }

    if (!defined($gConfig->{'MBLIB_SRCDIR'})) {
        $gConfig->{'MBLIB_SRCDIR'} =
            catdir('.', $OPTIONS->{'MBLibOutputDirPrefix'});
    }

    if (!defined($gConfig->{'MB_HAS_SDL2'})) {
        if (-f '/usr/lib64/libSDL2.so' ||
            -f '/usr/lib/x86_64-linux-gnu/libSDL2.so') {
            Console("SDL2 detected\n");
            $gConfig->{'MB_HAS_SDL2'} = TRUE;
        } else {
            Console("SDL2 not detected\n");
            $gConfig->{'MB_HAS_SDL2'} = FALSE;
        }
    } else {
        if ($gConfig->{'MB_HAS_SDL2'}) {
            Console("SDL2 enabled by config\n");
        } else {
            Console("SDL2 disabled by config\n");
        }
    }

    if ( $^O eq 'linux') {
        Console("Linux detected\n");
        $gConfig->{'MB_LINUX'} = TRUE;
        $gConfig->{'DEFAULT_CFLAGS'} .= " -D _GNU_SOURCE";
    } elsif ($^O eq 'darwin') {
        Console("MacOS detected\n");
        $gConfig->{'MB_MACOS'} = TRUE;
    } else {
        Panic("Unknown OS: $^O\n");
    }

    $gConfig->{'DEFAULT_CFLAGS'} .= " -march=native";

    if ($gConfig->{'MB_DEVEL'}) {
        Console("Enabling devel options\n");
        $gConfig->{'DEFAULT_CFLAGS'} .= " -Wall -Wextra -Werror -g";
        $gConfig->{'DEFAULT_CFLAGS'} .= " -Wno-attributes";
        $gConfig->{'DEFAULT_CFLAGS'} .= " -Wno-unused-parameter";
        $gConfig->{'DEFAULT_CFLAGS'} .= " -Wno-sign-compare";
        if (!$gConfig->{'MB_MACOS'}) {
            $gConfig->{'DEFAULT_CFLAGS'} .= " -Wno-format-truncation";
        }
        $gConfig->{'DEFAULT_CFLAGS'} .= " -Wno-unused-result";
    } else {
        Console("Disabling devel options\n");
        $gConfig->{'DEFAULT_CFLAGS'} .= " -Wno-unused-result";
    }

    if ($gConfig->{'MB_DEBUG'}) {
        Console("Enabling debug options\n");
        $gConfig->{'DEFAULT_CFLAGS'} .= " -Og -g";
        $gConfig->{'DEFAULT_CFLAGS'} .= " -fno-omit-frame-pointer";
        $gConfig->{'DEFAULT_CFLAGS'} .= " -Wno-type-limits";
    } else {
        Console("Disabling debug options\n");
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

    Console("Using CC=" . $gConfig->{'CC'} . "\n");
    Console("Using CXX=" . $gConfig->{'CXX'} . "\n");

    # Load defaults from caller
    foreach my $x (keys(%{$callerDefines})) {
        $gConfig->{$x} = $callerDefines->{$x};
        push(@defines, $x);
    }
    if (defined($gConfig->{'PROJECT_CFLAGS'})) {
        $gConfig->{'DEFAULT_CFLAGS'} .= " " . $gConfig->{'PROJECT_CFLAGS'};
    }
    delete $gConfig->{'PROJECT_CFLAGS'};

    if ($OPTIONS->{'verbose'}) {
        Dump($gConfig);
    }

    # Make target symlinks
    ASSERT(!defined($callerTargets) || ref($callerTargets) eq 'ARRAY');
    if (defined($callerTargets) && ArrayLen($callerTargets) > 0) {
        foreach my $t (@{$callerTargets}) {
            my $link = catfile($gConfig->{'BUILDROOT'}, $t);
            my $target = catfile($gConfig->{'BUILDTYPE'}, $t);
            unlink($link);
            symlink($target, $link);
        }
    }

    # Make buildtree symlinks
    my $link = catfile($gConfig->{'BUILDROOT'}, 'current');
    my $tree = $gConfig->{'BUILDTYPE'};
    unlink($link);
    symlink($tree, $link);

    #Open files
    make_path($gConfig->{'MBLIB_BUILDDIR'});
    make_path($gConfig->{'TMPDIR'});
    make_path($gConfig->{'MBLIB_DEPDIR'});

    my $cMake;
    my $cHeader;
    my $cHeaderNewPath = catfile($gConfig->{'BUILDTYPE_ROOT'}, 'config.h.new');
    my $cHeaderPath = catfile($gConfig->{'BUILDTYPE_ROOT'}, 'config.h');
    open($cMake, '>', 'config.mk') or Panic($!);
    open($cHeader, '>', $cHeaderNewPath) or Panic($!);

    print $cHeader "#ifndef ALLOW_MBBUILD_CONFIG_H\n";
    print $cHeader "#error Cannot include config.h directly, use MBConfig.h\n";
    print $cHeader "#endif\n";

    # Save joint MakeFile/Header options
    foreach my $x ('MB_LINUX', 'MB_MACOS', 'MB_DEBUG', 'MB_DEVEL',
                   'MB_HAS_SDL2') {
        if (defined($gConfig->{$x})) {
            ASSERT($gConfig->{$x} eq '1' || $gConfig->{$x} eq '0');

            print $cMake "$x=" . $gConfig->{$x} . "\n";

            if ($gConfig->{$x} eq '1') {
                print $cHeader "#define $x " . $gConfig->{$x} . "\n";
            }
        }

        delete $gConfig->{$x};
    }

    # Save Makefile-only options
    foreach my $x  ('BUILDROOT', 'BUILDTYPE', 'BUILDTYPE_ROOT',
                    'TMPDIR', 'DEPROOT',
                    'MBLIB_BUILDDIR', 'MBLIB_DEPDIR',
                    'MBLIB_SRCDIR', 'DEFAULT_CFLAGS',
                    'CC', 'CXX') {
        print $cMake "$x=" . $gConfig->{$x} . "\n";
        delete $gConfig->{$x};
    }

    # Save caller defines
    foreach my $x (sort @defines) {
        if (defined($gConfig->{$x})) {
            ASSERT($gConfig->{$x} eq '1' || $gConfig->{$x} eq '0');

            print $cMake "$x=" . $gConfig->{$x} . "\n";
            if ($gConfig->{$x} eq '1') {
                print $cHeader "#define $x " . $gConfig->{$x} . "\n";
            }
        }

        delete $gConfig->{$x};
    }

    close($cMake);
    close($cHeader);

    # See if we've changed the config
    if (compare($cHeaderPath, $cHeaderNewPath) != 0) {
        move($cHeaderNewPath, $cHeaderPath);
    }

    # Check for unused keys
    foreach my $x (keys(%{$gConfig})) {
        Panic("Unused key found in gConfig: $x => " . $gConfig->{$x} . "\n");
    }

    Console("\nConfigured!\n");
}
