#!/usr/bin/perl

# Version		:	v1.999
# Author		:	Jozef Legény
# Date			:	2013
# Support		:	contact@clockwork.fr
# Original URL	:	http://clockwork.fr/blazing-speed

# Permission is hereby granted to use, distribute and modify this program
# by anybody for any purpose. Attribution is welcome but not mandatory.
# For more details read the LICENSE file

use strict;
no warnings 'experimental::smartmatch';
use feature ':5.18';
use feature 'switch';
use Getopt::Long;
use LWP::Simple;
use Regexp::Common qw /net/;
use Term::ProgressBar;
use Term::ReadKey;

my $o_port = 42000; # starting port, will use more
my $o_slices = 3; # number of concurrent transfers
my $o_minimumSize = 1024*1024; # if target file is smaller than this it will be simply copied by scp
my $o_blockSize = 512; # size of transferred blocks
my $o_myIP = 'auto'; # own public IP address
my $o_keepSession = 0; # keep temporary folder after the download is complete
my $o_verbose = 0; # display verboe log
my $o_password = 0; # ask for password

GetOptions(
	'slices=i' => \$o_slices,
	'port=i' => \$o_port,
	'minimum-size=i' => \$o_minimumSize,
	'block-size=i' => \$o_blockSize,
	'own-address=s' => \$o_myIP,
	'keep-session!' => \$o_keepSession,
	'verbose!' => \$o_verbose,
	'password!' => \$o_password
) or die "Error handling command line arguments";

# determine the own IP address if it was not specified

if ($o_myIP eq 'auto') {
	$o_myIP = get "http://tnx.nl/ip";
	say "Auto determined the public IP address as $o_myIP" if $o_verbose;
}

not $o_myIP =~ /$RE{net}{IPv4}/ and die "Can not determine own public address";

my $remoteHost = $ARGV[0];
my $remoteFile = $ARGV[1];
my $localFile = $ARGV[2];

say "usage $0 <user\@remoteHost> <remote file> [local file]" and die if scalar @ARGV < 2;

$remoteFile =~ /([^\/]+)$/; # get the filename part of the remote file

not $localFile and $localFile = $1; # if the local file was not specified use the remote file name

# ask for password if necessary
my $remotePassword;

if ($o_password) {
	ReadMode('noecho');
	$remotePassword = ReadLine(0);
}

say "Your typed password was '$remotePassword'";



# print what we will actually do
say qq{Will connect to $remoteHost on port $o_port.} if $o_verbose;
say qq{Will fetch file "$remoteFile" as $o_slices parts and save it to "$localFile".} if $o_verbose;

# Check own platform
my $localPlatform = `uname`;
chomp $localPlatform;

# Check the remote platform
my $remotePlatform = `ssh "$remoteHost" 'uname'`;
chomp $remotePlatform;

# Check the file size
my $remoteStatCommand;

given ($remotePlatform)
{
	when ("Linux") { $remoteStatCommand = 'stat -c %s'; }
	when ("Darwin") { $remoteStatCommand = 'stat -f %z'; }
}

my $fileSize = `ssh "$remoteHost" '$remoteStatCommand "$remoteFile"'`;
chomp $fileSize;


if (not ($fileSize =~ /^\d+$/ and $fileSize > 0)) { # file does not exist
	die "The remote file does not exist";
} 

say "The targets file size is $fileSize bytes." if $o_verbose;

# fetch the file directly if it is too small to be split or the person requested a single split
if ($fileSize < $o_minimumSize or $o_slices < 2) {
	say "The file is too small, will use scp to fetch it" if $o_verbose;

	$remoteFile =~ s/ /\\ /g;
	`scp $remoteHost:"$remoteFile" "$localFile"`;
	exit 0;
}

# proceed to file splitting

# first calculate the sizes of the chunks
say "The file is large enough, it will be split like so:" if $o_verbose;

my $splitSizeInBlocks;

{
	use integer;
	$splitSizeInBlocks = $fileSize / $o_blockSize / $o_slices;
}

for (1 .. $o_slices - 1)
{
	say "Slice	$_ :		$splitSizeInBlocks blocks of		$o_blockSize for a total of		", $splitSizeInBlocks * $o_blockSize, " bytes" if $o_verbose;
}

say "Slice	$o_slices :		will contain remainder of the file thus 		", $fileSize - ($splitSizeInBlocks * $o_blockSize * ($o_slices - 1)), " bytes" if $o_verbose;

# create a temporary directory

my $tempDownloadFolder = "/tmp/bs-$$";

mkdir $tempDownloadFolder;

my @receivingChildren;

# create all child processes and start listening for incoming data
for (my $index_child = 0; $index_child < $o_slices; $index_child++) {

	my $current_pid = fork();

	if ($current_pid) {
		push @receivingChildren, $current_pid;
	}
	elsif ($current_pid == 0) {
		startListeningForSlice($index_child, $tempDownloadFolder);
		exit 0;
	}
	else {
		die "Could not fork: $!\n";
	}
}

my $progressChild;
# create a process for calculating progress
{
	my $current_pid = fork();

	if ($current_pid) {
		$progressChild = $current_pid;
	}
	elsif ($current_pid == 0) {
		startCalculatingProgress($tempDownloadFolder);
		exit 0;
	}
	else {
		die "Could not fork: $!\n";
	}
}

# listening has started, request server to send data

my $current_block = 0;

for (my $index_command = 0; $index_command < $o_slices; $index_command++) {
	my $current_port = $o_port + $index_command;
	say "Will request slice $index_command on port $current_port" if $o_verbose;
	
	my $countCommand = $index_command != $o_slices - 1 ? "count=$splitSizeInBlocks" : "";

	my $netcatRequestCommand = qq{ssh $remoteHost 'dd ibs=$o_blockSize if="$remoteFile" skip=$current_block $countCommand | nc -w 1 $o_myIP $current_port'};

	say "> $netcatRequestCommand" if $o_verbose;
	`nohup $netcatRequestCommand > /dev/null &`;

	say "Requested slice $index_command" if $o_verbose;

	$current_block += $splitSizeInBlocks;
}

# wait for children to finish
foreach (@receivingChildren) {
	my $tmp = waitpid($_, 0);
	# say "Joined child with pid $tmp has finished downloading";
}

# wait for progressbar to finish

say "Everything received, joining splits into the final destination" if $o_verbose;

for (my $index_file = 0; $index_file < $o_slices; $index_file++)
{
	my $joinCommand = qq{dd if="$tempDownloadFolder/slice-$index_file.part" bs=$o_blockSize of="$localFile"};

	given($localPlatform)
	{
	  when (/Linux/) { $index_file > 0 and $joinCommand .= " oflag=append conv=notrunc"; }
		when (/Darwin/) { $index_file > 0 and $joinCommand .= " seek=" . $index_file * $splitSizeInBlocks; }
	}

	say "> $joinCommand" if $o_verbose;
	`nohup $joinCommand`;
}
say "Slices have been joined in the target file" if $o_verbose;

# clean the temporary directory
unless ($o_keepSession) {
	say "Removing temporary directory";
	for (0..$o_slices)
	{
		unlink "$tempDownloadFolder/slice-$_.part";
	}

	say "Removing temporary directory" if $o_verbose;
	rmdir $tempDownloadFolder;
}

waitpid($progressChild, 0);
say "Done" if $o_verbose;

sub startListeningForSlice($$) {
	my $sliceToDownload = shift;
	my $tempDownloadFolder = shift;
	my $currentPort = $o_port + $sliceToDownload;
	say "  [$sliceToDownload] Listening for slice $sliceToDownload on port ", $currentPort if $o_verbose;

	my $netcatListenCommand;

	given ($localPlatform)
	{
		when (/Linux/) {  $netcatListenCommand = qq{nc -l -p $currentPort > "$tempDownloadFolder/slice-$sliceToDownload.part" };  }
		when (/Darwin/) { $netcatListenCommand = qq{nc -H 10 -l > "$tempDownloadFolder/slice-$sliceToDownload.part" $currentPort};  }
	}

	`nohup $netcatListenCommand`;

	say "  [$sliceToDownload] Download of slice $sliceToDownload has finished" if $o_verbose;
	return $sliceToDownload;
}

sub startCalculatingProgress($) {
	local $| = 1;
	my $tempDownloadFolder = shift;
	say "Starting the progressbar";
	my $progress = Term::ProgressBar->new({
			name => 'Downloaded',
			count => $fileSize,
			ETA => 'linear',
		});
	$progress->max_update_rate(1);
	my $next_update = 0;

	my $localStatCommand;

	given ($localPlatform)
	{
		when ("Linux") { $localStatCommand = 'stat -c %s'; }
		when ("Darwin") { $localStatCommand = 'stat -f %z'; }
	}


	while (-e $tempDownloadFolder) {
		my $dataDownloadedSoFar = 0;
		for (0..$o_slices) {
			if (-e "$tempDownloadFolder/slice-$_.part")
			{
				my $currentSliceSize = `$localStatCommand "$tempDownloadFolder/slice-$_.part"`;
				$dataDownloadedSoFar += $currentSliceSize;

				my $currentSliceCompleteSize;
				if ($_ < $o_slices - 1) {
					$currentSliceCompleteSize = $splitSizeInBlocks * $o_blockSize;
				}
				else {
					$currentSliceCompleteSize = $fileSize - ($splitSizeInBlocks * $o_blockSize * ($o_slices - 1));
				}

				my $percentComplete = $currentSliceSize / $currentSliceCompleteSize;
				#print "slice $_: $percentComplete\n";
				#$progress->message($percentComplete);
			}
			$next_update = $progress->update($dataDownloadedSoFar) if $dataDownloadedSoFar > $next_update;
		}
		sleep 1;
	}

	$progress->update($fileSize) if $fileSize >= $next_update;

}
