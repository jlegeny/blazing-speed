# Blazing Speed

Fast SSH/netcat downloader for Mac and Linux.

Blazing Speed is a multi-process downloader using _SSH_ and _netcat_ to download a single file through several pipes separated in separate processes.

## Disclaimers

Blazing Speed uses the [tnx.nl public IP detection](http://tnx.nl/ip) to work. If you do not wish to ping this website, use the **--own-address** parameter. 

## Usage 

Syntax of command is:

`blazing-speed.pl [options] <remote_user@remote_host> <remote_file> [local_file]`

### Command line options

**-s, --slices \<number of slices>**
Number of equal size slices the file will be split into. Each slice will be downloaded by a separate process.

**-p, --port \<port number>**
Port over which to transfer data. This port will be used for the first download, the second one will use port +1, third one +2 etc.

**-m, --minimum-size \<size in bytes>**
Minimum size of a file to download via slicing. If the remote file is smaller that this size _scp_ program will be used to get if from the server.

**-b, --block-size \<size in bytes>**
Size of blocks transferred at one time by _nc_.

**-o, --own-address \<IP address>**
Your own public IP address in _xxx.xxx.xxx.xxx_ format. You can precise _auto_ for the address to be auto-determined.

**-k, --keep-session**
If this option is specified the temporary directory inside `/tmp` will not be deleted.

