#!/usr/bin/perl

# s3snap.pl
# Manage cycling, incremental, compressed, encrypted backups on Amazon S3.
#
# Copyright (c) 2001-2007 David Soergel
# 418 Richmond St., El Cerrito, CA  94530
# david@davidsoergel.com
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
use File::stat;
use Config::ApacheFormat;

my $diffdir;
my $bucket; 
my $recipient;
my $encrypt;
my $delete_from_s3;
my $send_to_s3;

my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);

print "\n\n\n";
print "------------------------------------------------------------------\n";
print "Starting s3snap  $mday/$mon/$year   $hour:$min\n\n";

my %opt;
#---------- ---------- ---------- ---------- ---------- ----------
# Process command-line Arguments + Options
getopts('t', \%opt) ||  die usage();

#if($opt{h}) {
#	usage();
#	exit 2;
#}

#my $debug = 0;

#my @configs; 

#for(@ARGV) {
#	if(-f "/etc/s3napback/$_.conf") {
#		push @configs, "/etc/snapback/$_.conf";
#	}
#	elsif(-f "/etc/s3napback/$_") {
#		push @configs, "/etc/s3napback/$_";
#	}
#	
#}

if($opt{t})
	{
	print "TEST MODE ONLY, NO REAL ACTIONS WILL BE TAKEN\n";
	}

my $mainConfig = new Config::ApacheFormat;
#					 duplicate_directives => 'combine',
#					 root_directive => 's3napback',
#					;

$mainConfig->read(<STDIN>);

print "config=$mainConfig\n";

my $diffdir = $mainConfig->get("DiffDir");
$diffdir || die "DiffDir must be defined.";

# insure that $diffdir ends with a slash
if(!$diffdir ~= /\/$/)
	{
	$diffdir = $diffdir . "/";
	}

my $bucket = $mainConfig->get("Bucket");
$bucket || die "Bucket must be defined.";
	
my $recipient = $mainConfig->get("GpgRecipient");
$recipient || die "GpgRecipient must be defined.";

my $s3keyfile = $mainConfig->get("S3Keyfile");
$s3keyfile || die "S3Keyfile must be defined.";

my $chunksize = $mainConfig->get("ChunkSize");
$chunksize || die "ChunkSize must be defined.";

#my $notifyemail = $mainConfig->get("NotifyEmail");
#my $logfile = $mainConfig->get("LogFile");
#my $loglevel = $mainConfig->get("LogLevel");

# setup commands (this is the crux of the matter)
my $encrypt="gpg -r $recipient -e";
my $send_to_s3="java -Xmx128M -jar js3tream.jar --debug -z $chunksize -n -v -K $s3keyfile -i -b";
my $delete_from_s3="java -jar js3tream.jar -v -K $s3keyfile -d -b";

processBlock($mainConfig);

for my $cycle ($mainConfig->get("Cycle"))
	{
	my $block = $mainConfig->block(Cycle => $name);
	processBlock($block);
	}

sub processBlock()
	{
	my($config) = @_;
	
	for my $name ($config->get("Subversion"))
		{
		my $block = $config->block(Subversion => $name);
		my $frequency = $block->get("frequency");
		my $fulls = $block->get("Fulls");
	
		backupSubversion($name, $frequency, $fulls);
		}
	
	for my $name ($config->get("SubversionDir"))
		{
		my $block = $config->block(SubversionDir => $name);
		my $frequency = $block->get("frequency");
		my $fulls = $block->get("Fulls");
	
		backupSubversionDir($name, $frequency, $fulls);
		}

	for my $name ($config->get("MySQL"))
		{
		my $block = $config->block(MySQL => $mysql);
		my $frequency = $block->get("frequency");
		my $fulls = $block->get("Fulls");
	
		backupMysql($name, $frequency, $fulls);
		}

	for my $name ($config->get("Directory"))
		{
		my $block = $config->block(Directory => $name);
		my $frequency = $block->get("frequency");
		my $diffs = $block->get("Diffs");
		my $fulls = $block->get("Fulls");
	
		backupDirectory($name, $frequency, $diffs, $fulls);
		}
	}	
	
sub backupDirectory
	{
	my ($name, $frequency, $diffs, $fulls) = @_;
	
	if($yday % $frequency != 0)
		{
		print "Skipping $name\n";
		next;
		}
		
	my $difffile = $diffdir . $name . ".diff";
	
    my $sb = stat($difffile);
 	if(defined $sb)
		{	
		my ($sec,$min,$hour,$mday,$mon,$year,$wday,$diffyday,$isdst) = localtime($sb->mtime);
	
		if ( $diffyday == $yday )
			{
			print "Skipping $name; diff was already performed today\n";
			next;
			}
		}
		
	my $cycles = $fulls * $diffs;
	my $cyclenum = ($yday / $frequency) % $cycles;
	
	my $type = "DIFF";

	if($cyclenum % $fulls == 0)
		{
		$type = "FULL";
		unlink $difffile;
		}
	
	my $datasource = "tar -g $difffile -C / -czp $name";
	my $bucketfullpath = "$bucket:$name-$cyclenum-$type";

	print "Directory $name -> $bucketfullpath\n";
	sendToS3($datasource, $bucketfullpath);
	}
	
	
sub backupMysql
	{
	my ($name, $frequency, $fulls) = @_;
	
	if($yday % $frequency != 0)
		{
		print "Skipping $name\n";
		next;
		}
	
	my $cycles = $fulls;
	my $cyclenum = ($yday / $frequency) % $cycles;
	
	my $bucketfullpath = "$bucket:MySQL/$name-$cyclenum";
	print "MySQL $name -> $bucketfullpath\n";
	
	if($name eq "all") { $name = "--all-databases"; }
	my $datasource = "mysqldump --opt $name";
	sendToS3($datasource, $bucketfullpath);
	}
	
	
sub backupSubversion
	{
	my ($name, $frequency, $fulls) = @_;
	
	if($yday % $frequency != 0)
		{
		print "Skipping $name\n";
		next;
		}
	
	my $cycles = $fulls;
	my $cyclenum = ($yday / $frequency) % $cycles;
	
	my $datasource = "svnadmin -q dump $name";
	my $bucketfullpath = "$bucket:$name-$cyclenum";
	
	print "Subversion $name -> $bucketfullpath\n";
	sendToS3($datasource, $bucketfullpath);
	}
	
		
sub backupSubversionDir
	{
	my ($name, $frequency, $fulls) = @_;
	
	if($yday % $frequency != 0)
		{
		print "Skipping $name\n";
		next;
		}
	
	# inspired by https://popov-cs.grid.cf.ac.uk/subversion/WeSC/scripts/svn_backup
	
	my $cycles = $fulls;
	my $cyclenum = ($yday / $frequency) % $cycles;
	
	opendir(DIR, $name);
	my @subdirs = readdir(DIR);
	closedir(DIR);

	foreach my $subdir (@subdirs) 
		{	
		`svnadmin verify $name/$subdir >& /dev/null`;
		if ($? == 0 )
			{
			my $datasource = "svnadmin -q dump $name/$subdir";
			my $bucketfullpath = "$bucket:$name/$subdir-$cyclenum";
			
			print "Subversion $name/$subdir -> $bucketfullpath\n";
			sendToS3($datasource, $bucketfullpath);
			}
		}
	}
	

sub sendToS3
	{
	my ($name $datasource,$bucketfullpath) = @_;
	
	if($opt{t})
		{
		print "$delete_from_s3 $bucketfullpath\n";
		print "$datasource | $encrypt | $send_to_s3 $bucketfullpath\n";
		}
	else
		{
		# delete the bucket if it exists
		`$delete_from_s3 $bucketfullpath`;
	
		if($? != 0)
			{
			print("Could not delete old backup: $!\n");
			}
		
		# stream the data
		`$datasource | $encrypt | $send_to_s3 $bucketfullpath`;
	
		if($? != 0)
			{
			print("Backup of $name failed: $!\n");
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

