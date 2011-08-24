#!/usr/bin/perl -w

# s3napback.pl
# Manage cycling, incremental, compressed, encrypted backups on Amazon S3.
#
# Version 1.12  (May 24, 2011)
#
# Copyright (c) 2008-2011 David Soergel
# 178 West St., Northampton, MA  01060
# dev@davidsoergel.com
#
# With major contributions by Kevin Ross and Scott Squires
#
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
#     * Redistributions of source code must retain the above copyright notice,
#       this list of conditions and the following disclaimer.
#     * Redistributions in binary form must reproduce the above copyright
#       notice, this list of conditions and the following disclaimer in the
#       documentation and/or other materials provided with the distribution.
#     * Neither the name of the author nor the names of any contributors may
#       be used to endorse or promote products derived from this software
#       without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
# LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
# A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
# CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
# EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
# PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
# PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
# LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
# NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

use strict;
use warnings;
use Log::Log4perl;
use Date::Format;
use File::stat;
use Getopt::Std;
use Config::ApacheFormat;
use File::Spec::Functions qw(rel2abs);
use File::Basename;
use Switch;

my $diffdir;
my $tempdir;
my $bucket;
my $recipient;
my $encrypt = "";
my $delete_from_s3;
my $send_to_s3;

my %isAlreadyDoneToday = ();
my %opt;

my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) = localtime(time);
$year += 1900;
$mon  += 1;
my $datestring = time2str( "%Y-%m-%d", time );
my $curPath = dirname( rel2abs($0) ) . "/";

###### Setup logging

Log::Log4perl->init("${curPath}s3napback.logconfig");

sub main() {
    my $logger = Log::Log4perl::get_logger("Backup::S3napback");

###### Print the header

    $logger->info("Starting s3napback");

###### Process command-line Arguments + Options

    getopts( 'c:fht', \%opt ) || die usage();

    if ( $opt{h} ) {
        usage();
        exit 2;
    }

    if ( $opt{t} ) {
        $logger->warn("TEST MODE ONLY, NO REAL ACTIONS WILL BE TAKEN");
    }

    if ( $opt{f} ) {
        $logger->warn("FORCE MODE; DATA MAY BE OVERWRITTEN");
    }

###### Find config files

    my @configs;

    # assume any params not processed are config files
    for (@ARGV) {
        if ( -f "/etc/s3napback/$_.conf" ) {
            push @configs, "/etc/s3napback/$_.conf";
        }
        elsif ( -f "/etc/s3napback/$_" ) {
            push @configs, "/etc/s3napback/$_";
        }
    }

    # get one config file from -c option
    unshift @configs, $opt{c} if $opt{c};
    @configs = '' unless @configs;

###### Parse config files

    for my $configfile (@configs) {
        my $mainConfig = Config::ApacheFormat->new(
            duplicate_directives => 'combine',
            inheritance_support  => 0,
            fix_booleans         => 1
        );

        $mainConfig->read($configfile);

        $logger->debug( "config=" . $mainConfig->dump() );

        $diffdir = $mainConfig->get("DiffDir");
        $diffdir || die "DiffDir must be defined.";

        # insure that $diffdir ends with a slash
        if ( !( $diffdir =~ /\/$/ ) ) {
            $diffdir = $diffdir . "/";
        }

        # insure that $diffdir exists.  Warn the user to do it manually instead of creating it, since DiffDir may be misconfigured
        unless ( -e $diffdir ) {
            die("DiffDir does not exist, please create: $diffdir");
        }

        $tempdir = $mainConfig->get("TempDir");
        if ( defined $tempdir ) {

            # insure that $tempdir ends with a slash
            if ( !( $tempdir =~ /\/$/ ) ) {
                $tempdir = $tempdir . "/";
            }
        }

        $bucket = $mainConfig->get("Bucket");
        $bucket || die "Bucket must be defined.";

        my $keyring = $mainConfig->get("GpgKeyring");
        if ($keyring) {
            $keyring = "--keyring $keyring";
        }
        else {
            $keyring = "";
        }

        my $recipient = $mainConfig->get("GpgRecipient");

        # Empty recipient OK; in that case we just won't use GPG.

        my $s3keyfile = $mainConfig->get("S3Keyfile");
        $s3keyfile || die "S3Keyfile must be defined.";

        my $chunksize = $mainConfig->get("ChunkSize");
        $chunksize || die "ChunkSize must be defined.";

        ###### Check gpg key availability

        if ( defined $recipient ) {
            my $checkgpg = `gpg --batch $keyring --list-public-keys`;
            if ( !( $checkgpg =~ /$recipient/ ) ) {
                $logger->logdie("GPG recipient $recipient not found in $checkgpg");
            }
        }

        ###### Setup commands (this is the crux of the matter)

        if ( defined $recipient ) {
            $encrypt = "| gpg --batch $keyring -r $recipient -e";
        }

        $send_to_s3     = "java -jar ${curPath}js3tream.jar --debug -z $chunksize -n -f -v -K $s3keyfile -i -b";    # -Xmx128M
        $delete_from_s3 = "java -jar ${curPath}js3tream.jar -v -K $s3keyfile -d -b";

        ###### Check what has already been done

        my $list_s3_bucket = "java -jar ${curPath}js3tream.jar -v -K $s3keyfile -l -b $bucket 2>&1";

        $logger->info("Getting current contents of bucket $bucket modified on $datestring...");
        my @bucketlist = `$list_s3_bucket`;

        $logger->debug( join "\n", @bucketlist );

        my @alreadyDoneToday = grep /$datestring/, @bucketlist;    ######### THIS DID NOT WORK BEFORE, TEST AGAIN #########

        # 2008-04-10 04:07:50 - dev.davidsoergel.com.backup1:MySQL/all-0 - 153.38k in 1 data blocks
        @alreadyDoneToday = map { s/^.* - (.*?) - .*$/$1/; chomp; $_ } @alreadyDoneToday;

        $logger->info("Buckets already done today:");
        for (@alreadyDoneToday) { $logger->info($_); $isAlreadyDoneToday{$_} = 1; }

        ###### Perform the requested operations

        processBlock($mainConfig);

        for my $cycle ( $mainConfig->get("Cycle") ) {
            my $block = $mainConfig->block($cycle);
            processBlock($block);
        }
    }
}

sub processBlock() {
    my ($config) = @_;

    my $logger = Log::Log4perl::get_logger("Backup::S3napback");
    my $function;
    my @params;

    for my $directive (qw(Directory Subversion SubversionDir MySQL PostgreSQL)) {
        for my $name ( $config->get($directive) ) {
            my $block = $config;
            if ( ref($name) eq 'ARRAY' ) {
                $logger->info( $name->[0] . " => " . $name->[1] );
                $block = $config->block($name);
                $name  = $name->[1];
            }

            my $cyclespec = cyclespec($block);
            if ( !isBackupDay($cyclespec) && !$opt{f} ) {
                $logger->warn("Skipping $directive $name");
                next;
            }

            @params = ();
            switch ($directive) {
                case "Directory" {
                    $function = \&backupDirectory;
                    my @excludes = $block->get("Exclude");
                    @params = ( \@excludes );
                }

                case "Subversion"    { $function = \&backupSubversion; }
                case "SubversionDir" { $function = \&backupSubversionDir; }
                case "MySQL"         { $function = \&backupMysql; }
                case "PostgreSQL"    { $function = \&backupPostgreSQL; }
            }

            &{$function}( $name, $cyclespec, @params );
        }
    }
}

sub backupDirectory {
    my ( $name, $cyclespec, $excludes_ref ) = @_;
    my ( $cycletype, $frequency, $phase, $diffs, $fulls, $discs, $archivedisc, $usetemp ) = @{$cyclespec};
    my @excludes = @{$excludes_ref};

    my $logger = Log::Log4perl::get_logger("Backup::S3napback::Directory");

    my $difffile = getDiffFilename($name);
    my $sb       = stat($difffile);
    if ( defined $sb ) {
        my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $diffyday, $isdst ) = localtime( $sb->mtime );

        if ( $diffyday == ( $yday + $phase ) && !$opt{f} ) {
            $logger->warn("Skipping $name; diff was already performed today");
            return;
        }
    }

    my $cyclenum = getSlotNumber($cyclespec);
    my $type = getSlotMode( $cyclespec, $cyclenum );

    if ( $type eq "FULL" ) {
        unlink $difffile;
    }

    my $excludes = "";

    for my $exclude (@excludes) {
        $excludes .= " --exclude $exclude";
    }

    my $datasource     = "tar -f - $excludes -g $difffile -C / -czp $name";
    my $bucketfullpath = "$bucket:$name-$cyclenum-$type";

    $logger->info("Directory $name -> $bucketfullpath");
    sendToS3( $datasource, $bucketfullpath, $usetemp, $logger );
}

sub backupMysql {
    my ( $name, $cyclespec ) = @_;
    my ( $cycletype, $frequency, $phase, $diffs, $fulls, $discs, $archivedisc, $usetemp ) = @{$cyclespec};

    my $logger = Log::Log4perl::get_logger("Backup::S3napback::MySQL");

    # note $diffs is ignored

    my $ignore_diffs = 1;
    my $cyclenum = getSlotNumber( $cyclespec, $ignore_diffs );

    my $socket    = "";
    my $socketopt = "";
    if ( $name =~ /(.*):(.*)/ ) {
        $socket    = $1;
        $socketopt = "--socket $1";
        $name      = $2;
    }
    if ( $name eq "all" ) { $name = "--all-databases"; }
    my $datasource = "mysqldump --opt $socketopt $name | gzip";

    if ($socket) {
        $name = "$socket/$name";
    }

    my $bucketfullpath = "$bucket:MySQL/$name-$cyclenum";
    $logger->info("MySQL $name -> $bucketfullpath");
    sendToS3( $datasource, $bucketfullpath, $usetemp, $logger );
}

sub backupPostgreSQL {
    my ( $name, $cyclespec ) = @_;
    my ( $cycletype, $frequency, $phase, $diffs, $fulls, $discs, $archivedisc, $usetemp ) = @{$cyclespec};

    my $logger = Log::Log4perl::get_logger("Backup::S3napback::PostgreSQL");

    # note $diffs is ignored
    my $ignore_diffs = 1;
    my $cyclenum = getSlotNumber( $cyclespec, $ignore_diffs );

    my $user_opt = "";
    if ( $name =~ /(.*)@(.*)/ ) {
        $user_opt = "-U $1";
        $name     = $2;
    }

    my $pg_dump_cmd = "";
    if ( $name eq "all" ) {
        $pg_dump_cmd = "pg_dumpall";
        $name        = "";
    }
    else {
        $pg_dump_cmd = "pg_dump";
    }

    my $datasource = "$pg_dump_cmd $user_opt $name | gzip";

    my $bucketfullpath = "$bucket:PostgreSQL/$name-$cyclenum";
    $logger->info("PostgreSQL $name -> $bucketfullpath");
    sendToS3( $datasource, $bucketfullpath, $usetemp, $logger );
}

sub backupSubversionDir {
    my ( $name, $cyclespec ) = @_;

    my $logger = Log::Log4perl::get_logger("Backup::S3napback::Subversion");

    # inspired by https://popov-cs.grid.cf.ac.uk/subversion/WeSC/scripts/svn_backup

    opendir( DIR, $name ) || die("Cannot open directory: $name");
    my @subdirs = readdir(DIR);
    closedir(DIR);

    foreach my $subdir (@subdirs) {
        $logger->debug(`svnadmin verify $name/$subdir 2>&1 1>/dev/null`);
        if ( $? == 0 ) {
            backupSubversion( "$name/$subdir", $cyclespec );
        }
    }
}

#
# Inspired by from http://le-gall.net/pierrick/blog/index.php/2007/04/17/98-subversion-incremental-backup
# Adapted to s3napback by Kevin Ross - metova.com
#
sub backupSubversion {
    my ( $name, $cyclespec ) = @_;
    my ( $cycletype, $frequency, $phase, $diffs, $fulls, $discs, $archivedisc, $usetemp ) = @{$cyclespec};

    my $logger = Log::Log4perl::get_logger("Backup::S3napback::Subversion");

    my $difffile = getDiffFilename($name);

    # initialize the last saved revision as -1, that way on the first pass it is simply incremented to 0 (the first revision).
    my $lastSavedRevision = -1;

    # check the time on any existing diff file to see if this was already done today.
    my $sb = stat($difffile);
    if ( defined $sb ) {
        my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $diffyday, $isdst ) = localtime( $sb->mtime );

        if ( $diffyday == ( $yday + $phase ) && !$opt{f} ) {
            $logger->warn("Skipping $name -- was already backed up today");
            return;
        }

        # The diff file exists and we need to run, so read the last saved revision from the file
        open( LAST_SAVED_REVISION, '<', $difffile ) || die("Cannot open diff file: $difffile");
        $lastSavedRevision = <LAST_SAVED_REVISION>;
        chomp $lastSavedRevision;
        close(LAST_SAVED_REVISION);
    }

    my $cyclenum = getSlotNumber($cyclespec);

    my $type = getSlotMode( $cyclespec, $cyclenum );
    if ( $lastSavedRevision < 0 ) {
        $type = "FULL";
    }
    if ( $type eq "FULL" ) {

        # remove the diff file, we want to do a full backup.
        unlink $difffile;
        $lastSavedRevision = -1;
    }

    # get informed of the current last revision (head)
    my $headRevision = `svnlook youngest $name`;
    chomp $headRevision;

    $logger->debug("Last revision of $name: $headRevision");

    if ( $type eq "DIFF" && $lastSavedRevision == $headRevision ) {

        # of course, if the head is not younger than the last saved revision it's useless to go on backing up.
        $logger->info("$name has no new revisions since last backup; skipping");
        return;
    }

    # if the last saved is 1000 and the head is 1023, we want the backup from 1001 to 1023
    my $fromRevision = $lastSavedRevision + 1;
    my $toRevision   = $headRevision;

    my $datasource     = "svnadmin dump -q -r$fromRevision:$toRevision --incremental $name | gzip";
    my $bucketfullpath = "$bucket:$name-$cyclenum-$type";

    $logger->info("Subversion $name -> $bucketfullpath");
    sendToS3( $datasource, $bucketfullpath, $usetemp, $logger );

    # Save last revision to the diff file so we know where to pick up later.
    if ( !$opt{t} ) {
        open( LAST_SAVED_REVISION, '>', $difffile ) || die("Cannot open diff file: $difffile");
        print LAST_SAVED_REVISION $toRevision, "\n";
        close(LAST_SAVED_REVISION);
    }
}

sub sendToS3 {

    # by passing the logger in here we can select to print debug log messages only for MySQL blocks, etc.
    my ( $datasource, $bucketfullpath, $shouldUseTempFile, $logger ) = @_;

    if ( $isAlreadyDoneToday{$bucketfullpath} && !$opt{f} ) {
        $logger->warn("Skipping $bucketfullpath -- already done today");
        return;
    }

    # setup in case this is a temp file scenario
    my $tempfile = $bucketfullpath . ".temp";
    $tempfile =~ s/\//_/g;
    if ( $shouldUseTempFile == 1 ) {
        $tempdir || $logger->logdie("TempDir must be defined in order to UseTempFile.");
        $tempfile = $tempdir . $tempfile;
    }

    if ( $opt{t} ) {
        $logger->info("$delete_from_s3 $bucketfullpath");

        # print out the statements for test mode.
        if ( $shouldUseTempFile == 1 ) {

            # stream the data to a temp file first, then to jS3tream
            $logger->info("Using temp file to buffer before streaming[ $tempfile ]...");
            $logger->info("$datasource $encrypt > $tempfile");
            $logger->info("$send_to_s3 $bucketfullpath <  $tempfile");
            $logger->info("rm $tempfile");
        }
        else {

            # stream the data
            $logger->info("$datasource $encrypt | $send_to_s3 $bucketfullpath");
        }

        return;
    }

    # delete the bucket if it exists
    $logger->debug(`$delete_from_s3 $bucketfullpath`);

    if ( $? != 0 ) {
        $logger->error("Could not delete old backup: $!");
    }

    if ( $shouldUseTempFile == 1 ) {

        # stream the data to a temp file first, then to jS3tream
        $logger->info("Using temp file to buffer before streaming [ $tempfile ]...");
        $logger->debug(`$datasource $encrypt > $tempfile`);

        if ( $? != 0 ) {
            $logger->error("Failed to stream to temporary file: $!");
        }
        else {
            $logger->debug(`$send_to_s3 $bucketfullpath <  $tempfile`);
        }

        deleteOnError( $bucketfullpath, $logger );

        # delete the remnants of the temp file if there was one.
        $logger->info("Deleting temp file [ $tempfile ].");
        unlink $tempfile;

    }
    else {

        # stream the data
        $logger->debug(`$datasource $encrypt | $send_to_s3 $bucketfullpath`);
        deleteOnError();
    }
}

sub deleteOnError {
    my ( $bucketfullpath, $logger ) = @_;

    if ( $? != 0 ) {
        $logger->error("Backup to $bucketfullpath failed: $!");
        $logger->error("Deleting any partial backup");

        # delete the bucket if it exists
        $logger->debug(`$delete_from_s3 $bucketfullpath`);

        if ( $? != 0 ) {
            $logger->error("Could not delete partial backup: $!");
        }
    }
}

sub cyclespec {
    my ($block) = @_;

    my $cycletype = $block->get("CycleType");

    # SimpleCycle
    my $frequency = $block->get("Frequency");
    my $phase     = $block->get("Phase");
    my $diffs     = $block->get("Diffs");
    my $fulls     = $block->get("Fulls");

    # HanoiCycle
    my $discs       = $block->get("Discs");
    my $archivedisc = $block->get("ArchiveOldestDisc");

    my $usetemp = $block->get("UseTempFile");

    if ( !defined $cycletype ) { $cycletype = "SimpleCycle"; }

    if ( !defined $frequency ) { $frequency = 1; }
    if ( !defined $phase )     { $phase     = 0; }
    if ( !defined $diffs )     { $diffs     = 6; }
    if ( !defined $fulls )     { $fulls     = 4; }

    if ( !defined $discs )       { $discs       = 5; }
    if ( !defined $archivedisc ) { $archivedisc = 0; }    # false

    if ( !defined $usetemp ) { $usetemp = 0; }            # false

    my @cyclespec = ( $cycletype, $frequency, $phase, $diffs, $fulls, $discs, $archivedisc, $usetemp );

    return \@cyclespec;
}

sub getSlotNumber {
    my ( $cyclespec, $ignore_diffs ) = @_;

    my ( $cycletype, $frequency, $phase, $diffs, $fulls, $discs, $archivedisc, $usetemp ) = @{$cyclespec};

    if ( !defined $ignore_diffs ) {
        $ignore_diffs = 0;
    }

    my $cyclenum = undef;

    switch ($cycletype) {
        case "SimpleCycle" {
            my $cycles = 0;
            if ($ignore_diffs) {
                $cycles = $fulls;
            }
            else {
                $cycles = $fulls * ( $diffs + 1 );
            }
            $cyclenum = ( ( $yday + $phase ) / $frequency ) % $cycles;
        }

        case "HanoiCycle" {
            my $cycle_days  = 2**( $discs - 1 );                                     # number of days it takes to use all slots
            my $epoch_days  = int( time / 86400 );                                   # days since epoch
            my $epoch_cycle = int( $epoch_days / ( $cycle_days * $frequency ) );     # cycles since epoch
            my $cycle_day   = ( ( $epoch_days / $frequency ) % $cycle_days ) + 1;    # day nbr within cycle

            my $cycle_slot   = leastSignificantBitPosition($cycle_day);
            my $archive_slot = $epoch_cycle + $cycle_slot;

            if ($archivedisc) {
                $cyclenum = $archive_slot;
            }
            else {
                $cyclenum = $cycle_slot;
            }
        }
    }

    return $cyclenum;
}

sub getSlotMode {
    my ( $cyclespec, $cyclenum ) = @_;
    my ( $cycletype, $frequency, $phase, $diffs, $fulls, $discs, $archivedisc, $usetemp ) = @{$cyclespec};

    my $type = undef;

    switch ($cycletype) {
        case "SimpleCycle" {
            $type = "DIFF";
            if ( $cyclenum % ( $diffs + 1 ) == 0 ) {
                $type = "FULL";
            }
        }

        case "HanoiCycle" {
            $type = "FULL";
        }
    }

    return $type;
}

sub isBackupDay {
    my $cyclespec = shift;
    my ( $cycletype, $frequency, $phase, $diffs, $fulls, $discs, $archivedisc, $usetemp ) = @{$cyclespec};

    my $result = 0;

    switch ($cycletype) {
        case "SimpleCycle" { $result = ( $yday + $phase ) % $frequency == 0; }
        case "HanoiCycle"  { $result = int( time / 86400 ) % $frequency == 0; }
    }

    return $result;
}

sub getDiffFilename {
    my $name     = shift;
    my $difffile = $name . ".diff";
    $difffile =~ s/\//_/g;
    $difffile = $diffdir . $difffile;
    return $difffile;
}

sub leastSignificantBitPosition {
    my $value = shift;

    my $clear_lsb   = $value & ( $value - 1 );
    my $isolate_lsb = $value ^ $clear_lsb;
    my $lsb_pos     = log($isolate_lsb) / log(2);

    return $lsb_pos;
}

sub usage {
    print "usage: s3napback.pl [-t] -c config\n";
}

main();
