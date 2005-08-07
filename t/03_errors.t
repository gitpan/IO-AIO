#!/usr/bin/perl

use Fcntl;
use Test;
use POSIX qw(ENOENT EACCES EBADF);
use FindBin;
use lib "$FindBin::Bin";
use aio_test_common;

BEGIN { plan tests => 9 }

IO::AIO::min_parallel 2;

my $tempdir = tempdir();

my $some_dir  = "$tempdir/some_dir/";
my $some_file = "$some_dir/some_file";

# create a file in a non-existent directory
aio_open $some_file, O_RDWR|O_CREAT|O_TRUNC, 0, sub {
    ok((!defined $_[0]) && $! == ENOENT);
};
pcb;

# now actually make that file
ok(mkdir $some_dir);
aio_open $some_file, O_RDWR|O_CREAT|O_TRUNC, 0644, sub {
    my $fh = shift;
    ok(defined $fh);
    print $fh "contents.";
    close $fh;
    ok(-e $some_file);
};
pcb;

# test error on unlinking non-empty directory
aio_unlink "$some_dir/notfound.txt", sub {
    ok($_[0] < 0);
    ok($! == ENOENT);
};
pcb;

# write to file open for reading
ok(open(F, $some_file)) or die $!;
aio_write *F, 0, 10, "foobarbaz.", 0, sub {
    my $written = shift;
    ok($written < 0);
    ok($! == EBADF);
};




