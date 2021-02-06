#!/usr/bin/perl
#
# MBBasic.pm -- part of MBPerl
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


package MBBasic;

use strict;
use warnings;

use Exporter();
our ($VERSION, @ISA, @EXPORT, @EXPORT_OK);
$VERSION     = 1.1;
@ISA         = qw(Exporter);
@EXPORT_OK   = qw($PROGRAM_VERSION $PROGRAM_NAME $PROGRAM_AUTHOR
                  $PROGRAM_COPYRIGHT_DATE
                  &Init &Exit &StatsReport OpenLogFile);
@EXPORT      = qw(TRUE FALSE $OPTIONS
                  &ASSERT &VERIFY &FUNCTION &Panic &NOT_REACHED
                  &NOT_IMPLEMENTED &ArrayLen
                  &TRACE
                  &Warning &LogV
                  &splitpath &basename &catfile &catdir &hostname
                  &StatTimePush &StatTimePop
                  &Dump &max &min &average
                  &LoadMRegFile &SaveMRegFile
                  &LoadCSVFile &SaveCSVFile
                  &ArrayContainsString &Sleep
                  &UndefToZero &UndefToEmpty
                  &PushHashValues &SumHashValues
                  &HyphenString &Trim);

use constant TRUE => 1;
use constant FALSE => 0;

# Global variables for help/version messages.
# (So scripts can override them at the top of their files.
our $PROGRAM_VERSION;
our $PROGRAM_NAME=basename($0);
our $PROGRAM_AUTHOR;
our $PROGRAM_COPYRIGHT_DATE;

# Exported parsed options list.
our $OPTIONS = {};

# Private module variables.
my $gStatsStack;
my $gStats;
my $gInitialized;
my $gOptionList;
my $gPanicCount;
my $gLogFile;

my $gBasicOptionList = {
    "help|h|?!" =>  { desc => "Print this help text", default => FALSE },
    "version|v!" => { desc => "Print the version number", default => FALSE },
    "verbose|V!" => { desc => "Print verbose messages", default => FALSE},
    "log=s" => { desc => "Use the specified log file", default => undef },
    "stats!" => { desc => "Collect stats information",
                  default => FALSE,
                  hidden => TRUE, },
    "verboseStats!" => { desc => "Print verbose stat information",
                         default => FALSE,
                         hidden => TRUE, },
};

# Wrappers for standard Perl library functions
sub splitpath { require File::Spec; return File::Spec->splitpath(@_); }
sub basename { require File::Basename; return File::Basename::basename(@_); }
sub catfile { require File::Spec::Functions; return File::Spec->catfile(@_); }
sub catdir { require File::Spec::Functions; return File::Spec->catdir(@_); }
sub hostname { require Sys::Hostname; return Sys::Hostname::hostname(); }


###########################################################
# Init --
#   Initialize the library and parse the options.
###########################################################
sub Init()
{
    ASSERT(!$gInitialized);
    LoadOptions($gBasicOptionList, __PACKAGE__);

    $gInitialized = TRUE;
    if (!ParseOptions(\@ARGV, $OPTIONS, $gOptionList) ||
        $OPTIONS->{help} || $OPTIONS->{usage}) {
        Usage(TRUE);
        exit 255;
    }

    if ($OPTIONS->{version}) {
        Usage(FALSE);
        exit 255;
    }

    if ($OPTIONS->{stats}) {
        $gStats = {};
    }

    if (defined($OPTIONS->{log})) {
        OpenLogFile($OPTIONS->{log});
    }

    StatTimePush("MBBasic::Script");
}


###########################################################
# Exit --
#   Clean up anything on the way out.
###########################################################
sub Exit()
{
    ASSERT($gInitialized);
    StatTimePop("MBBasic::Script");
    StatsReport();
    CloseLogFile();
}


###########################################################
# LoadOptions --
#   Load options from the provided array.
###########################################################
sub LoadOptions($;$)
{
    my $opts = shift;
    my $category = shift;

    ASSERT(!$gInitialized);
    $gOptionList = MergeOptionLists($gOptionList, $opts, $category);
}


###########################################################
# ParseOptions --
#   Parse options from the provided array.
#   Leftover options are put into $optOut->{bareOptions}.
#
#   Returns TRUE iff everything parsed correctly,
#   and FALSE if there were errors.
###########################################################
sub ParseOptions($$$)
{
    my $optArray = shift;
    my $optOut = shift;
    my $optList = shift;

    ASSERT(ref($optArray) eq "ARRAY");
    ASSERT(ref($optOut) eq "HASH");
    ASSERT(ref($optList) eq "HASH");

    require Getopt::Long;

    Getopt::Long::Configure("bundling");
    if (!Getopt::Long::GetOptionsFromArray($optArray, $optOut,
                                           keys(%$optList))) {
        return FALSE;
    }

    foreach my $opt (keys(%{$optList})) {
        my $key;
        if ($opt =~ /^([^=|!+:]*)/) {
            $key = $1;
        } else {
            NOT_IMPLEMENTED();
        }

        if (!defined($optOut->{$key})) {
            my $val = $optList->{$opt}->{default};
            $optOut->{$key} = $val;
        }
    }

    ASSERT(!defined($optOut->{bareOptions}));
    $optOut->{bareOptions} = [];
    push(@{$optOut->{bareOptions}}, @{$optArray});

    return TRUE;
}


###########################################################
# MergeOptionLists --
#   Merge two option lists together using the specified
#   option category.
#
#   Returns the new option list.
###########################################################
sub MergeOptionLists($$;$)
{
    my $oldOptions = shift;
    my $newOptions = shift;
    my $category = shift;

    my $oup = {};

    foreach my $key (keys(%{$oldOptions})) {
        $oup->{$key} = $oldOptions->{$key};
    }

    foreach my $key (keys(%{$newOptions})) {
        if (defined($oup->{$key})) {
            if (defined($newOptions->{$key}->{'override'}) &&
                $oup->{$key}->{'category'} eq
                $newOptions->{$key}->{'override'}) {
                # New option overrides old
                $oup->{$key} = $newOptions->{$key};
                $oup->{$key}->{'category'} = $category;
            } elsif (defined($oup->{$key}->{'override'}) &&
                     $category eq $oup->{$key}->{'override'}) {
                # Old option overrides new
            } else {
               Panic("Duplicate option without \'override\': key=$key",
                     "oldCategory=" . $oup->{$key}->{'category'},
                     "newCategory=" . $category);
            }
        } else {
            # Only the new option exists
            $oup->{$key} = $newOptions->{$key};
            $oup->{$key}->{'category'} = $category;
        }
    }

    return $oup;
}


###########################################################
# Usage --
#   Print the script usage.
###########################################################
sub Usage(;$)
{
    my $fullUsage = shift;

    ASSERT($gInitialized);

    ASSERT(defined($PROGRAM_NAME));
    my $versionLine = $PROGRAM_NAME;

    if (defined($PROGRAM_VERSION)) {
        $versionLine .= " version $PROGRAM_VERSION"
    }

    if (defined($PROGRAM_AUTHOR)) {
        if (defined($PROGRAM_COPYRIGHT_DATE)) {
            $versionLine .= "\nCopyright (c) $PROGRAM_COPYRIGHT_DATE " .
                            "$PROGRAM_AUTHOR";
        } else {
            $versionLine .= " by $PROGRAM_AUTHOR";
        }
    }

    Warning("$versionLine\n");

    if (!$fullUsage) {
        return;
    }

    Warning("Usage: $PROGRAM_NAME [options]\n");

    foreach my $opt (keys(%{$gOptionList})) {
        if (!$gOptionList->{$opt}->{'hidden'}) {
            my $str = sprintf("%20s : %s", $opt, $gOptionList->{$opt}->{desc});
            Warning("$str\n");
        }
    }
}


#######################################
# ArrayLen --
#  Returns the length of an array ref.
#######################################
sub ArrayLen($)
{
    my $a = shift;
    ASSERT(ref($a) eq "ARRAY", "Argument is not an arrayref");
    return scalar @{ $a }
}


###########################################################
# OpenLogFile --
#   Opens the specified log file, and starts using it to
#   log Warning/Log calls.
###########################################################
sub OpenLogFile($)
{
    my $logFileName = shift;

    if (defined($gLogFile)) {
        CloseLogFile();
        ASSERT(!defined($gLogFile));
    }

    open($gLogFile, ">", $logFileName) or
        Panic("Unable to open log file: $logFileName");
    VERIFY(defined($gLogFile));
}


###########################################################
# CloseLogFile --
#   Closes an opened log file.
#   Nothing further will be logged.
###########################################################
sub CloseLogFile()
{
    if (defined($gLogFile)) {
        Log("Closing log file...\n");
        close($gLogFile);
        $gLogFile = undef;
    }
}


###########################################################
# Warning --
#   Print the arguments to the console, and log file.
###########################################################
sub Warning($)
{
    my $msg = shift;

    print($msg);

    if (defined($gLogFile)) {
        print $gLogFile $msg;
    }
}


###########################################################
# Log --
#   Print the arguments to the log-file, and also to the
#   console if set to be verbose.
###########################################################
sub Log($)
{
    my $msg = shift;

    if ($OPTIONS->{verbose}) {
        print($msg);
    }

    if (defined($gLogFile)) {
        print $gLogFile $msg;
    }
}


###########################################################
# Dump --
#   Dump all the arguments to Warning in string form.
#   Intended for debugging.
###########################################################
sub Dump($)
{
    my $arg = shift;
    require Data::Dumper;
    my $old = $Data::Dumper::Sortkeys;
    $Data::Dumper::Sortkeys = TRUE;
    Warning(Data::Dumper::Dumper($arg));
    $Data::Dumper::Sortkeys = $old;
}


###########################################################
# NOT_IMPLEMENTED --
#   Panic for an unhandled condition.
###########################################################
sub NOT_IMPLEMENTED(;$)
{
    my $msg = shift;

    if (defined($msg)) {
        chomp($msg);
        Panic("NOT_IMPLEMENTED: $msg\n");
    } else {
        Panic("NOT_IMPLEMENTED\n");
    }
}


###########################################################
# ASSERT --
#   Check for a condition, and Panic if it is not met.
#   Intended only for program-invariants.
###########################################################
sub ASSERT($;@)
{
    my $condition = shift;
    my @args = @_;

    if (!$condition) {
        Panic("ASSERT", @args);
    }
}


###########################################################
# VERIFY --
#   Check for a condition, and Panic if it is not met.
#   Intended for external constraints, or unhandled
#   serious conditions.
###########################################################
sub VERIFY($;@)
{
   my $condition = shift;
   my @args = @_;

   if (!$condition) {
      Panic("VERIFY", @args);
   }
}

###########################################################
# FUNCTION --
#   Return the name of the calling function, as a string.
###########################################################
sub FUNCTION()
{
    my $level = 0;
    my $function = (caller($level + 1))[3];
    $function =~ s/^main:://;
    return $function;
}

###########################################################
# PrintBacktrace --
#   Print the current backtrace.
###########################################################
sub PrintBacktrace()
{
    my $level = 0;
    my $function = (caller($level + 1))[3];
    while (defined($function)) {
        $function = (caller($level + 1))[3];
        my $file = (caller($level))[1];
        my $line = (caller($level))[2];

        if (defined($function)) {
            $file =~ s/^.*\///g;
            $function = sprintf("%-20s", $function);
            Warning("  [$level]: $function $file:$line\n");
        }
        $level++
    }
}

###########################################################
# TRACE --
#   Print the current function and line-number.
#   Intended for debugging.
###########################################################
sub TRACE()
{
    my $level = 0;
    my $file = (caller($level))[1];
    my $line = (caller($level))[2];
    my $function = (caller($level + 1))[3];
    $function =~ s/^main:://;
    Warning("$file:$line ($function)\n");
}

###########################################################
# GetPanicLine --
#   Helper function for Panic paths to find the caller.
###########################################################
sub GetPanicLine()
{
    my $level = 0;

    #This will eventually terminate, because function will come
    #back as undefined.
    while(TRUE) {
        $level++;
        my $file = (caller($level - 1))[1];
        my $line = (caller($level - 1))[2];
        my $function = (caller($level))[3];

        if (!defined($function)) {
            $function = "undefined";
        }

        if ($function ne "MBBasic::Panic" &&
            $function ne "MBBasic::ASSERT" &&
            $function ne "MBBasic::NOT_IMPLEMENTED" &&
            $function ne "MBBasic::VERIFY") {

            $file =~ s/^.*[\/\\]//g;
            return "$file:$line ($function)";
        }
     }
}


###########################################################
# Panic --
#   Exit the program with a helpful backtrace.
#   This function does not return.
###########################################################
sub Panic
{
    my @args = @_;
    my $message = join("\n", @args);
    chomp($message);

    $gPanicCount++;
    if ($gPanicCount > 1) {
        if ($gPanicCount <= 2) {
            print("Panic Loop!\n");
            print("PANIC: $message\n");
            Warning("Panic Loop!\n");
            Warning("PANIC: $message\n");
        }
        exit(253);
    }

    Warning("\n");
    Warning("PANIC: $message\n");
    Warning("       " . GetPanicLine() . "\n\n");
    PrintBacktrace();

    CloseLogFile();

    print("\nPANIC: $message\n\n");
    exit(254);
}

###########################################################
# NOT_REACHED --
#   Crash upon hitting unexpected control-flow.
###########################################################
sub NOT_REACHED() {
   Panic("NOT_REACHED");
}

###########################################################
# StatTimePush --
#   Start a stat timer.
###########################################################
sub StatTimePush($)
{
    my $stat = shift;

    if (!$OPTIONS->{stats}) {
        return;
    }

    ASSERT(!defined($gStatsStack) || ref($gStatsStack) eq "ARRAY");

    require Time::HiRes;

    my $statItem = {};
    $statItem->{name} = $stat;
    $statItem->{startTime} = Time::HiRes::time();
    $statItem->{childTime} = 0;

    push(@{$gStatsStack}, $statItem);
}

###########################################################
# StatTimePop --
#   End a stat timer.
###########################################################
sub StatTimePop($)
{
    my $stat = shift;

    if (!$OPTIONS->{stats}) {
        return;
    }

    ASSERT(defined($gStatsStack));

    require Time::HiRes;

    my $now = Time::HiRes::time();
    my $statItem = pop(@{$gStatsStack});
    my $name = $statItem->{name};
    my $start = $statItem->{startTime};
    my $diff = $now - $start;
    my $fdiff = sprintf("%.2f s", $diff);

    ASSERT($stat eq $name, "Mismatched stat pop: expected=$stat, got=$name\n");

    if ($OPTIONS->{verboseStats}) {
        Warning("Stat: $statItem->{name}, selfTime=$fdiff\n");
    }
    LogV("Elapsed Time: $fdiff\n");

    my $stackLen = ArrayLen($gStatsStack);
    if ($stackLen > 0) {
        my $oldItem = $gStatsStack->[$stackLen - 1];
        ASSERT(defined($oldItem));
        $oldItem->{childTime} += $diff;
    }

    ASSERT(ref($gStats) eq "HASH");

    my $statVar = $gStats->{$name};

    if (!defined($statVar)) {
        $statVar = {};
        $statVar->{name} = $name;
        $statVar->{count} = 0;
        $statVar->{totalTime} = 0;
        $statVar->{selfTime} = 0;
    }
    ASSERT($statVar->{name} eq $name);

    $statVar->{count}++;
    $statVar->{totalTime} += $diff;
    $statVar->{selfTime} += $diff - $statItem->{childTime};

    $gStats->{$name} = $statVar;
}


###########################################################
# StatsReport --
#   Print a report about all stats.
###########################################################
sub StatsReport()
{
    if (!$OPTIONS->{stats}) {
        return;
    }

    ASSERT(ArrayLen($gStatsStack) == 0,
           "Unpopped stat still on the stack.");

    Warning("MBBasic::StatsReport\n");
    my $str = sprintf("%30s %10s %20s %20s\n",
                      "Name", "Count", "SelfTime", "TotalTime");
    Warning($str);

    my @arr = keys %{$gStats};
    @arr = sort {
                  $gStats->{$b}->{selfTime} <=>
                  $gStats->{$a}->{selfTime}
                } @arr;

    foreach my $key (@arr) {
        my $statVar = $gStats->{$key};
        my $totalTime = sprintf("%.2fs", $statVar->{totalTime});
        my $selfTime = sprintf("%.2fs", $statVar->{selfTime});
        $str = sprintf("%30s %10s %20s %20s\n",
                       $statVar->{name}, $statVar->{count}, $selfTime,
                       $totalTime);
        Warning($str);
    }
}


###############################################################
# max --
#   Wrap List::Util::max, but propagate undef without warning.
###############################################################
sub max
{
    my $a = \@_;

    ASSERT(ref($a) eq "ARRAY");

    if (ArrayLen($a) == 0) {
        return undef;
    }

    foreach my $e (@{$a}) {
        if (!defined($e)) {
            return undef;
        }
    }

    my $max = List::Util::max(@{$a});
    return $max;
}


###############################################################
# min --
#   Wrap List::Util::min, but propagate undef without warning.
###############################################################
sub min
{
    my $a = \@_;

    ASSERT(ref($a) eq "ARRAY");

    if (ArrayLen($a) == 0) {
        return undef;
    }

    foreach my $e (@{$a}) {
        if (!defined($e)) {
            return undef;
        }
    }

    my $min = List::Util::min(@{$a});
    return $min;
}


###########################################################
# average --
#   Average the provided values, skipping undef.
#   Returns the average of the array, or undef if there were
#   no defined parameters.
###########################################################
sub average(@)
{
    my @args = @_;

    my $count = 0;
    my $sum = 0;

    foreach my $k (@args) {
        if (defined($k)) {
            $count++;
            $sum += $k
        }
    }

    if ($count > 0) {
        return $sum / $count;
    } else {
        return undef;
    }
}

###########################################################
# LoadMRegFile --
#   Loads an "MReg" file into a hash table.
#   An "MReg" file is a key-value store of strings.
#   Returns a hashref of the key-value pairs.
###########################################################
sub LoadMRegFile($)
{
    my $mregFile = shift;
    my $entries = {};

    VERIFY(-f $mregFile);

    my $fh;
    my $line;

    open($fh, '<', $mregFile) or Panic("Unable to open MReg file", $!);
    $line = <$fh>;
    chomp($line);
    VERIFY($line =~ /^MJ?BBasic::MReg::Version=(\d+)$/,
           "File does not appear to be an MReg file",
           "file=$mregFile");
    my $version = $1;
    VERIFY($version <= 3);

    while (defined($line = <$fh>)) {
        my $key;
        my $value;
        if ($line =~ /^\"/) {
            VERIFY($line =~ /^\"([^"]+)\"=(.*)$/);
            $key = $1;
            $value = $2;
        } else {
            VERIFY($line =~ /^([^=]+)=(.*)$/, "line=$line");
            $key = $1;
            $value = $2;
        }
        $entries->{$key} = $value;
    }
    close($fh);

    return $entries;
}


###########################################################
# SaveMRegFile --
#   Saves an "MReg" file from a hash table.
#   (See LoadMRegFile.)
###########################################################
sub SaveMRegFile($$)
{
    my $entries = shift;
    my $mregFile = shift;

    ASSERT(ref($entries) eq 'HASH');

    my $fh;
    open($fh, '>', $mregFile) or Panic("Unable to open MReg file", $!);
    print $fh "MBBasic::MReg::Version=3\n";
    foreach my $key (sort keys(%{$entries})) {
        my $value = $entries->{$key};

        if ($key =~ /=/) {
            $key = "\"$key\"";
        } else {
            ASSERT($key !~ /"/ && $key ne "", "Bad MReg key: $key");
        }
        printf $fh "$key=$value\n";
    }
    close($fh);
}

###########################################################
# LoadCSVFile --
#   Loads a CSV file.
#   Returns an arrayref of hashrefs of the data.
###########################################################
sub LoadCSVFile($;$)
{
    my $csvFile = shift;
    my $expectedFields = shift;

    if (defined($expectedFields)) {
        ASSERT(ref($expectedFields) eq 'ARRAY');
    }

    my $fh;
    open($fh, '<', $csvFile) or Panic("Unable to open CSV file", $!);

    my $line = <$fh>;

    if (!defined($line) || $line eq "\n") {
        return undef;
    }

    chomp($line);
    VERIFY($line !~ /\\,/, "Escaped-CSV commas not implemented");
    my @fields = split(/,/, $line);

    if (defined($expectedFields)) {
        foreach my $f (@{$expectedFields}) {
            VERIFY(ArrayContainsString(\@fields, $f),
                   "Expected field missing: $f");
        }
        foreach my $f (@fields) {
            VERIFY(ArrayContainsString($expectedFields, $f),
                   "Unexpected field: $f");
        }
    }

    my $arr = [];
    while (defined($line = <$fh>)) {
        chomp($line);
        VERIFY($line !~ /\\,/, "Escaped-CSV commas not implemented");
        my @v = split(/,/, $line);
        my $row = {};

        for (my $i = 0; $i < ArrayLen(\@fields); $i++) {
            my $f = $fields[$i];
            if (defined($v[$i])) {
                $row->{$f} = $v[$i];
            } else {
                $row->{$f} = undef;
            }
        }

        push(@{$arr}, $row);
    }

    close($fh);
    return $arr;
}


###########################################################
# SaveCSVFile --
#   Saves a CSV file.
#   Takes an arrayref of field names (in order),
#   and an arrayref of hashrefs of the data.
###########################################################
sub SaveCSVFile($$$)
{
    my $csvFile = shift;
    my $fields = shift;
    my $data = shift;

    ASSERT(ref($fields) eq 'ARRAY');
    ASSERT(ref($data) eq 'ARRAY');

    my $fh;
    open($fh, '>', $csvFile) or Panic("Unable to open CSV file", $!);
    print $fh join(',', @{$fields});
    print $fh "\n";

    foreach my $item (@{$data}) {
        my @row;
        for (my $i = 0; $i < ArrayLen($fields); $i++) {
            my $f = $fields->[$i];
            my $v = $item->{$f};
            push(@row, UndefToEmpty($v));
        }
        print $fh join(',', @row);
        print $fh "\n";
    }

    close($fh);
}


###########################################################
# ArrayContainsString --
#   Returns TRUE iff the array contains the specified item.
###########################################################
sub ArrayContainsString($$)
{
    my $array = shift;
    my $string = shift;

    ASSERT(ref($array) eq 'ARRAY');
    foreach my $a (@{$array}) {
        if ($a eq $string) {
            return TRUE;
        }
    }

    return FALSE;
}


###########################################################
# Sleep --
#   Sleep for the specified number of seconds.
###########################################################
sub Sleep($)
{
   my $seconds = shift;
   if ($seconds <= 0) {
      return;
   }
   select(undef, undef, undef, $seconds);
}


###########################################################
# UndefToZero --
#   Sanitize a value to zero if it is undefined.
###########################################################
sub UndefToZero($)
{
    my $value = shift;
    if (defined($value)) {
        return $value;
    } else {
        return 0;
    }
}


###########################################################
# UndefToEmpty --
#   Sanitize a value to empty-string if it is undefined.
###########################################################
sub UndefToEmpty($)
{
    my $value = shift;
    if (defined($value)) {
        return $value;
    } else {
        return "";
    }
}


###########################################################
# PushHashValues --
#   Insert the elements from one hashref into another.
###########################################################
sub PushHashValues($$;$)
{
    my $src = shift;
    my $dest = shift;
    my $op = shift;

    if (!defined($op)) {
        foreach my $k (keys(%{$src})) {
            $dest->{$k} = $src->{$k};
        }
    } elsif ($op eq 'sum') {
        foreach my $k (keys(%{$src})) {
            if (defined($dest->{$k})) {
                $dest->{$k} += $src->{$k};
            } else {
                $dest->{$k} = $src->{$k};
            }
        }
    } else {
        Panic("Unknown op: $op\n");
    }
}

###########################################################
# HyphenString --
#   Returns a string of N hyphens.
###########################################################
sub HyphenString($)
{
    my $n = shift;

    if (!defined($n) || $n == 0) {
        return "";
    }

    my @partial;
    my $str = "-";
    my $l = 1;

    while ($l < $n) {
        if (($l & $n) != 0) {
            push(@partial, $str);
            $n -= $l;
        }

        $str = $str . $str;
        $l *= 2;
    }
    push(@partial, $str);
    ASSERT($l == $n);

    return join("", @partial);
}



###########################################################
# Trim --
#   Strip leading/trailing ws from a given string.
###########################################################
sub Trim($)
{
    my $s = shift;

    if (!defined($s)) {
        return undef;
    }

    $s =~ s/^\s+//g;
    $s =~ s/\s+$//g;
    return $s;
}

return 1; # We always load successfully.
