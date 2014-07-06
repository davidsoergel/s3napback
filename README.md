s3napback
=========

_Cycling, Incremental, Compressed, Encrypted Backups to Amazon S3_

 * Dead-simple configuration
 * Automatic rotation of backup sets
 * Optional decaying backup schedule (thanks to Scott Squires)
 * Alternation of full and incremental backups (using "tar -g")
 * Integrated GPG encryption
 * No temporary files used anywhere, only pipes and TCP streams (optionally, uses smallish temp files to save memory)
 * Integrated handling of MySQL dumps
 * Integrated handling of PostgreSQL dumps (thanks to Scott Squires)
 * Integrated handling of Subversion repositories, and of directories containing multiple Subversion repositories (including incremental backups-- thanks to Kevin Ross).

s3napback is basically a convenience wrapper around [js3tream](http://js3tream.sourceforge.net/), and is at least partly inspired by the [snapback2](http://www.perusion.com/misc/Snapback2/) script (which is still a great solution for incremental rsync-based backups to your own disks).


Manual
======

 * [Introduction](#introduction)
 * [Quick Start](#quick-start)
 * [wiki:PrinciplesOfOperation Principles of Operation]
 * [wiki:ConfigurationOptions Configuration Options]
 * [wiki:Recovery Recovery]
 * [wiki:FutureImprovements Future Improvements]


Introduction
------------

In searching for a way to back up one of my Linux boxes to Amazon S3, I was surprised to find that none of the many backup methods and scripts I found on the net did what I wanted, so I wrote yet another one.

The design requirements were:

 * Occasional full backups, and daily incremental backups
 * Stream data to S3, rather than making a local temp file first (i.e., if I want to archive all of /home at once, there's no point in making huge local tarball, doing lots of disk access in the process)
 * Break up large archives into manageable chunks
 * Encryption

As far as I could tell, no available backup script (including, e.g. s3sync, backup-manager, s3backup, etc. etc.) met all four requirements.

The closest thing is [js3tream](http://js3tream.sourceforge.net), which handles streaming and splitting, but not incrementalness or encryption.  Those are both fairly easy to add, though, using tar and gpg, as [suggested](http://js3tream.sourceforge.net/linux_tar.html) by the js3tream author.  However, the s3backup.sh script he provides uses temp files (unnecessarily), and does not encrypt.  So I modified it a bit to produce [s3backup-gpg-streaming.sh](source:trunk/s3backup-gpg-streaming.sh).

That's not the end of the story, though, since it leaves open the problem of managing the backup rotation.  I found the explicit cron jobs suggested on the js3tream site too messy, especially since I sometimes want to back up a lot of different directories.  Some other available solutions will send incremental backups to S3, but never purge the old ones, and so use ever more storage.

Finally, I wanted to easily deal with MySQL and Subversion dumps.

Quick Start
===========

Clone this repo, or [download](https://github.com/davidsoergel/s3napback/archive/master.zip) and extract the s3napback package.  There's no "make" or any such needed, so just extract it to some convenient location (I use /usr/local/s3napback).

Prerequisites
-------------

 * Java 1.5 or above.  Note that you must use the standard Sun JDK (or JRE); libgcj will not work.  (The s3napback script just executes whatever "java" it finds in the path, so you may need to adjust your path so that the Sun java takes precedence.  On some systems there are symlinks in /etc/alternatives that point at one version or the other.)

 * gpg (if you want encryption)

 * Date::Format
 * Config::ApacheFormat
 * Log::Log4Perl

On many systems you can install the latter three packages from the command line like this:
```
sudo cpan Date::Format Config::ApacheFormat Log::Log4perl
```


S3 configuration
----------------

Configure s3napback with your S3 login information by creating a file called e.g. /usr/local/s3napback/key.txt containing
```
key=your AWS key
secret=your AWS secret
```
You probably want to take care that this file is readable only by the user that s3napback will be running as, so `chown` and `chmod 600` it, as appropriate.

GPG configuration
-----------------

_Note: if you don't care about encryption, you can skip this section, and simply don't specify a GpgRecipient in the configuration file below._

You'll need a GPG key pair for encryption.  Create it with
```
gpg --gen-key
```
Since you'll need the secret key to decrypt your backups, you'll obviously need to store it in a safe place (see [the GPG manual](http://www.gnupg.org/gph/en/manual/c481.html)).

If you'll be backing up a different machine from the one where you generated the key pair, export the public key:
```
gpg --export me@example.com > backup.pubkey
```
and import it on the machine to be backed up:
```
gpg --import backup.pubkey
gpg --edit-key backup@example.com
```

then (in the gpg key editing interface), "trust" the key.

If you want to run s3napback as root (e.g., from cron), you'll want to make sure that the right gpg keyring is used.  Gpg will look for a keyring under ~/.gnupg, but on some systems /etc/crontab sets the HOME environment variable to "/"; consequently during the cron job gpg may look in /.gnupg instead of /root/.gnupg.  Thus, you may want to change /etc/crontab to set HOME to "/root"; or actually create and populate /.gnupg; or just use the GpgKeyring option in the s3napback config file to specify a keyring explicitly.

Defining backup sets
--------------------

Create a configuration file something like this (descriptions of the options are [wiki:ConfigurationOptions here], if they're not entirely obvious):
```
DiffDir /usr/local/s3napback/diffs
Bucket dev.davidsoergel.com.backup1
GpgRecipient backup@davidsoergel.com
S3Keyfile /usr/local/s3napback/key.txt
ChunkSize 25000000

# make diffs of these every day, store fulls once a week, and keep two weeks
<Cycle daily-example>
	#CycleType SimpleCycle  # this is the default
	Frequency 1
	Diffs 6
	Fulls 2

	Directory /etc
	Directory /home/build
	Directory /home/notebook
	Directory /home/trac
	Directory /usr
	Directory /var
</Cycle>

# make full backups of these every day on a decaying schedule.
# Keep a total of five backups, spread out such that the oldest
# backup is between 8 and 16 days old.  Each additional disc 
# increases the age of the oldest backup by a factor of two.
<Cycle decaying-example>
	CycleType HanoiCycle
	Frequency 1
	Discs 5

	Directory /etc
	Directory /home/build
	Directory /home/notebook
	Directory /home/trac
	Directory /usr
	Directory /var
</Cycle>

# make diffs of these every week, store fulls once a month, and keep two months
<Cycle weekly-example>
	Frequency 7
	Diffs 3
	Fulls 2

	Directory /bin
	Directory /boot
	Directory /lib
	Directory /lib64
	Directory /opt
	Exclude /opt/useless
	Directory /root
	Directory /sbin
</Cycle>

# make a diff of this every day, store fulls once a week, and keep eight weeks
<Directory /home/foobar>
	Frequency 1
	Diffs 6
	Fulls 8

	Exclude /home/foobar/wumpus
</Directory>

# backup an entire machine
<Directory />
	Frequency 1
	Diffs 6
	Fulls 8

	Exclude /proc
	Exclude /dev
	Exclude /sys
	Exclude /tmp
	Exclude /var/run
</Directory>

# store a MySQL dump of all databases every day, keeping 14.
<MySQL all>
	Frequency 1
	Fulls 14
</MySQL>

# store a MySQL dump of a specific database every day, keeping 14.
<MySQL mydatabase>
	Frequency 1
	Fulls 14
</MySQL>

# store a full dump of all Subversion repos every day, keeping 10.
<SubversionDir /home/svn/repos>
	Frequency 1
	Fulls 10
</SubversionDir>

# store a diff of a specific Subversion repo every day, with a full dump every fourth day, keeping 10 fulls.
<Subversion /home/svn/repos/myproject>
 	Frequency 1
	Phase 0
	Diffs 3
	Fulls 10
</Subversion>
```

Run the backup
--------------

To run it, just run the script, passing the config file with the -c option:
```
./s3snapback.pl -c s3napback.conf
```
That's it!  You can put that command in a cron job to run once a day.

Logging
-------

The log destinations and formatting are specified in s3napback.logconfig included in the package archive.  Log
rotation and emailing work too as long as you install Log::Dispatch (`sudo cpan Log::Dispatch`)
and Mail::Sender (`sudo cpan Mail::Sender`), as needed.


Principles of operation
=======================

There are two available "cycle types" that govern the timing and order of overwriting old backups: a "Simple" cycle that keeps backups at fixed intervals, and a "Hanoi" cycle that keeps backups on a decaying schedule.  Only the Simple cycle allows incremental backups.

SimpleCycle
-----------

The cycling of backup sets here is rudimentary, taking its inspiration from the [cron job approach](http://js3tream.sourceforge.net/linux_tar.html) given on the js3tream page.  The principle is that we'll sort the snapshots into a fixed number of "slots"; every new backup simply overwrites the oldest slot, so we don't need to explicitly purge old files.

This is a fairly crappy schedule, in that the rotation doesn't decay over time.  We just keep a certain number of daily backups (full or diff), and that's it.

Note also that the present scheme means that, once the oldest full backup is deleted, the diffs based on it will still be stored until they are overwritten, but may not be all that useful.  For instance, if you do daily diffs and weekly fulls for two weeks, then at some point you'll go from this situation, where you can reconstruct your data for any day from the last two weeks (F = full, D = diff, time flowing to the right):
```
FDDDDDDFDDDDDD
```
to this one:
```
 DDDDDDFDDDDDDF
```
where the full backup on which the six oldest diffs are based is gone, so in fact you can only fully reconstruct the last 8 days.  You can still retrieve files that changed on the days represented by the old diffs, of course.


HanoiCycle
----------

The decaying properties of the Hanoi schedule are excellently described [elsewhere](http://www.alvechurchdata.co.uk/softhanoi.htm).  Briefly: full backups are made every day, but are overwritten in an order that results in ages distributed as powers of two, e.g. 1, 2, 4, 8, and 16 days old (etc.).


Command Line Options
====================

`-c <filename>`
  path to the configuration file
  
`-t`
  test mode; report what would be done, but don't actually do anything
  
`-f`
  force backup even if it has already been done today (use with caution; this may overwrite the current diff and thereby lose data)
  
`-d`
  print debug messages


Configuration Options
=====================

_First off you'll need some general configuration statements:_

`DiffDir`
  a directory where tar can store its diff files (necessary for incremental backups).

`TempDir`
  to store MySQL dumps or other content that can't be streamed to S3 without risking timeouts. Only matters if UseTempFile is set.

`Bucket`
  the destination bucket on S3.

`GpgRecipient`
  the address of the public key to use for encryption.  The gpg keyring of the user you're running the script as (i.e., root, for a systemwide cron job) must contain a matching key.  If this option is not specified, no encryption is performed.

`GpgKeyring`
  path to the keyring file containing the public key for the GpgRecipient.  Defaults to ~/.gnupg/pubring.gpg

`S3KeyFile`
  the file containing your AWS authentication keys.

`ChunkSize`
  the size of the chunks to be stored on S3, in bytes.

_Then you can specify as many directories, databases, and repositories as you like to be backed up.  These may be contained in <Cycle> blocks, for the sake of reusing timing configuration, or may be blocks themselves with individual timings._

`<Cycle name>`
  <name>: a unique identifier for the cycle.  This is not used except to establish the uniqueness of each block.

`CycleType`
  Use "SimpleCycle" (default) to make backups at regular intervals (e.g., every day) with no decaying behavior.  Use "HanoiCycle" for a decaying schedule, i.e. to store a few old backups and a lot of recent ones (thanks to Scott Squires for implementing HanoiCycle).

`Frequency` (when using either cycle type):
  how often a backup should be made at all, in days.

`Phase` _(when using SimpleCycle only)_:
  Allows adjusting the day on which the backup is made, with respect to the frequency.  Can take values 0 <= Phase < Frequency; defaults to 0.  This can be useful, for instance, if you want to alternate daily backups between two backup sets.  This can be accomplished by creating two nearly identical backup specifications, both with Frequency 2, but where one has a Phase of 0 and the other has a Phase of 1.

`Diffs` _(when using SimpleCycle only)_:
  tells how many incremental backups to make between full backups.  E.g., if you want daily diffs and weekly fulls, set this to 6.

`Fulls` _(when using SimpleCycle only)_:
  tells how many total cycles to keep.  This should be at least 2.  With only one slot, you'd have no protection while a backup is running, since the old contents of the slot are deleted before the new contents are written.

`Discs` _(when using HanoiCycle only)_:
  The number of full backups to keep on a decaying schedule (e.g., setting this to 4 should provide backups that are one day, two days, four days, and eight days old, more or less depending on the current day relative to the Hanoi rotation).  Managing incremental backups on a decaying cycle would be very messy, so all backups using the Hanoi cycle are full backups, not diffs.

`ArchiveOldestDisc` _(when using HanoiCycle only) (default false)_:
  If all the slots specified by the Discs parameter are in use and the new backup would overwrite the oldest slot, keep an archive copy of the oldest backup.  For example, with 5 discs, this would result in having recent backups of 1, 2, 4, and 8 days ago, and archived backups every 16 days (16, 32, 48, etc. days ago).  Using an analogy to backup tapes, this is like removing the tape with your oldest backup after each full cycle, putting it into storage, and adding a fresh tape into the rotation.

  This causes the total volume of backup data to grow indefinitely.  Depending on your needs, it may make sense to use a fairly large number of discs, so as to keep a few very old backups while rarely triggering the archival condition.

`Directory <name>`    or    `<Directory name>`:
  `<name>` a directory to be backed up.
  May appear as a property within a cycle block, or as a block in its own right, e.g. `<Directory /some/path>`.  The latter case is just a shorthand for a cycle block containing a single Directory property.

`MySQL <databasename>`    or    `<MySQL databasename>`
  In order for this to work, the user you're running the script as must be able to mysqldump the requested databases without entering a password.  This can be accomplished through the use of a .my.cnf file in the user's home directory.
  `<databasename>` names a single database to be backed up, or "all" to dump all databases.
  The Diffs property is ignored, since MySQL dumps are always "full".

`PostgreSQL <databasename>`    or    `<PostgreSQL databasename>`
  In order for this to work, the user you're running the script as must be able to pg_dump the requested databases without entering a password.  This can be accomplished through the use of a .pgpass file in the user's home directory.
  `<databasename>` names a single database to be backed up, or "all" to dump all databases.
  The Diffs property is ignored, since PostgreSQL dumps are always "full".

`Subversion <repository>`    or    `<Subversion repository>`
  In order for this to work, the user you're running the script as must have permission to svnadmin dump the requested repository.
  `<repository>` names a single svn repository to be backed up.  Incremental backups are handled by storing the latest backed-up revision number in a file under `DiffDir`.  As elsewhere, setting `Diffs` to 0 (or just leaving it out) results in a full dump every time.  (Thanks to Kevin Ross for adding the incremental behavior here). 

`SubversionDir <repository-dir>`    or    `<SubversionDir repository-dir>`:
  `<repository-dir>` a directory containing multiple subversion repositories, all of which should be backed up.
  (this feature was inspired by http://www.hlynes.com/2006/10/01/backups-part-2-subversion)

`UseTempFile`
  Causes the data to be backed up to be dumped to a local file before being streamed to S3. Set to 0 or 1.  This is most useful in a MySQL block, because the slow upload speed to S3 can cause mysqldump to time out when dumping large tables.  Letting mysqldump write to a temp file before uploading it obviously avoids this problem.  An alternate solution is to set long mysqld timeouts in my.cnf:
```
net_read_timeout=3600
net_write_timeout=3600
```
That may be the right solution for some circumstances, e.g. if the databases are larger than the available scratch disk.  The UseTempFile configuration will work for regular filesystem backups and Subversion backups as well, at the cost of (temporary) disk space and more disk activity.

Recovery
========

Recovery is not automated, but if you need it, you'll be motivated to follow this simple manual process.

To retrieve a backup, use js3tream to download the files you need, then decrypt them with GPG, then extract the tarballs.  Always start with the most recent FULL backup, then apply all available diffs in date order, regardless of the slot number.

The procedure will be something along these lines:
```
java -jar js3tream.jar --debug -n -f -v -K $s3keyfile -o -b $bucket:$name | gpg -d | tar xvz
```
Note that because of the streaming nature of all this, you can extract part of an archive even if there's not enough disk space to store the entire archive.  You'll still have to download the whole thing, unfortunately (throwing most of it away without writing to disk), since it's only at the tar stage that you can select which files will be restored.
```
java -jar js3tream.jar --debug -n -f -v -K $s3keyfile -o -b $bucket:$name | gpg -d | tar xvz /path/to/desired/file
```


The name of the file you want ("$name" above) has the slot number and the type (FULL or DIFF) appended to it before being sent to S3.  So it likely has a name like 
`mybucket:/some/path-5-FULL` or some such.

The easiest way to figure out which one you want is to use an S3 browsing program to see what files are actually in your bucket (I've used S3browser and S3hub on the Mac; I don't recommend the s3fox Firefox extension because it gets confused by leading slashes on the filenames).  

If there are multiple versions in different slot numbers, look at the dates to figure out which one you want.  The usage of the numbers wraps around, so higher numbers are not necessarily more recent.  This is especially true for the Hanoi rotation, in which the relationship between slot numbers and dates is entirely scrambled.

js3tream breaks the files into chunks, and appends the chunk number after a colon.  So your bucket will have something looking like `mybucket:/some//path-5-FULL:0000000000000`, or maybe a series of these if there are multiple chunks.  Of course js3tream knows how to re-join the chunks, so just give it the part before the colon.

Finally note that the resulting file is in fact a tar file (or the gpg-encrypted version of that, if enabled), though it may not automatically get a .tar extension.


Future Improvements
===================

 * S3 uploads could be done in parallel, since that can speed things up a lot
 * Recovery could be automated
 * It's always possible to make the code cleaner, improve error handling, etc.

This is just a quick summary of the biggest outstanding issues; please have a look at the issue tracker for more detail or to leave comments.

Please [let me know](mailto:dev@davidsoergel.com) if you make these or any other improvements!