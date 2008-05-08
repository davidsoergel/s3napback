#!/usr/bin/perl

# s3napback.pl
# Manage cycling, incremental, compressed, encrypted backups on Amazon S3.
#
# Copyright (c) 2008 David Soergel
# 418 Richmond St., El Cerrito, CA  94530
# dev@davidsoergel.com
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
use Date::Format;
use File::stat;
use Getopt::Std;    
use Config::ApacheFormat;

my $diffdir;
my $bucket; 
my $recipient;
my $encrypt;
my $delete_from_s3;
my $send_to_s3;

my %isAlreadyDoneToday= {};

my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
$year += 1900;
$mon += 1;
my $datestring = time2str("%Y-%m-%d", time);


###### Print the header  
	
print "\n\n\n";
print "------------------------------------------------------------------\n";
print "Starting s3napback  $datestring   $hour:$min\n\n";


###### Process command-line Arguments + Options

my %opt;
getopts('c:td', \%opt) ||  die usage();

#if($opt{h}) {
#	usage();
#	exit 2;
#}

#my $debug = 0;

if($opt{t})
	{
	print "TEST MODE ONLY, NO REAL ACTIONS WILL BE TAKEN\n\n";
	}


###### Find config files

my @configs;

# Hmm, does Getopt::Std modify @ARGV to contain only what it didn't parse, or are we here looking at the whole thing?
# (doesn't really matter in practice)

for(@ARGV) {
	if(-f "/etc/s3napback/$_.conf") {
		push @configs, "/etc/s3napback/$_.conf";
	}
	elsif(-f "/etc/s3napback/$_") {
		push @configs, "/etc/s3napback/$_";
	}	
}

unshift @configs, $opt{c} if $opt{c};
@configs = '' unless @configs;


###### Parse config files

for my $configfile (@configs)
	{
	my $mainConfig = Config::ApacheFormat->new(
					 duplicate_directives => 'combine',
					inheritance_support => 0);

	$mainConfig->read($configfile);

	#print "config=" . $mainConfig->dump() . "\n";

	$diffdir = $mainConfig->get("DiffDir");
	$diffdir || die "DiffDir must be defined.";

	# insure that $diffdir ends with a slash
	if(!($diffdir =~ /\/$/))
		{
		$diffdir = $diffdir . "/";
		}

	$bucket = $mainConfig->get("Bucket");
	$bucket || die "Bucket must be defined.";
	
	my $keyring = $mainConfig->get("GpgKeyring");
	if($keyring)
		{
		$keyring = "--keyring $keyring";
		}

	my $recipient = $mainConfig->get("GpgRecipient");
	# $recipient || die "GpgRecipient must be defined.";
	# Empty recipient OK; in that case we just won't use GPG.

	my $s3keyfile = $mainConfig->get("S3Keyfile");
	$s3keyfile || die "S3Keyfile must be defined.";

	my $chunksize = $mainConfig->get("ChunkSize");
	$chunksize || die "ChunkSize must be defined.";

	#my $notifyemail = $mainConfig->get("NotifyEmail");
	#my $logfile = $mainConfig->get("LogFile");
	#my $loglevel = $mainConfig->get("LogLevel");


	###### Check gpg key availability
		
	my $checkgpg=`gpg --batch $keyring --list-public-keys`;
	if(defined $recipient && !($checkgpg =~ /$recipient/))
		{
		die "Requested GPG public key not found: $recipient";
		}


	###### Setup commands (this is the crux of the matter)
	
	if(defined $recipient)
		{	
		$encrypt="| gpg --batch $keyring -r $recipient -e";
		}
		
	$send_to_s3="| java -jar js3tream.jar --debug -z $chunksize -n -f -v -K $s3keyfile -i -b"; # -Xmx128M 
	$delete_from_s3="java -jar js3tream.jar -v -K $s3keyfile -d -b";
	
	
	###### Check what has already been done
	
	my $list_s3_bucket="java -jar js3tream.jar -v -K $s3keyfile -l -b $bucket 2>&1";
	
	print("Getting current contents of bucket $bucket modified on $datestring...\n");
	my @bucketlist = `$list_s3_bucket`;
	
	my @alreadyDoneToday = grep /$datestring/, @bucketlist;    ######### THIS DID NOT WORK BEFORE, TEST AGAIN #########
	
	# 2008-04-10 04:07:50 - dev.davidsoergel.com.backup1:MySQL/all-0 - 153.38k in 1 data blocks
	@alreadyDoneToday = map { s/^.* - (.*?) - .*$/\1/; chomp; $_ } @alreadyDoneToday;

	print "Buckets already done today: \n";
	map { print; print "\n"; } @alreadyDoneToday;
	for (@alreadyDoneToday) { $isAlreadyDoneToday{$_} = 1; }


	###### Perform the requested operations

	processBlock($mainConfig);

	for my $cycle ($mainConfig->get("Cycle"))
		{
		my $block = $mainConfig->block($cycle);
		processBlock($block);
		}

}

sub processBlock()
	{
	my($config) = @_;
	
	for my $name ($config->get("Directory"))
		{
		#print "Directory $name\n";
		
		my $block = $config;
		if(ref($name) eq 'ARRAY')
			{
			print($name->[0] . " => " . $name->[1] . "\n");
			$block = $config->block($name);
			$name = $name->[1];
			}

		my $frequency = $block->get("Frequency");
		my $phase = $block->get("Phase");
		my $diffs = $block->get("Diffs");
		my $fulls = $block->get("Fulls");
		my @excludes = $block->get("Exclude");
	
		backupDirectory($name, $frequency, $phase, $diffs, $fulls, @excludes);
  	}
    	
    for my $name ($config->get("Subversion"))
    	{
    	#print "Subversion $name\n";

		my $block = $config;
		if(ref($name) eq 'ARRAY') 
			{
				
			# avoid confusion with SubversionDir
	#		if($name->[0] ne "subversion")
	#			{
	#			next;
	#			}
				
			print($name->[0] . " => " . $name->[1] . "\n");
			$block = $config->block($name);
			$name = $name->[1];
			}

    	my $frequency = $block->get("Frequency");
		my $phase = $block->get("Phase");
    	my $fulls = $block->get("Fulls");
    
    	backupSubversion($name, $frequency, $phase, $fulls);
    	}
    
    for my $name ($config->get("SubversionDir"))
    	{
		my $block = $config;
		if(ref($name) eq 'ARRAY')
			{
			# avoid confusion with Subversion
	#		if($name->[0] ne "subversiondir")
	#			{
	#			next;
	#			}
				
			print($name->[0] . " => " . $name->[1] . "\n");
			$block = $config->block($name);
			$name = $name->[1];
			}

    	my $frequency = $block->get("Frequency");
		my $phase = $block->get("Phase");
    	my $fulls = $block->get("Fulls");
    
    	backupSubversionDir($name, $frequency, $phase, $fulls);
    	}
 
    for my $name ($config->get("MySQL"))
    	{
		my $block = $config;
		if(ref($name) eq 'ARRAY')
			{
			print($name->[0] . " => " . $name->[1] . "\n");
			$block = $config->block($name);
			$name = $name->[1];
			}

    	my $frequency = $block->get("Frequency");
		my $phase = $block->get("Phase");
    	my $fulls = $block->get("Fulls");
    
    	backupMysql($name, $frequency, $phase, $fulls);
    	}

	}	
	
sub backupDirectory
	{
	my ($name, $frequency, $phase, $diffs, $fulls, @excludes) = @_;
	
	if(($yday + $phase) % $frequency != 0)
		{
		print "Skipping $name\n";
		next;
		}
		
	my $difffile =  $name . ".diff";
	$difffile =~ s/\//_/g;
	$difffile = $diffdir . $difffile;
	
    my $sb = stat($difffile);
 	if(defined $sb)
		{	
		my ($sec,$min,$hour,$mday,$mon,$year,$wday,$diffyday,$isdst) = localtime($sb->mtime);
	
		if ( $diffyday == ($yday + $phase) )
			{
			print "Skipping $name; diff was already performed today\n";
			next;
			}
		}
		
	my $cycles = $fulls * ($diffs + 1);
	my $cyclenum = (($yday + $phase) / $frequency) % $cycles;
	
	my $type = "DIFF";

	if($cyclenum % ($diffs + 1) == 0)
		{
		$type = "FULL";
		unlink $difffile;
		}
		
	my $excludes = "";
	
	for my $exclude (@excludes)
		{
		$excludes .= " --exclude $exclude";
		}
	
	my $datasource = "tar $excludes -g $difffile -C / -czp $name";
	my $bucketfullpath = "$bucket:$name-$cyclenum-$type";

	print "Directory $name -> $bucketfullpath\n";
	sendToS3($datasource, $bucketfullpath);
	}
	
	
sub backupMysql
	{
	my ($name, $frequency, $phase, $fulls) = @_;
	
	if(($yday + $phase) % $frequency != 0)
		{
		print "Skipping $name\n";
		next;
		}
	
	my $cycles = $fulls;
	my $cyclenum = (($yday + $phase) / $frequency) % $cycles;
	

	
	my $socket = "";
	my $socketopt = "";
	if($name =~ /(.*):(.*)/)
		{
		$socket = $1;
		$socketopt = "--socket $1";
		$name = $2;
		}
	if($name eq "all") { $name = "--all-databases"; }
	my $datasource = "mysqldump --opt $socketopt $name | gzip";
	
	if($socket)
		{
		$name = "$socket/$name";
		}
		
	my $bucketfullpath = "$bucket:MySQL/$name-$cyclenum";
	print "MySQL $name -> $bucketfullpath\n";
	sendToS3($datasource, $bucketfullpath);
	}
	
	
sub backupSubversion
	{
	my ($name, $frequency, $phase, $fulls) = @_;
	
	if(($yday + $phase) % $frequency != 0)
		{
		print "Skipping $name\n";
		next;
		}
	
	my $cycles = $fulls;
	my $cyclenum = (($yday + $phase) / $frequency) % $cycles;
	
	my $datasource = "svnadmin -q dump $name | gzip";
	my $bucketfullpath = "$bucket:$name-$cyclenum";
	
	print "Subversion $name -> $bucketfullpath\n";
	sendToS3($datasource, $bucketfullpath);
	}
	
		
sub backupSubversionDir
	{
	my ($name, $frequency, $phase, $fulls) = @_;
	
	if(($yday + $phase) % $frequency != 0)
		{
		print "Skipping $name\n";
		next;
		}
	
	# inspired by https://popov-cs.grid.cf.ac.uk/subversion/WeSC/scripts/svn_backup
	
	my $cycles = $fulls;
	my $cyclenum = (($yday + $phase) / $frequency) % $cycles;
	
	opendir(DIR, $name);
	my @subdirs = readdir(DIR);
	closedir(DIR);

	foreach my $subdir (@subdirs) 
		{	
		`svnadmin verify $name/$subdir >& /dev/null`;
		if ($? == 0 )
			{
			my $datasource = "svnadmin -q dump $name/$subdir | gzip";
			my $bucketfullpath = "$bucket:$name/$subdir-$cyclenum";
			
			print "Subversion $name/$subdir -> $bucketfullpath\n";
			sendToS3($datasource, $bucketfullpath);
			}
		}
	}
	

sub sendToS3
	{
	my ($datasource,$bucketfullpath) = @_;
	
	if($isAlreadyDoneToday{$bucketfullpath} && !$opt{f})
		{
		print "Skipping $bucketfullpath; already done today\n";
		return;
		}
	
	if($opt{t} || $opt{d})
		{
		print "$delete_from_s3 $bucketfullpath\n";
		print "$datasource $encrypt $send_to_s3 $bucketfullpath\n\n";
		}

	if(!$opt{t})
		{
		# delete the bucket if it exists
		`$delete_from_s3 $bucketfullpath`;
	
		if($? != 0)
			{
			print("Could not delete old backup: $!\n");
			}
		
		# stream the data
		`$datasource $encrypt $send_to_s3 $bucketfullpath`;
	
		if($? != 0)
			{
			print("Backup to $bucketfullpath failed: $!\n");
			print("Deleting any partial backup\n");
		
			# delete the bucket if it exists
			`$delete_from_s3 $bucketfullpath`;
	
			if($? != 0)
				{
				print("Could not delete partial backup: $!\n");
				}
			}
		}
	}

