#!/usr/bin/perl

# Version		:	v1.1
# Author		:	Jozef Legény
# Date			:	2013
# Support		:	contact@clockwork.fr
# Original URL	:	http://clockwork.fr/blazing-speed

# Permission is hereby granted to use, distribute and modify this program
# by anybody for any purpose. Attribution is welcome but not mandatory.
# For more details read the LICENSE file

use strict;
use feature ':5.16';
use Getopt::Long;
use LWP::Simple;
use Regexp::Common qw /net/;
use Switch;

my $o_port = 42000; # starting port, will use more
	'slices' => 3, # number of concurrent transfers
my $o_slices = 3; # number of concurrent transfers
my $o_minimumSize = 1024*1024; # if target file is smaller than this it will be simply copied by scp
my $o_blockSize = 512; # size of transferred blocks
my $o_myIP = 'auto'; # own public IP address
my $o_keepSession = 0; # keep temporary folder after the download is complete

GetOptions(
	'slices=i' => \$o_slices,
	'port=i' => \$o_port,
	'minimum-size=i' => \$o_minimumSize,
	'block-size=i' => \$o_blockSize,
	'own-address=s' => \$o_myIP,
	'keep-session!' => \$o_keepSession,
) or die "Error handling command line arguments";

# determine the own IP address if it was not specified

if ($o_myIP eq 'auto') {
	$o_myIP = get "http://tnx.nl/ip";
	say "Auto determined the public IP address as $o_myIP";
}

not $o_myIP =~ /$RE{net}{IPv4}/ and die "Can not determine own public address";

my $remoteHost = $ARGV[0];
my $remoteFile = $ARGV[1];
my $localFile = $ARGV[3];

say "usage $0 <user\@remoteHost> <remote file> [local file]" and die if scalar @ARGV < 2;

$remoteFile =~ /([^\/]+)$/; # get the filename part of the remote file

not $localFile and $localFile = $1; # if the local file was not specified use the remote file name

# print what we will actually do

say qq{Will connect to $remoteHost on port $o_port.};
say qq{Will fetch file "$remoteFile" as $o_slices parts and save it to "$localFile".};

# Check own platform

my $localPlatform = `uname`;
chomp $localPlatform;

# Check the remote platform

my $remotePlatform = `ssh "$remoteHost" 'uname'`;
chomp $remotePlatform;

# Check the file size

my $statCommand;

switch ($remotePlatform)
{
	case "Linux" { $statCommand = 'stat -c %s'; }
	case "Darwin" { $statCommand = 'stat -f %z'; }
}

my $fileSize = `ssh "$remoteHost" '$statCommand "$remoteFile"'`;
chomp $fileSize;


if (not ($fileSize =~ /^\d+$/ and $fileSize > 0)) { # file does not exist
	say "The remote file does not exist";
	die;
} 

say "The targets file size is $fileSize bytes.";

# fetch the file directly if it is too small to be split or the person requested a single split
if ($fileSize < $o_minimumSize or $o_slices < 2) {
	say "The file is too small, will use scp to fetch it";

	$remoteFile =~ s/ /\\ /g;
	`scp $remoteHost:"$remoteFile" "$localFile"`;
	exit 0;
}

# proceed to file splitting

# first calculate the sizes of the chunks
say "The file is large enough, it will be split like so:";

my $splitSizeInBlocks;

{
	use integer;
	$splitSizeInBlocks = $fileSize / $o_blockSize / $o_slices;
}

for (1 .. $o_slices - 1)
{
	say "Slice	$_ :		$splitSizeInBlocks blocks of		$o_blockSize for a total of		", $splitSizeInBlocks * $o_blockSize, " bytes";
}

say "Slice	$o_slices :		will contain remainder of the file thus 		", $fileSize - ($splitSizeInBlocks * $o_blockSize * ($o_slices - 1)), " bytes";

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

# listening has started, request server to send data

my $current_block = 0;

for (my $index_command = 0; $index_command < $o_slices; $index_command++) {
	my $current_port = $o_port + $index_command;
	say "Will request slice $index_command on port $current_port";
	
	my $countCommand = $index_command != $o_slices - 1 ? "count=$splitSizeInBlocks" : "";

	my $netcatRequestCommand = qq{ssh $remoteHost 'dd ibs=$o_blockSize if="$remoteFile" skip=$current_block $countCommand | nc -w 1 $o_myIP $current_port'};

	say "$netcatRequestCommand";
	`$netcatRequestCommand > /dev/null &`;

	say "Requested slice $index_command";

	$current_block += $splitSizeInBlocks;
}

# wait for children to finish

foreach (@receivingChildren) {
	my $tmp = waitpid($_, 0);
	# say "Joined child with pid $tmp has finished downloading";
}

say "Everything received, joining splits into the final destination";

for (my $index_file = 0; $index_file < $o_slices; $index_file++)
{
	my $joinCommand = qq{dd if="$tempDownloadFolder/slice-$index_file.part" bs=$o_blockSize of="$localFile"};

	switch($localPlatform)
	{
		case /Linux/ { $index_file > 0 and $joinCommand .= " oflag=append conv=notrunc"; }
		case /Darwin/ { $index_file > 0 and $joinCommand .= " seek=" . $index_file * $splitSizeInBlocks; }
	}

	say "$joinCommand";
	`$joinCommand`;
}

# clean the temporary directory
unless ($o_keepSession) {
	say "Removing temporary directory";
	for (0..$o_slices)
	{
		unlink "$tempDownloadFolder/slice-$_.part";
	}
	rmdir $tempDownloadFolder;
}

say "Done";

sub startListeningForSlice($$) {
	my $sliceToDownload = shift;
	my $tempDownloadFolder = shift;
	my $currentPort = $o_port + $sliceToDownload;
	say "  [$sliceToDownload] Listening for slice $sliceToDownload on port ", $currentPort;

	my $netcatListenCommand;

	switch ($localPlatform)
	{
		case /Linux/ {  $netcatListenCommand = qq{nc -l -p $currentPort > "$tempDownloadFolder/slice-$sliceToDownload.part" };  }
		case /Darwin/ { $netcatListenCommand = qq{nc -H 10 -l > "$tempDownloadFolder/slice-$sliceToDownload.part" $currentPort};  }
	}

	`$netcatListenCommand`;

	say "  [$sliceToDownload] Download of slice $sliceToDownload has finished";
	return $sliceToDownload;
}

