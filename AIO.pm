=head1 NAME

IO::AIO - Asynchronous Input/Output

=head1 SYNOPSIS

 use IO::AIO;

 aio_open "/etc/passwd", IO::AIO::O_RDONLY, 0, sub {
    my $fh = shift
       or die "/etc/passwd: $!";
    ...
 };

 aio_unlink "/tmp/file", sub { };

 aio_read $fh, 30000, 1024, $buffer, 0, sub {
    $_[0] > 0 or die "read error: $!";
 };

 # version 2+ has request and group objects
 use IO::AIO 2;

 aioreq_pri 4; # give next request a very high priority
 my $req = aio_unlink "/tmp/file", sub { };
 $req->cancel; # cancel request if still in queue

 my $grp = aio_group sub { print "all stats done\n" };
 add $grp aio_stat "..." for ...;

=head1 DESCRIPTION

This module implements asynchronous I/O using whatever means your
operating system supports. It is implemented as an interface to C<libeio>
(L<http://software.schmorp.de/pkg/libeio.html>).

Asynchronous means that operations that can normally block your program
(e.g. reading from disk) will be done asynchronously: the operation
will still block, but you can do something else in the meantime. This
is extremely useful for programs that need to stay interactive even
when doing heavy I/O (GUI programs, high performance network servers
etc.), but can also be used to easily do operations in parallel that are
normally done sequentially, e.g. stat'ing many files, which is much faster
on a RAID volume or over NFS when you do a number of stat operations
concurrently.

While most of this works on all types of file descriptors (for
example sockets), using these functions on file descriptors that
support nonblocking operation (again, sockets, pipes etc.) is
very inefficient. Use an event loop for that (such as the L<EV>
module): IO::AIO will naturally fit into such an event loop itself.

In this version, a number of threads are started that execute your
requests and signal their completion. You don't need thread support
in perl, and the threads created by this module will not be visible
to perl. In the future, this module might make use of the native aio
functions available on many operating systems. However, they are often
not well-supported or restricted (GNU/Linux doesn't allow them on normal
files currently, for example), and they would only support aio_read and
aio_write, so the remaining functionality would have to be implemented
using threads anyway.

Although the module will work in the presence of other (Perl-) threads,
it is currently not reentrant in any way, so use appropriate locking
yourself, always call C<poll_cb> from within the same thread, or never
call C<poll_cb> (or other C<aio_> functions) recursively.

=head2 EXAMPLE

This is a simple example that uses the EV module and loads
F</etc/passwd> asynchronously:

   use EV;
   use IO::AIO;

   # register the IO::AIO callback with EV
   my $aio_w = EV::io IO::AIO::poll_fileno, EV::READ, \&IO::AIO::poll_cb;

   # queue the request to open /etc/passwd
   aio_open "/etc/passwd", IO::AIO::O_RDONLY, 0, sub {
      my $fh = shift
         or die "error while opening: $!";

      # stat'ing filehandles is generally non-blocking
      my $size = -s $fh;

      # queue a request to read the file
      my $contents;
      aio_read $fh, 0, $size, $contents, 0, sub {
         $_[0] == $size
            or die "short read: $!";

         close $fh;

         # file contents now in $contents
         print $contents;

         # exit event loop and program
         EV::unloop;
      };
   };

   # possibly queue up other requests, or open GUI windows,
   # check for sockets etc. etc.

   # process events as long as there are some:
   EV::loop;

=head1 REQUEST ANATOMY AND LIFETIME

Every C<aio_*> function creates a request. which is a C data structure not
directly visible to Perl.

If called in non-void context, every request function returns a Perl
object representing the request. In void context, nothing is returned,
which saves a bit of memory.

The perl object is a fairly standard ref-to-hash object. The hash contents
are not used by IO::AIO so you are free to store anything you like in it.

During their existance, aio requests travel through the following states,
in order:

=over 4

=item ready

Immediately after a request is created it is put into the ready state,
waiting for a thread to execute it.

=item execute

A thread has accepted the request for processing and is currently
executing it (e.g. blocking in read).

=item pending

The request has been executed and is waiting for result processing.

While request submission and execution is fully asynchronous, result
processing is not and relies on the perl interpreter calling C<poll_cb>
(or another function with the same effect).

=item result

The request results are processed synchronously by C<poll_cb>.

The C<poll_cb> function will process all outstanding aio requests by
calling their callbacks, freeing memory associated with them and managing
any groups they are contained in.

=item done

Request has reached the end of its lifetime and holds no resources anymore
(except possibly for the Perl object, but its connection to the actual
aio request is severed and calling its methods will either do nothing or
result in a runtime error).

=back

=cut

package IO::AIO;

use Carp ();

use common::sense;

use base 'Exporter';

BEGIN {
   our $VERSION = 4.31;

   our @AIO_REQ = qw(aio_sendfile aio_seek aio_read aio_write aio_open aio_close
                     aio_stat aio_lstat aio_unlink aio_rmdir aio_readdir aio_readdirx
                     aio_scandir aio_symlink aio_readlink aio_realpath aio_sync
                     aio_fsync aio_syncfs aio_fdatasync aio_sync_file_range aio_allocate
                     aio_pathsync aio_readahead aio_fiemap
                     aio_rename aio_link aio_move aio_copy aio_group
                     aio_nop aio_mknod aio_load aio_rmtree aio_mkdir aio_chown
                     aio_chmod aio_utime aio_truncate
                     aio_msync aio_mtouch aio_mlock aio_mlockall
                     aio_statvfs
                     aio_wd);

   our @EXPORT = (@AIO_REQ, qw(aioreq_pri aioreq_nice));
   our @EXPORT_OK = qw(poll_fileno poll_cb poll_wait flush
                       min_parallel max_parallel max_idle idle_timeout
                       nreqs nready npending nthreads
                       max_poll_time max_poll_reqs
                       sendfile fadvise madvise
                       mmap munmap munlock munlockall);

   push @AIO_REQ, qw(aio_busy); # not exported

   @IO::AIO::GRP::ISA = 'IO::AIO::REQ';

   require XSLoader;
   XSLoader::load ("IO::AIO", $VERSION);
}

=head1 FUNCTIONS

=head2 QUICK OVERVIEW

This section simply lists the prototypes most of the functions for
quick reference. See the following sections for function-by-function
documentation.

   aio_wd $pathname, $callback->($wd)
   aio_open $pathname, $flags, $mode, $callback->($fh)
   aio_close $fh, $callback->($status)
   aio_seek  $fh,$offset,$whence, $callback->($offs)
   aio_read  $fh,$offset,$length, $data,$dataoffset, $callback->($retval)
   aio_write $fh,$offset,$length, $data,$dataoffset, $callback->($retval)
   aio_sendfile $out_fh, $in_fh, $in_offset, $length, $callback->($retval)
   aio_readahead $fh,$offset,$length, $callback->($retval)
   aio_stat  $fh_or_path, $callback->($status)
   aio_lstat $fh, $callback->($status)
   aio_statvfs $fh_or_path, $callback->($statvfs)
   aio_utime $fh_or_path, $atime, $mtime, $callback->($status)
   aio_chown $fh_or_path, $uid, $gid, $callback->($status)
   aio_chmod $fh_or_path, $mode, $callback->($status)
   aio_truncate $fh_or_path, $offset, $callback->($status)
   aio_allocate $fh, $mode, $offset, $len, $callback->($status)
   aio_fiemap $fh, $start, $length, $flags, $count, $cb->(\@extents)
   aio_unlink $pathname, $callback->($status)
   aio_mknod $pathname, $mode, $dev, $callback->($status)
   aio_link $srcpath, $dstpath, $callback->($status)
   aio_symlink $srcpath, $dstpath, $callback->($status)
   aio_readlink $pathname, $callback->($link)
   aio_realpath $pathname, $callback->($link)
   aio_rename $srcpath, $dstpath, $callback->($status)
   aio_mkdir $pathname, $mode, $callback->($status)
   aio_rmdir $pathname, $callback->($status)
   aio_readdir $pathname, $callback->($entries)
   aio_readdirx $pathname, $flags, $callback->($entries, $flags)
      IO::AIO::READDIR_DENTS IO::AIO::READDIR_DIRS_FIRST
      IO::AIO::READDIR_STAT_ORDER IO::AIO::READDIR_FOUND_UNKNOWN
   aio_scandir $pathname, $maxreq, $callback->($dirs, $nondirs)
   aio_load $pathname, $data, $callback->($status)
   aio_copy $srcpath, $dstpath, $callback->($status)
   aio_move $srcpath, $dstpath, $callback->($status)
   aio_rmtree $pathname, $callback->($status)
   aio_sync $callback->($status)
   aio_syncfs $fh, $callback->($status)
   aio_fsync $fh, $callback->($status)
   aio_fdatasync $fh, $callback->($status)
   aio_sync_file_range $fh, $offset, $nbytes, $flags, $callback->($status)
   aio_pathsync $pathname, $callback->($status)
   aio_msync $scalar, $offset = 0, $length = undef, flags = 0, $callback->($status)
   aio_mtouch $scalar, $offset = 0, $length = undef, flags = 0, $callback->($status)
   aio_mlock $scalar, $offset = 0, $length = undef, $callback->($status)
   aio_mlockall $flags, $callback->($status)
   aio_group $callback->(...)
   aio_nop $callback->()

   $prev_pri = aioreq_pri [$pri]
   aioreq_nice $pri_adjust

   IO::AIO::poll_wait
   IO::AIO::poll_cb
   IO::AIO::poll
   IO::AIO::flush
   IO::AIO::max_poll_reqs $nreqs
   IO::AIO::max_poll_time $seconds
   IO::AIO::min_parallel $nthreads
   IO::AIO::max_parallel $nthreads
   IO::AIO::max_idle $nthreads
   IO::AIO::idle_timeout $seconds
   IO::AIO::max_outstanding $maxreqs
   IO::AIO::nreqs
   IO::AIO::nready
   IO::AIO::npending

   IO::AIO::sendfile $ofh, $ifh, $offset, $count
   IO::AIO::fadvise $fh, $offset, $len, $advice
   IO::AIO::mmap $scalar, $length, $prot, $flags[, $fh[, $offset]]
   IO::AIO::munmap $scalar
   IO::AIO::madvise $scalar, $offset, $length, $advice
   IO::AIO::mprotect $scalar, $offset, $length, $protect
   IO::AIO::munlock $scalar, $offset = 0, $length = undef
   IO::AIO::munlockall

=head2 API NOTES

All the C<aio_*> calls are more or less thin wrappers around the syscall
with the same name (sans C<aio_>). The arguments are similar or identical,
and they all accept an additional (and optional) C<$callback> argument
which must be a code reference. This code reference will be called after
the syscall has been executed in an asynchronous fashion. The results
of the request will be passed as arguments to the callback (and, if an
error occured, in C<$!>) - for most requests the syscall return code (e.g.
most syscalls return C<-1> on error, unlike perl, which usually delivers
"false").

Some requests (such as C<aio_readdir>) pass the actual results and
communicate failures by passing C<undef>.

All functions expecting a filehandle keep a copy of the filehandle
internally until the request has finished.

All functions return request objects of type L<IO::AIO::REQ> that allow
further manipulation of those requests while they are in-flight.

The pathnames you pass to these routines I<should> be absolute. The
reason for this is that at the time the request is being executed, the
current working directory could have changed. Alternatively, you can
make sure that you never change the current working directory anywhere
in the program and then use relative paths. You can also take advantage
of IO::AIOs working directory abstraction, that lets you specify paths
relative to some previously-opened "working directory object" - see the
description of the C<IO::AIO::WD> class later in this document.

To encode pathnames as octets, either make sure you either: a) always pass
in filenames you got from outside (command line, readdir etc.) without
tinkering, b) are in your native filesystem encoding, c) use the Encode
module and encode your pathnames to the locale (or other) encoding in
effect in the user environment, d) use Glib::filename_from_unicode on
unicode filenames or e) use something else to ensure your scalar has the
correct contents.

This works, btw. independent of the internal UTF-8 bit, which IO::AIO
handles correctly whether it is set or not.

=head2 AIO REQUEST FUNCTIONS

=over 4

=item $prev_pri = aioreq_pri [$pri]

Returns the priority value that would be used for the next request and, if
C<$pri> is given, sets the priority for the next aio request.

The default priority is C<0>, the minimum and maximum priorities are C<-4>
and C<4>, respectively. Requests with higher priority will be serviced
first.

The priority will be reset to C<0> after each call to one of the C<aio_*>
functions.

Example: open a file with low priority, then read something from it with
higher priority so the read request is serviced before other low priority
open requests (potentially spamming the cache):

   aioreq_pri -3;
   aio_open ..., sub {
      return unless $_[0];

      aioreq_pri -2;
      aio_read $_[0], ..., sub {
         ...
      };
   };


=item aioreq_nice $pri_adjust

Similar to C<aioreq_pri>, but subtracts the given value from the current
priority, so the effect is cumulative.


=item aio_open $pathname, $flags, $mode, $callback->($fh)

Asynchronously open or create a file and call the callback with a newly
created filehandle for the file (or C<undef> in case of an error).

The pathname passed to C<aio_open> must be absolute. See API NOTES, above,
for an explanation.

The C<$flags> argument is a bitmask. See the C<Fcntl> module for a
list. They are the same as used by C<sysopen>.

Likewise, C<$mode> specifies the mode of the newly created file, if it
didn't exist and C<O_CREAT> has been given, just like perl's C<sysopen>,
except that it is mandatory (i.e. use C<0> if you don't create new files,
and C<0666> or C<0777> if you do). Note that the C<$mode> will be modified
by the umask in effect then the request is being executed, so better never
change the umask.

Example:

   aio_open "/etc/passwd", IO::AIO::O_RDONLY, 0, sub {
      if ($_[0]) {
         print "open successful, fh is $_[0]\n";
         ...
      } else {
         die "open failed: $!\n";
      }
   };

In addition to all the common open modes/flags (C<O_RDONLY>, C<O_WRONLY>,
C<O_RDWR>, C<O_CREAT>, C<O_TRUNC>, C<O_EXCL> and C<O_APPEND>), the
following POSIX and non-POSIX constants are available (missing ones on
your system are, as usual, C<0>):

C<O_ASYNC>, C<O_DIRECT>, C<O_NOATIME>, C<O_CLOEXEC>, C<O_NOCTTY>, C<O_NOFOLLOW>,
C<O_NONBLOCK>, C<O_EXEC>, C<O_SEARCH>, C<O_DIRECTORY>, C<O_DSYNC>,
C<O_RSYNC>, C<O_SYNC> and C<O_TTY_INIT>.


=item aio_close $fh, $callback->($status)

Asynchronously close a file and call the callback with the result
code.

Unfortunately, you can't do this to perl. Perl I<insists> very strongly on
closing the file descriptor associated with the filehandle itself.

Therefore, C<aio_close> will not close the filehandle - instead it will
use dup2 to overwrite the file descriptor with the write-end of a pipe
(the pipe fd will be created on demand and will be cached).

Or in other words: the file descriptor will be closed, but it will not be
free for reuse until the perl filehandle is closed.

=cut

=item aio_seek $fh, $offset, $whence, $callback->($offs)

Seeks the filehandle to the new C<$offset>, similarly to perl's
C<sysseek>. The C<$whence> can use the traditional values (C<0> for
C<IO::AIO::SEEK_SET>, C<1> for C<IO::AIO::SEEK_CUR> or C<2> for
C<IO::AIO::SEEK_END>).

The resulting absolute offset will be passed to the callback, or C<-1> in
case of an error.

In theory, the C<$whence> constants could be different than the
corresponding values from L<Fcntl>, but perl guarantees they are the same,
so don't panic.

As a GNU/Linux (and maybe Solaris) extension, also the constants
C<IO::AIO::SEEK_DATA> and C<IO::AIO::SEEK_HOLE> are available, if they
could be found. No guarantees about suitability for use in C<aio_seek> or
Perl's C<sysseek> can be made though, although I would naively assume they
"just work".

=item aio_read  $fh,$offset,$length, $data,$dataoffset, $callback->($retval)

=item aio_write $fh,$offset,$length, $data,$dataoffset, $callback->($retval)

Reads or writes C<$length> bytes from or to the specified C<$fh> and
C<$offset> into the scalar given by C<$data> and offset C<$dataoffset>
and calls the callback without the actual number of bytes read (or -1 on
error, just like the syscall).

C<aio_read> will, like C<sysread>, shrink or grow the C<$data> scalar to
offset plus the actual number of bytes read.

If C<$offset> is undefined, then the current file descriptor offset will
be used (and updated), otherwise the file descriptor offset will not be
changed by these calls.

If C<$length> is undefined in C<aio_write>, use the remaining length of
C<$data>.

If C<$dataoffset> is less than zero, it will be counted from the end of
C<$data>.

The C<$data> scalar I<MUST NOT> be modified in any way while the request
is outstanding. Modifying it can result in segfaults or World War III (if
the necessary/optional hardware is installed).

Example: Read 15 bytes at offset 7 into scalar C<$buffer>, starting at
offset C<0> within the scalar:

   aio_read $fh, 7, 15, $buffer, 0, sub {
      $_[0] > 0 or die "read error: $!";
      print "read $_[0] bytes: <$buffer>\n";
   };


=item aio_sendfile $out_fh, $in_fh, $in_offset, $length, $callback->($retval)

Tries to copy C<$length> bytes from C<$in_fh> to C<$out_fh>. It starts
reading at byte offset C<$in_offset>, and starts writing at the current
file offset of C<$out_fh>. Because of that, it is not safe to issue more
than one C<aio_sendfile> per C<$out_fh>, as they will interfere with each
other. The same C<$in_fh> works fine though, as this function does not
move or use the file offset of C<$in_fh>.

Please note that C<aio_sendfile> can read more bytes from C<$in_fh> than
are written, and there is no way to find out how many more bytes have been
read from C<aio_sendfile> alone, as C<aio_sendfile> only provides the
number of bytes written to C<$out_fh>. Only if the result value equals
C<$length> one can assume that C<$length> bytes have been read.

Unlike with other C<aio_> functions, it makes a lot of sense to use
C<aio_sendfile> on non-blocking sockets, as long as one end (typically
the C<$in_fh>) is a file - the file I/O will then be asynchronous, while
the socket I/O will be non-blocking. Note, however, that you can run
into a trap where C<aio_sendfile> reads some data with readahead, then
fails to write all data, and when the socket is ready the next time, the
data in the cache is already lost, forcing C<aio_sendfile> to again hit
the disk. Explicit C<aio_read> + C<aio_write> let's you better control
resource usage.

This call tries to make use of a native C<sendfile>-like syscall to
provide zero-copy operation. For this to work, C<$out_fh> should refer to
a socket, and C<$in_fh> should refer to an mmap'able file.

If a native sendfile cannot be found or it fails with C<ENOSYS>,
C<EINVAL>, C<ENOTSUP>, C<EOPNOTSUPP>, C<EAFNOSUPPORT>, C<EPROTOTYPE> or
C<ENOTSOCK>, it will be emulated, so you can call C<aio_sendfile> on any
type of filehandle regardless of the limitations of the operating system.

As native sendfile syscalls (as practically any non-POSIX interface hacked
together in a hurry to improve benchmark numbers) tend to be rather buggy
on many systems, this implementation tries to work around some known bugs
in Linux and FreeBSD kernels (probably others, too), but that might fail,
so you really really should check the return value of C<aio_sendfile> -
fewre bytes than expected might have been transferred.


=item aio_readahead $fh,$offset,$length, $callback->($retval)

C<aio_readahead> populates the page cache with data from a file so that
subsequent reads from that file will not block on disk I/O. The C<$offset>
argument specifies the starting point from which data is to be read and
C<$length> specifies the number of bytes to be read. I/O is performed in
whole pages, so that offset is effectively rounded down to a page boundary
and bytes are read up to the next page boundary greater than or equal to
(off-set+length). C<aio_readahead> does not read beyond the end of the
file. The current file offset of the file is left unchanged.

If that syscall doesn't exist (likely if your OS isn't Linux) it will be
emulated by simply reading the data, which would have a similar effect.


=item aio_stat  $fh_or_path, $callback->($status)

=item aio_lstat $fh, $callback->($status)

Works like perl's C<stat> or C<lstat> in void context. The callback will
be called after the stat and the results will be available using C<stat _>
or C<-s _> etc...

The pathname passed to C<aio_stat> must be absolute. See API NOTES, above,
for an explanation.

Currently, the stats are always 64-bit-stats, i.e. instead of returning an
error when stat'ing a large file, the results will be silently truncated
unless perl itself is compiled with large file support.

To help interpret the mode and dev/rdev stat values, IO::AIO offers the
following constants and functions (if not implemented, the constants will
be C<0> and the functions will either C<croak> or fall back on traditional
behaviour).

C<S_IFMT>, C<S_IFIFO>, C<S_IFCHR>, C<S_IFBLK>, C<S_IFLNK>, C<S_IFREG>,
C<S_IFDIR>, C<S_IFWHT>, C<S_IFSOCK>, C<IO::AIO::major $dev_t>,
C<IO::AIO::minor $dev_t>, C<IO::AIO::makedev $major, $minor>.

Example: Print the length of F</etc/passwd>:

   aio_stat "/etc/passwd", sub {
      $_[0] and die "stat failed: $!";
      print "size is ", -s _, "\n";
   };


=item aio_statvfs $fh_or_path, $callback->($statvfs)

Works like the POSIX C<statvfs> or C<fstatvfs> syscalls, depending on
whether a file handle or path was passed.

On success, the callback is passed a hash reference with the following
members: C<bsize>, C<frsize>, C<blocks>, C<bfree>, C<bavail>, C<files>,
C<ffree>, C<favail>, C<fsid>, C<flag> and C<namemax>. On failure, C<undef>
is passed.

The following POSIX IO::AIO::ST_* constants are defined: C<ST_RDONLY> and
C<ST_NOSUID>.

The following non-POSIX IO::AIO::ST_* flag masks are defined to
their correct value when available, or to C<0> on systems that do
not support them:  C<ST_NODEV>, C<ST_NOEXEC>, C<ST_SYNCHRONOUS>,
C<ST_MANDLOCK>, C<ST_WRITE>, C<ST_APPEND>, C<ST_IMMUTABLE>, C<ST_NOATIME>,
C<ST_NODIRATIME> and C<ST_RELATIME>.

Example: stat C</wd> and dump out the data if successful.

   aio_statvfs "/wd", sub {
      my $f = $_[0]
         or die "statvfs: $!";

      use Data::Dumper;
      say Dumper $f;
   };

   # result:
   {
      bsize   => 1024,
      bfree   => 4333064312,
      blocks  => 10253828096,
      files   => 2050765568,
      flag    => 4096,
      favail  => 2042092649,
      bavail  => 4333064312,
      ffree   => 2042092649,
      namemax => 255,
      frsize  => 1024,
      fsid    => 1810
   }

Here is a (likely partial - send me updates!) list of fsid values used by
Linux - it is safe to hardcode these when C<$^O> is C<linux>:

   0x0000adf5 adfs
   0x0000adff affs
   0x5346414f afs
   0x09041934 anon-inode filesystem
   0x00000187 autofs
   0x42465331 befs
   0x1badface bfs
   0x42494e4d binfmt_misc
   0x9123683e btrfs
   0x0027e0eb cgroupfs
   0xff534d42 cifs
   0x73757245 coda
   0x012ff7b7 coh
   0x28cd3d45 cramfs
   0x453dcd28 cramfs-wend (wrong endianness)
   0x64626720 debugfs
   0x00001373 devfs
   0x00001cd1 devpts
   0x0000f15f ecryptfs
   0x00414a53 efs
   0x0000137d ext
   0x0000ef53 ext2/ext3
   0x0000ef51 ext2
   0x00004006 fat
   0x65735546 fuseblk
   0x65735543 fusectl
   0x0bad1dea futexfs
   0x01161970 gfs2
   0x47504653 gpfs
   0x00004244 hfs
   0xf995e849 hpfs
   0x958458f6 hugetlbfs
   0x2bad1dea inotifyfs
   0x00009660 isofs
   0x000072b6 jffs2
   0x3153464a jfs
   0x6b414653 k-afs
   0x0bd00bd0 lustre
   0x0000137f minix
   0x0000138f minix 30 char names
   0x00002468 minix v2
   0x00002478 minix v2 30 char names
   0x00004d5a minix v3
   0x19800202 mqueue
   0x00004d44 msdos
   0x0000564c novell
   0x00006969 nfs
   0x6e667364 nfsd
   0x00003434 nilfs
   0x5346544e ntfs
   0x00009fa1 openprom
   0x7461636F ocfs2
   0x00009fa0 proc
   0x6165676c pstorefs
   0x0000002f qnx4
   0x858458f6 ramfs
   0x52654973 reiserfs
   0x00007275 romfs
   0x67596969 rpc_pipefs
   0x73636673 securityfs
   0xf97cff8c selinux
   0x0000517b smb
   0x534f434b sockfs
   0x73717368 squashfs
   0x62656572 sysfs
   0x012ff7b6 sysv2
   0x012ff7b5 sysv4
   0x01021994 tmpfs
   0x15013346 udf
   0x00011954 ufs
   0x54190100 ufs byteswapped
   0x00009fa2 usbdevfs
   0x01021997 v9fs
   0xa501fcf5 vxfs
   0xabba1974 xenfs
   0x012ff7b4 xenix
   0x58465342 xfs
   0x012fd16d xia

=item aio_utime $fh_or_path, $atime, $mtime, $callback->($status)

Works like perl's C<utime> function (including the special case of $atime
and $mtime being undef). Fractional times are supported if the underlying
syscalls support them.

When called with a pathname, uses utimes(2) if available, otherwise
utime(2). If called on a file descriptor, uses futimes(2) if available,
otherwise returns ENOSYS, so this is not portable.

Examples:

   # set atime and mtime to current time (basically touch(1)):
   aio_utime "path", undef, undef;
   # set atime to current time and mtime to beginning of the epoch:
   aio_utime "path", time, undef; # undef==0


=item aio_chown $fh_or_path, $uid, $gid, $callback->($status)

Works like perl's C<chown> function, except that C<undef> for either $uid
or $gid is being interpreted as "do not change" (but -1 can also be used).

Examples:

   # same as "chown root path" in the shell:
   aio_chown "path", 0, -1;
   # same as above:
   aio_chown "path", 0, undef;


=item aio_truncate $fh_or_path, $offset, $callback->($status)

Works like truncate(2) or ftruncate(2).


=item aio_allocate $fh, $mode, $offset, $len, $callback->($status)

Allocates or freed disk space according to the C<$mode> argument. See the
linux C<fallocate> docuemntation for details.

C<$mode> can currently be C<0> or C<IO::AIO::FALLOC_FL_KEEP_SIZE>
to allocate space, or C<IO::AIO::FALLOC_FL_PUNCH_HOLE |
IO::AIO::FALLOC_FL_KEEP_SIZE>, to deallocate a file range.

The file system block size used by C<fallocate> is presumably the
C<f_bsize> returned by C<statvfs>.

If C<fallocate> isn't available or cannot be emulated (currently no
emulation will be attempted), passes C<-1> and sets C<$!> to C<ENOSYS>.


=item aio_chmod $fh_or_path, $mode, $callback->($status)

Works like perl's C<chmod> function.


=item aio_unlink $pathname, $callback->($status)

Asynchronously unlink (delete) a file and call the callback with the
result code.


=item aio_mknod $pathname, $mode, $dev, $callback->($status)

[EXPERIMENTAL]

Asynchronously create a device node (or fifo). See mknod(2).

The only (POSIX-) portable way of calling this function is:

   aio_mknod $pathname, IO::AIO::S_IFIFO | $mode, 0, sub { ...

See C<aio_stat> for info about some potentially helpful extra constants
and functions.

=item aio_link $srcpath, $dstpath, $callback->($status)

Asynchronously create a new link to the existing object at C<$srcpath> at
the path C<$dstpath> and call the callback with the result code.


=item aio_symlink $srcpath, $dstpath, $callback->($status)

Asynchronously create a new symbolic link to the existing object at C<$srcpath> at
the path C<$dstpath> and call the callback with the result code.


=item aio_readlink $pathname, $callback->($link)

Asynchronously read the symlink specified by C<$path> and pass it to
the callback. If an error occurs, nothing or undef gets passed to the
callback.


=item aio_realpath $pathname, $callback->($path)

Asynchronously make the path absolute and resolve any symlinks in
C<$path>. The resulting path only consists of directories (same as
L<Cwd::realpath>).

This request can be used to get the absolute path of the current working
directory by passing it a path of F<.> (a single dot).


=item aio_rename $srcpath, $dstpath, $callback->($status)

Asynchronously rename the object at C<$srcpath> to C<$dstpath>, just as
rename(2) and call the callback with the result code.

On systems that support the AIO::WD working directory abstraction
natively, the case C<[$wd, "."]> as C<$srcpath> is specialcased - instead
of failing, C<rename> is called on the absolute path of C<$wd>.


=item aio_mkdir $pathname, $mode, $callback->($status)

Asynchronously mkdir (create) a directory and call the callback with
the result code. C<$mode> will be modified by the umask at the time the
request is executed, so do not change your umask.


=item aio_rmdir $pathname, $callback->($status)

Asynchronously rmdir (delete) a directory and call the callback with the
result code.

On systems that support the AIO::WD working directory abstraction
natively, the case C<[$wd, "."]> is specialcased - instead of failing,
C<rmdir> is called on the absolute path of C<$wd>.


=item aio_readdir $pathname, $callback->($entries)

Unlike the POSIX call of the same name, C<aio_readdir> reads an entire
directory (i.e. opendir + readdir + closedir). The entries will not be
sorted, and will B<NOT> include the C<.> and C<..> entries.

The callback is passed a single argument which is either C<undef> or an
array-ref with the filenames.


=item aio_readdirx $pathname, $flags, $callback->($entries, $flags)

Quite similar to C<aio_readdir>, but the C<$flags> argument allows one to
tune behaviour and output format. In case of an error, C<$entries> will be
C<undef>.

The flags are a combination of the following constants, ORed together (the
flags will also be passed to the callback, possibly modified):

=over 4

=item IO::AIO::READDIR_DENTS

When this flag is off, then the callback gets an arrayref consisting of
names only (as with C<aio_readdir>), otherwise it gets an arrayref with
C<[$name, $type, $inode]> arrayrefs, each describing a single directory
entry in more detail.

C<$name> is the name of the entry.

C<$type> is one of the C<IO::AIO::DT_xxx> constants:

C<IO::AIO::DT_UNKNOWN>, C<IO::AIO::DT_FIFO>, C<IO::AIO::DT_CHR>, C<IO::AIO::DT_DIR>,
C<IO::AIO::DT_BLK>, C<IO::AIO::DT_REG>, C<IO::AIO::DT_LNK>, C<IO::AIO::DT_SOCK>,
C<IO::AIO::DT_WHT>.

C<IO::AIO::DT_UNKNOWN> means just that: readdir does not know. If you need to
know, you have to run stat yourself. Also, for speed reasons, the C<$type>
scalars are read-only: you can not modify them.

C<$inode> is the inode number (which might not be exact on systems with 64
bit inode numbers and 32 bit perls). This field has unspecified content on
systems that do not deliver the inode information.

=item IO::AIO::READDIR_DIRS_FIRST

When this flag is set, then the names will be returned in an order where
likely directories come first, in optimal stat order. This is useful when
you need to quickly find directories, or you want to find all directories
while avoiding to stat() each entry.

If the system returns type information in readdir, then this is used
to find directories directly. Otherwise, likely directories are names
beginning with ".", or otherwise names with no dots, of which names with
short names are tried first.

=item IO::AIO::READDIR_STAT_ORDER

When this flag is set, then the names will be returned in an order
suitable for stat()'ing each one. That is, when you plan to stat()
all files in the given directory, then the returned order will likely
be fastest.

If both this flag and C<IO::AIO::READDIR_DIRS_FIRST> are specified, then
the likely dirs come first, resulting in a less optimal stat order.

=item IO::AIO::READDIR_FOUND_UNKNOWN

This flag should not be set when calling C<aio_readdirx>. Instead, it
is being set by C<aio_readdirx>, when any of the C<$type>'s found were
C<IO::AIO::DT_UNKNOWN>. The absence of this flag therefore indicates that all
C<$type>'s are known, which can be used to speed up some algorithms.

=back


=item aio_load $pathname, $data, $callback->($status)

This is a composite request that tries to fully load the given file into
memory. Status is the same as with aio_read.

=cut

sub aio_load($$;$) {
   my ($path, undef, $cb) = @_;
   my $data = \$_[1];

   my $pri = aioreq_pri;
   my $grp = aio_group $cb;

   aioreq_pri $pri;
   add $grp aio_open $path, O_RDONLY, 0, sub {
      my $fh = shift
         or return $grp->result (-1);

      aioreq_pri $pri;
      add $grp aio_read $fh, 0, (-s $fh), $$data, 0, sub {
         $grp->result ($_[0]);
      };
   };

   $grp
}

=item aio_copy $srcpath, $dstpath, $callback->($status)

Try to copy the I<file> (directories not supported as either source or
destination) from C<$srcpath> to C<$dstpath> and call the callback with
a status of C<0> (ok) or C<-1> (error, see C<$!>).

This is a composite request that creates the destination file with
mode 0200 and copies the contents of the source file into it using
C<aio_sendfile>, followed by restoring atime, mtime, access mode and
uid/gid, in that order.

If an error occurs, the partial destination file will be unlinked, if
possible, except when setting atime, mtime, access mode and uid/gid, where
errors are being ignored.

=cut

sub aio_copy($$;$) {
   my ($src, $dst, $cb) = @_;

   my $pri = aioreq_pri;
   my $grp = aio_group $cb;

   aioreq_pri $pri;
   add $grp aio_open $src, O_RDONLY, 0, sub {
      if (my $src_fh = $_[0]) {
         my @stat = stat $src_fh; # hmm, might block over nfs?

         aioreq_pri $pri;
         add $grp aio_open $dst, O_CREAT | O_WRONLY | O_TRUNC, 0200, sub {
            if (my $dst_fh = $_[0]) {
               aioreq_pri $pri;
               add $grp aio_sendfile $dst_fh, $src_fh, 0, $stat[7], sub {
                  if ($_[0] == $stat[7]) {
                     $grp->result (0);
                     close $src_fh;

                     my $ch = sub {
                        aioreq_pri $pri;
                        add $grp aio_chmod $dst_fh, $stat[2] & 07777, sub {
                           aioreq_pri $pri;
                           add $grp aio_chown $dst_fh, $stat[4], $stat[5], sub {
                              aioreq_pri $pri;
                              add $grp aio_close $dst_fh;
                           }
                        };
                     };

                     aioreq_pri $pri;
                     add $grp aio_utime $dst_fh, $stat[8], $stat[9], sub {
                        if ($_[0] < 0 && $! == ENOSYS) {
                           aioreq_pri $pri;
                           add $grp aio_utime $dst, $stat[8], $stat[9], $ch;
                        } else {
                           $ch->();
                        }
                     };
                  } else {
                     $grp->result (-1);
                     close $src_fh;
                     close $dst_fh;

                     aioreq $pri;
                     add $grp aio_unlink $dst;
                  }
               };
            } else {
               $grp->result (-1);
            }
         },

      } else {
         $grp->result (-1);
      }
   };

   $grp
}

=item aio_move $srcpath, $dstpath, $callback->($status)

Try to move the I<file> (directories not supported as either source or
destination) from C<$srcpath> to C<$dstpath> and call the callback with
a status of C<0> (ok) or C<-1> (error, see C<$!>).

This is a composite request that tries to rename(2) the file first; if
rename fails with C<EXDEV>, it copies the file with C<aio_copy> and, if
that is successful, unlinks the C<$srcpath>.

=cut

sub aio_move($$;$) {
   my ($src, $dst, $cb) = @_;

   my $pri = aioreq_pri;
   my $grp = aio_group $cb;

   aioreq_pri $pri;
   add $grp aio_rename $src, $dst, sub {
      if ($_[0] && $! == EXDEV) {
         aioreq_pri $pri;
         add $grp aio_copy $src, $dst, sub {
            $grp->result ($_[0]);

            unless ($_[0]) {
               aioreq_pri $pri;
               add $grp aio_unlink $src;
            }
         };
      } else {
         $grp->result ($_[0]);
      }
   };

   $grp
}

=item aio_scandir $pathname, $maxreq, $callback->($dirs, $nondirs)

Scans a directory (similar to C<aio_readdir>) but additionally tries to
efficiently separate the entries of directory C<$path> into two sets of
names, directories you can recurse into (directories), and ones you cannot
recurse into (everything else, including symlinks to directories).

C<aio_scandir> is a composite request that creates of many sub requests_
C<$maxreq> specifies the maximum number of outstanding aio requests that
this function generates. If it is C<< <= 0 >>, then a suitable default
will be chosen (currently 4).

On error, the callback is called without arguments, otherwise it receives
two array-refs with path-relative entry names.

Example:

   aio_scandir $dir, 0, sub {
      my ($dirs, $nondirs) = @_;
      print "real directories: @$dirs\n";
      print "everything else: @$nondirs\n";
   };

Implementation notes.

The C<aio_readdir> cannot be avoided, but C<stat()>'ing every entry can.

If readdir returns file type information, then this is used directly to
find directories.

Otherwise, after reading the directory, the modification time, size etc.
of the directory before and after the readdir is checked, and if they
match (and isn't the current time), the link count will be used to decide
how many entries are directories (if >= 2). Otherwise, no knowledge of the
number of subdirectories will be assumed.

Then entries will be sorted into likely directories a non-initial dot
currently) and likely non-directories (see C<aio_readdirx>). Then every
entry plus an appended C</.> will be C<stat>'ed, likely directories first,
in order of their inode numbers. If that succeeds, it assumes that the
entry is a directory or a symlink to directory (which will be checked
separately). This is often faster than stat'ing the entry itself because
filesystems might detect the type of the entry without reading the inode
data (e.g. ext2fs filetype feature), even on systems that cannot return
the filetype information on readdir.

If the known number of directories (link count - 2) has been reached, the
rest of the entries is assumed to be non-directories.

This only works with certainty on POSIX (= UNIX) filesystems, which
fortunately are the vast majority of filesystems around.

It will also likely work on non-POSIX filesystems with reduced efficiency
as those tend to return 0 or 1 as link counts, which disables the
directory counting heuristic.

=cut

sub aio_scandir($$;$) {
   my ($path, $maxreq, $cb) = @_;

   my $pri = aioreq_pri;

   my $grp = aio_group $cb;

   $maxreq = 4 if $maxreq <= 0;

   # get a wd object
   aioreq_pri $pri;
   add $grp aio_wd $path, sub {
      $_[0]
         or return $grp->result ();

      my $wd = [shift, "."];

      # stat once
      aioreq_pri $pri;
      add $grp aio_stat $wd, sub {
         return $grp->result () if $_[0];
         my $now = time;
         my $hash1 = join ":", (stat _)[0,1,3,7,9];

         # read the directory entries
         aioreq_pri $pri;
         add $grp aio_readdirx $wd, READDIR_DIRS_FIRST, sub {
            my $entries = shift
               or return $grp->result ();

            # stat the dir another time
            aioreq_pri $pri;
            add $grp aio_stat $wd, sub {
               my $hash2 = join ":", (stat _)[0,1,3,7,9];

               my $ndirs;

               # take the slow route if anything looks fishy
               if ($hash1 ne $hash2 or (stat _)[9] == $now) {
                  $ndirs = -1;
               } else {
                  # if nlink == 2, we are finished
                  # for non-posix-fs's, we rely on nlink < 2
                  $ndirs = (stat _)[3] - 2
                     or return $grp->result ([], $entries);
               }

               my (@dirs, @nondirs);

               my $statgrp = add $grp aio_group sub {
                  $grp->result (\@dirs, \@nondirs);
               };

               limit $statgrp $maxreq;
               feed $statgrp sub {
                  return unless @$entries;
                  my $entry = shift @$entries;

                  aioreq_pri $pri;
                  $wd->[1] = "$entry/.";
                  add $statgrp aio_stat $wd, sub {
                     if ($_[0] < 0) {
                        push @nondirs, $entry;
                     } else {
                        # need to check for real directory
                        aioreq_pri $pri;
                        $wd->[1] = $entry;
                        add $statgrp aio_lstat $wd, sub {
                           if (-d _) {
                              push @dirs, $entry;

                              unless (--$ndirs) {
                                 push @nondirs, @$entries;
                                 feed $statgrp;
                              }
                           } else {
                              push @nondirs, $entry;
                           }
                        }
                     }
                  };
               };
            };
         };
      };
   };

   $grp
}

=item aio_rmtree $pathname, $callback->($status)

Delete a directory tree starting (and including) C<$path>, return the
status of the final C<rmdir> only. This is a composite request that
uses C<aio_scandir> to recurse into and rmdir directories, and unlink
everything else.

=cut

sub aio_rmtree;
sub aio_rmtree($;$) {
   my ($path, $cb) = @_;

   my $pri = aioreq_pri;
   my $grp = aio_group $cb;

   aioreq_pri $pri;
   add $grp aio_scandir $path, 0, sub {
      my ($dirs, $nondirs) = @_;

      my $dirgrp = aio_group sub {
         add $grp aio_rmdir $path, sub {
            $grp->result ($_[0]);
         };
      };

      (aioreq_pri $pri), add $dirgrp aio_rmtree "$path/$_" for @$dirs;
      (aioreq_pri $pri), add $dirgrp aio_unlink "$path/$_" for @$nondirs;

      add $grp $dirgrp;
   };

   $grp
}

=item aio_sync $callback->($status)

Asynchronously call sync and call the callback when finished.

=item aio_fsync $fh, $callback->($status)

Asynchronously call fsync on the given filehandle and call the callback
with the fsync result code.

=item aio_fdatasync $fh, $callback->($status)

Asynchronously call fdatasync on the given filehandle and call the
callback with the fdatasync result code.

If this call isn't available because your OS lacks it or it couldn't be
detected, it will be emulated by calling C<fsync> instead.

=item aio_syncfs $fh, $callback->($status)

Asynchronously call the syncfs syscall to sync the filesystem associated
to the given filehandle and call the callback with the syncfs result
code. If syncfs is not available, calls sync(), but returns C<-1> and sets
errno to C<ENOSYS> nevertheless.

=item aio_sync_file_range $fh, $offset, $nbytes, $flags, $callback->($status)

Sync the data portion of the file specified by C<$offset> and C<$length>
to disk (but NOT the metadata), by calling the Linux-specific
sync_file_range call. If sync_file_range is not available or it returns
ENOSYS, then fdatasync or fsync is being substituted.

C<$flags> can be a combination of C<IO::AIO::SYNC_FILE_RANGE_WAIT_BEFORE>,
C<IO::AIO::SYNC_FILE_RANGE_WRITE> and
C<IO::AIO::SYNC_FILE_RANGE_WAIT_AFTER>: refer to the sync_file_range
manpage for details.

=item aio_pathsync $pathname, $callback->($status)

This request tries to open, fsync and close the given path. This is a
composite request intended to sync directories after directory operations
(E.g. rename). This might not work on all operating systems or have any
specific effect, but usually it makes sure that directory changes get
written to disc. It works for anything that can be opened for read-only,
not just directories.

Future versions of this function might fall back to other methods when
C<fsync> on the directory fails (such as calling C<sync>).

Passes C<0> when everything went ok, and C<-1> on error.

=cut

sub aio_pathsync($;$) {
   my ($path, $cb) = @_;

   my $pri = aioreq_pri;
   my $grp = aio_group $cb;

   aioreq_pri $pri;
   add $grp aio_open $path, O_RDONLY, 0, sub {
      my ($fh) = @_;
      if ($fh) {
         aioreq_pri $pri;
         add $grp aio_fsync $fh, sub {
            $grp->result ($_[0]);

            aioreq_pri $pri;
            add $grp aio_close $fh;
         };
      } else {
         $grp->result (-1);
      }
   };

   $grp
}

=item aio_msync $scalar, $offset = 0, $length = undef, flags = 0, $callback->($status)

This is a rather advanced IO::AIO call, which only works on mmap(2)ed
scalars (see the C<IO::AIO::mmap> function, although it also works on data
scalars managed by the L<Sys::Mmap> or L<Mmap> modules, note that the
scalar must only be modified in-place while an aio operation is pending on
it).

It calls the C<msync> function of your OS, if available, with the memory
area starting at C<$offset> in the string and ending C<$length> bytes
later. If C<$length> is negative, counts from the end, and if C<$length>
is C<undef>, then it goes till the end of the string. The flags can be
a combination of C<IO::AIO::MS_ASYNC>, C<IO::AIO::MS_INVALIDATE> and
C<IO::AIO::MS_SYNC>.

=item aio_mtouch $scalar, $offset = 0, $length = undef, flags = 0, $callback->($status)

This is a rather advanced IO::AIO call, which works best on mmap(2)ed
scalars.

It touches (reads or writes) all memory pages in the specified
range inside the scalar. All caveats and parameters are the same
as for C<aio_msync>, above, except for flags, which must be either
C<0> (which reads all pages and ensures they are instantiated) or
C<IO::AIO::MT_MODIFY>, which modifies the memory pages (by reading and
writing an octet from it, which dirties the page).

=item aio_mlock $scalar, $offset = 0, $length = undef, $callback->($status)

This is a rather advanced IO::AIO call, which works best on mmap(2)ed
scalars.

It reads in all the pages of the underlying storage into memory (if any)
and locks them, so they are not getting swapped/paged out or removed.

If C<$length> is undefined, then the scalar will be locked till the end.

On systems that do not implement C<mlock>, this function returns C<-1>
and sets errno to C<ENOSYS>.

Note that the corresponding C<munlock> is synchronous and is
documented under L<MISCELLANEOUS FUNCTIONS>.

Example: open a file, mmap and mlock it - both will be undone when
C<$data> gets destroyed.

   open my $fh, "<", $path or die "$path: $!";
   my $data;
   IO::AIO::mmap $data, -s $fh, IO::AIO::PROT_READ, IO::AIO::MAP_SHARED, $fh;
   aio_mlock $data; # mlock in background

=item aio_mlockall $flags, $callback->($status)

Calls the C<mlockall> function with the given C<$flags> (a combination of
C<IO::AIO::MCL_CURRENT> and C<IO::AIO::MCL_FUTURE>).

On systems that do not implement C<mlockall>, this function returns C<-1>
and sets errno to C<ENOSYS>.

Note that the corresponding C<munlockall> is synchronous and is
documented under L<MISCELLANEOUS FUNCTIONS>.

Example: asynchronously lock all current and future pages into memory.

   aio_mlockall IO::AIO::MCL_FUTURE;

=item aio_fiemap $fh, $start, $length, $flags, $count, $cb->(\@extents)

Queries the extents of the given file (by calling the Linux C<FIEMAP>
ioctl, see L<http://cvs.schmorp.de/IO-AIO/doc/fiemap.txt> for details). If
the ioctl is not available on your OS, then this request will fail with
C<ENOSYS>.

C<$start> is the starting offset to query extents for, C<$length> is the
size of the range to query - if it is C<undef>, then the whole file will
be queried.

C<$flags> is a combination of flags (C<IO::AIO::FIEMAP_FLAG_SYNC> or
C<IO::AIO::FIEMAP_FLAG_XATTR> - C<IO::AIO::FIEMAP_FLAGS_COMPAT> is also
exported), and is normally C<0> or C<IO::AIO::FIEMAP_FLAG_SYNC> to query
the data portion.

C<$count> is the maximum number of extent records to return. If it is
C<undef>, then IO::AIO queries all extents of the range. As a very special
case, if it is C<0>, then the callback receives the number of extents
instead of the extents themselves (which is unreliable, see below).

If an error occurs, the callback receives no arguments. The special
C<errno> value C<IO::AIO::EBADR> is available to test for flag errors.

Otherwise, the callback receives an array reference with extent
structures. Each extent structure is an array reference itself, with the
following members:

   [$logical, $physical, $length, $flags]

Flags is any combination of the following flag values (typically either C<0>
or C<IO::AIO::FIEMAP_EXTENT_LAST> (1)):

C<IO::AIO::FIEMAP_EXTENT_LAST>, C<IO::AIO::FIEMAP_EXTENT_UNKNOWN>,
C<IO::AIO::FIEMAP_EXTENT_DELALLOC>, C<IO::AIO::FIEMAP_EXTENT_ENCODED>,
C<IO::AIO::FIEMAP_EXTENT_DATA_ENCRYPTED>, C<IO::AIO::FIEMAP_EXTENT_NOT_ALIGNED>,
C<IO::AIO::FIEMAP_EXTENT_DATA_INLINE>, C<IO::AIO::FIEMAP_EXTENT_DATA_TAIL>,
C<IO::AIO::FIEMAP_EXTENT_UNWRITTEN>, C<IO::AIO::FIEMAP_EXTENT_MERGED> or
C<IO::AIO::FIEMAP_EXTENT_SHARED>.

At the time of this writing (Linux 3.2), this requets is unreliable unless
C<$count> is C<undef>, as the kernel has all sorts of bugs preventing
it to return all extents of a range for files with large number of
extents. The code works around all these issues if C<$count> is undef.

=item aio_group $callback->(...)

This is a very special aio request: Instead of doing something, it is a
container for other aio requests, which is useful if you want to bundle
many requests into a single, composite, request with a definite callback
and the ability to cancel the whole request with its subrequests.

Returns an object of class L<IO::AIO::GRP>. See its documentation below
for more info.

Example:

   my $grp = aio_group sub {
      print "all stats done\n";
   };

   add $grp
      (aio_stat ...),
      (aio_stat ...),
      ...;

=item aio_nop $callback->()

This is a special request - it does nothing in itself and is only used for
side effects, such as when you want to add a dummy request to a group so
that finishing the requests in the group depends on executing the given
code.

While this request does nothing, it still goes through the execution
phase and still requires a worker thread. Thus, the callback will not
be executed immediately but only after other requests in the queue have
entered their execution phase. This can be used to measure request
latency.

=item IO::AIO::aio_busy $fractional_seconds, $callback->()  *NOT EXPORTED*

Mainly used for debugging and benchmarking, this aio request puts one of
the request workers to sleep for the given time.

While it is theoretically handy to have simple I/O scheduling requests
like sleep and file handle readable/writable, the overhead this creates is
immense (it blocks a thread for a long time) so do not use this function
except to put your application under artificial I/O pressure.

=back


=head2 IO::AIO::WD - multiple working directories

Your process only has one current working directory, which is used by all
threads. This makes it hard to use relative paths (some other component
could call C<chdir> at any time, and it is hard to control when the path
will be used by IO::AIO).

One solution for this is to always use absolute paths. This usually works,
but can be quite slow (the kernel has to walk the whole path on every
access), and can also be a hassle to implement.

Newer POSIX systems have a number of functions (openat, fdopendir,
futimensat and so on) that make it possible to specify working directories
per operation.

For portability, and because the clowns who "designed", or shall I write,
perpetrated this new interface were obviously half-drunk, this abstraction
cannot be perfect, though.

IO::AIO allows you to convert directory paths into a so-called IO::AIO::WD
object. This object stores the canonicalised, absolute version of the
path, and on systems that allow it, also a directory file descriptor.

Everywhere where a pathname is accepted by IO::AIO (e.g. in C<aio_stat>
or C<aio_unlink>), one can specify an array reference with an IO::AIO::WD
object and a pathname instead (or the IO::AIO::WD object alone, which
gets interpreted as C<[$wd, "."]>). If the pathname is absolute, the
IO::AIO::WD object is ignored, otherwise the pathname is resolved relative
to that IO::AIO::WD object.

For example, to get a wd object for F</etc> and then stat F<passwd>
inside, you would write:

   aio_wd "/etc", sub {
      my $etcdir = shift;

      # although $etcdir can be undef on error, there is generally no reason
      # to check for errors here, as aio_stat will fail with ENOENT
      # when $etcdir is undef.

      aio_stat [$etcdir, "passwd"], sub {
         # yay
      };
   };

That C<aio_wd> is a request and not a normal function shows that creating
an IO::AIO::WD object is itself a potentially blocking operation, which is
why it is done asynchronously.

To stat the directory obtained with C<aio_wd> above, one could write
either of the following three request calls:

   aio_lstat "/etc"    , sub { ...  # pathname as normal string
   aio_lstat [$wd, "."], sub { ...  # "." relative to $wd (i.e. $wd itself)
   aio_lstat $wd       , sub { ...  # shorthand for the previous

As with normal pathnames, IO::AIO keeps a copy of the working directory
object and the pathname string, so you could write the following without
causing any issues due to C<$path> getting reused:

   my $path = [$wd, undef];

   for my $name (qw(abc def ghi)) {
      $path->[1] = $name;
      aio_stat $path, sub {
         # ...
      };
   }

There are some caveats: when directories get renamed (or deleted), the
pathname string doesn't change, so will point to the new directory (or
nowhere at all), while the directory fd, if available on the system,
will still point to the original directory. Most functions accepting a
pathname will use the directory fd on newer systems, and the string on
older systems. Some functions (such as realpath) will always rely on the
string form of the pathname.

So this functionality is mainly useful to get some protection against
C<chdir>, to easily get an absolute path out of a relative path for future
reference, and to speed up doing many operations in the same directory
(e.g. when stat'ing all files in a directory).

The following functions implement this working directory abstraction:

=over 4

=item aio_wd $pathname, $callback->($wd)

Asynchonously canonicalise the given pathname and convert it to an
IO::AIO::WD object representing it. If possible and supported on the
system, also open a directory fd to speed up pathname resolution relative
to this working directory.

If something goes wrong, then C<undef> is passwd to the callback instead
of a working directory object and C<$!> is set appropriately. Since
passing C<undef> as working directory component of a pathname fails the
request with C<ENOENT>, there is often no need for error checking in the
C<aio_wd> callback, as future requests using the value will fail in the
expected way.

=item IO::AIO::CWD

This is a compiletime constant (object) that represents the process
current working directory.

Specifying this object as working directory object for a pathname is as if
the pathname would be specified directly, without a directory object. For
example, these calls are functionally identical:

   aio_stat "somefile", sub { ... };
   aio_stat [IO::AIO::CWD, "somefile"], sub { ... };

=back

To recover the path associated with an IO::AIO::WD object, you can use
C<aio_realpath>:

   aio_realpath $wd, sub {
      warn "path is $_[0]\n";
   };

Currently, C<aio_statvfs> always, and C<aio_rename> and C<aio_rmdir>
sometimes, fall back to using an absolue path.

=head2 IO::AIO::REQ CLASS

All non-aggregate C<aio_*> functions return an object of this class when
called in non-void context.

=over 4

=item cancel $req

Cancels the request, if possible. Has the effect of skipping execution
when entering the B<execute> state and skipping calling the callback when
entering the the B<result> state, but will leave the request otherwise
untouched (with the exception of readdir). That means that requests that
currently execute will not be stopped and resources held by the request
will not be freed prematurely.

=item cb $req $callback->(...)

Replace (or simply set) the callback registered to the request.

=back

=head2 IO::AIO::GRP CLASS

This class is a subclass of L<IO::AIO::REQ>, so all its methods apply to
objects of this class, too.

A IO::AIO::GRP object is a special request that can contain multiple other
aio requests.

You create one by calling the C<aio_group> constructing function with a
callback that will be called when all contained requests have entered the
C<done> state:

   my $grp = aio_group sub {
      print "all requests are done\n";
   };

You add requests by calling the C<add> method with one or more
C<IO::AIO::REQ> objects:

   $grp->add (aio_unlink "...");

   add $grp aio_stat "...", sub {
      $_[0] or return $grp->result ("error");

      # add another request dynamically, if first succeeded
      add $grp aio_open "...", sub {
         $grp->result ("ok");
      };
   };

This makes it very easy to create composite requests (see the source of
C<aio_move> for an application) that work and feel like simple requests.

=over 4

=item * The IO::AIO::GRP objects will be cleaned up during calls to
C<IO::AIO::poll_cb>, just like any other request.

=item * They can be canceled like any other request. Canceling will cancel not
only the request itself, but also all requests it contains.

=item * They can also can also be added to other IO::AIO::GRP objects.

=item * You must not add requests to a group from within the group callback (or
any later time).

=back

Their lifetime, simplified, looks like this: when they are empty, they
will finish very quickly. If they contain only requests that are in the
C<done> state, they will also finish. Otherwise they will continue to
exist.

That means after creating a group you have some time to add requests
(precisely before the callback has been invoked, which is only done within
the C<poll_cb>). And in the callbacks of those requests, you can add
further requests to the group. And only when all those requests have
finished will the the group itself finish.

=over 4

=item add $grp ...

=item $grp->add (...)

Add one or more requests to the group. Any type of L<IO::AIO::REQ> can
be added, including other groups, as long as you do not create circular
dependencies.

Returns all its arguments.

=item $grp->cancel_subs

Cancel all subrequests and clears any feeder, but not the group request
itself. Useful when you queued a lot of events but got a result early.

The group request will finish normally (you cannot add requests to the
group).

=item $grp->result (...)

Set the result value(s) that will be passed to the group callback when all
subrequests have finished and set the groups errno to the current value
of errno (just like calling C<errno> without an error number). By default,
no argument will be passed and errno is zero.

=item $grp->errno ([$errno])

Sets the group errno value to C<$errno>, or the current value of errno
when the argument is missing.

Every aio request has an associated errno value that is restored when
the callback is invoked. This method lets you change this value from its
default (0).

Calling C<result> will also set errno, so make sure you either set C<$!>
before the call to C<result>, or call c<errno> after it.

=item feed $grp $callback->($grp)

Sets a feeder/generator on this group: every group can have an attached
generator that generates requests if idle. The idea behind this is that,
although you could just queue as many requests as you want in a group,
this might starve other requests for a potentially long time. For example,
C<aio_scandir> might generate hundreds of thousands of C<aio_stat>
requests, delaying any later requests for a long time.

To avoid this, and allow incremental generation of requests, you can
instead a group and set a feeder on it that generates those requests. The
feed callback will be called whenever there are few enough (see C<limit>,
below) requests active in the group itself and is expected to queue more
requests.

The feed callback can queue as many requests as it likes (i.e. C<add> does
not impose any limits).

If the feed does not queue more requests when called, it will be
automatically removed from the group.

If the feed limit is C<0> when this method is called, it will be set to
C<2> automatically.

Example:

   # stat all files in @files, but only ever use four aio requests concurrently:

   my $grp = aio_group sub { print "finished\n" };
   limit $grp 4;
   feed $grp sub {
      my $file = pop @files
         or return;

      add $grp aio_stat $file, sub { ... };
   };

=item limit $grp $num

Sets the feeder limit for the group: The feeder will be called whenever
the group contains less than this many requests.

Setting the limit to C<0> will pause the feeding process.

The default value for the limit is C<0>, but note that setting a feeder
automatically bumps it up to C<2>.

=back

=head2 SUPPORT FUNCTIONS

=head3 EVENT PROCESSING AND EVENT LOOP INTEGRATION

=over 4

=item $fileno = IO::AIO::poll_fileno

Return the I<request result pipe file descriptor>. This filehandle must be
polled for reading by some mechanism outside this module (e.g. EV, Glib,
select and so on, see below or the SYNOPSIS). If the pipe becomes readable
you have to call C<poll_cb> to check the results.

See C<poll_cb> for an example.

=item IO::AIO::poll_cb

Process some requests that have reached the result phase (i.e. they have
been executed but the results are not yet reported). You have to call
this "regularly" to finish outstanding requests.

Returns C<0> if all events could be processed (or there were no
events to process), or C<-1> if it returned earlier for whatever
reason. Returns immediately when no events are outstanding. The amount
of events processed depends on the settings of C<IO::AIO::max_poll_req>,
C<IO::AIO::max_poll_time> and C<IO::AIO::max_outstanding>.

If not all requests were processed for whatever reason, the poll file
descriptor will still be ready when C<poll_cb> returns, so normally you
don't have to do anything special to have it called later.

Apart from calling C<IO::AIO::poll_cb> when the event filehandle becomes
ready, it can be beneficial to call this function from loops which submit
a lot of requests, to make sure the results get processed when they become
available and not just when the loop is finished and the event loop takes
over again. This function returns very fast when there are no outstanding
requests.

Example: Install an Event watcher that automatically calls
IO::AIO::poll_cb with high priority (more examples can be found in the
SYNOPSIS section, at the top of this document):

   Event->io (fd => IO::AIO::poll_fileno,
              poll => 'r', async => 1,
              cb => \&IO::AIO::poll_cb);

=item IO::AIO::poll_wait

Wait until either at least one request is in the result phase or no
requests are outstanding anymore.

This is useful if you want to synchronously wait for some requests to
become ready, without actually handling them.

See C<nreqs> for an example.

=item IO::AIO::poll

Waits until some requests have been handled.

Returns the number of requests processed, but is otherwise strictly
equivalent to:

   IO::AIO::poll_wait, IO::AIO::poll_cb

=item IO::AIO::flush

Wait till all outstanding AIO requests have been handled.

Strictly equivalent to:

   IO::AIO::poll_wait, IO::AIO::poll_cb
      while IO::AIO::nreqs;

=item IO::AIO::max_poll_reqs $nreqs

=item IO::AIO::max_poll_time $seconds

These set the maximum number of requests (default C<0>, meaning infinity)
that are being processed by C<IO::AIO::poll_cb> in one call, respectively
the maximum amount of time (default C<0>, meaning infinity) spent in
C<IO::AIO::poll_cb> to process requests (more correctly the mininum amount
of time C<poll_cb> is allowed to use).

Setting C<max_poll_time> to a non-zero value creates an overhead of one
syscall per request processed, which is not normally a problem unless your
callbacks are really really fast or your OS is really really slow (I am
not mentioning Solaris here). Using C<max_poll_reqs> incurs no overhead.

Setting these is useful if you want to ensure some level of
interactiveness when perl is not fast enough to process all requests in
time.

For interactive programs, values such as C<0.01> to C<0.1> should be fine.

Example: Install an Event watcher that automatically calls
IO::AIO::poll_cb with low priority, to ensure that other parts of the
program get the CPU sometimes even under high AIO load.

   # try not to spend much more than 0.1s in poll_cb
   IO::AIO::max_poll_time 0.1;

   # use a low priority so other tasks have priority
   Event->io (fd => IO::AIO::poll_fileno,
              poll => 'r', nice => 1,
              cb => &IO::AIO::poll_cb);

=back

=head3 CONTROLLING THE NUMBER OF THREADS

=over

=item IO::AIO::min_parallel $nthreads

Set the minimum number of AIO threads to C<$nthreads>. The current
default is C<8>, which means eight asynchronous operations can execute
concurrently at any one time (the number of outstanding requests,
however, is unlimited).

IO::AIO starts threads only on demand, when an AIO request is queued and
no free thread exists. Please note that queueing up a hundred requests can
create demand for a hundred threads, even if it turns out that everything
is in the cache and could have been processed faster by a single thread.

It is recommended to keep the number of threads relatively low, as some
Linux kernel versions will scale negatively with the number of threads
(higher parallelity => MUCH higher latency). With current Linux 2.6
versions, 4-32 threads should be fine.

Under most circumstances you don't need to call this function, as the
module selects a default that is suitable for low to moderate load.

=item IO::AIO::max_parallel $nthreads

Sets the maximum number of AIO threads to C<$nthreads>. If more than the
specified number of threads are currently running, this function kills
them. This function blocks until the limit is reached.

While C<$nthreads> are zero, aio requests get queued but not executed
until the number of threads has been increased again.

This module automatically runs C<max_parallel 0> at program end, to ensure
that all threads are killed and that there are no outstanding requests.

Under normal circumstances you don't need to call this function.

=item IO::AIO::max_idle $nthreads

Limit the number of threads (default: 4) that are allowed to idle
(i.e., threads that did not get a request to process within the idle
timeout (default: 10 seconds). That means if a thread becomes idle while
C<$nthreads> other threads are also idle, it will free its resources and
exit.

This is useful when you allow a large number of threads (e.g. 100 or 1000)
to allow for extremely high load situations, but want to free resources
under normal circumstances (1000 threads can easily consume 30MB of RAM).

The default is probably ok in most situations, especially if thread
creation is fast. If thread creation is very slow on your system you might
want to use larger values.

=item IO::AIO::idle_timeout $seconds

Sets the minimum idle timeout (default 10) after which worker threads are
allowed to exit. SEe C<IO::AIO::max_idle>.

=item IO::AIO::max_outstanding $maxreqs

Sets the maximum number of outstanding requests to C<$nreqs>. If
you do queue up more than this number of requests, the next call to
C<IO::AIO::poll_cb> (and other functions calling C<poll_cb>, such as
C<IO::AIO::flush> or C<IO::AIO::poll>) will block until the limit is no
longer exceeded.

In other words, this setting does not enforce a queue limit, but can be
used to make poll functions block if the limit is exceeded.

This is a very bad function to use in interactive programs because it
blocks, and a bad way to reduce concurrency because it is inexact: Better
use an C<aio_group> together with a feed callback.

It's main use is in scripts without an event loop - when you want to stat
a lot of files, you can write somehting like this:

   IO::AIO::max_outstanding 32;

   for my $path (...) {
      aio_stat $path , ...;
      IO::AIO::poll_cb;
   }

   IO::AIO::flush;

The call to C<poll_cb> inside the loop will normally return instantly, but
as soon as more thna C<32> reqeusts are in-flight, it will block until
some requests have been handled. This keeps the loop from pushing a large
number of C<aio_stat> requests onto the queue.

The default value for C<max_outstanding> is very large, so there is no
practical limit on the number of outstanding requests.

=back

=head3 STATISTICAL INFORMATION

=over

=item IO::AIO::nreqs

Returns the number of requests currently in the ready, execute or pending
states (i.e. for which their callback has not been invoked yet).

Example: wait till there are no outstanding requests anymore:

   IO::AIO::poll_wait, IO::AIO::poll_cb
      while IO::AIO::nreqs;

=item IO::AIO::nready

Returns the number of requests currently in the ready state (not yet
executed).

=item IO::AIO::npending

Returns the number of requests currently in the pending state (executed,
but not yet processed by poll_cb).

=back

=head3 MISCELLANEOUS FUNCTIONS

IO::AIO implements some functions that might be useful, but are not
asynchronous.

=over 4

=item IO::AIO::sendfile $ofh, $ifh, $offset, $count

Calls the C<eio_sendfile_sync> function, which is like C<aio_sendfile>,
but is blocking (this makes most sense if you know the input data is
likely cached already and the output filehandle is set to non-blocking
operations).

Returns the number of bytes copied, or C<-1> on error.

=item IO::AIO::fadvise $fh, $offset, $len, $advice

Simply calls the C<posix_fadvise> function (see its
manpage for details). The following advice constants are
available: C<IO::AIO::FADV_NORMAL>, C<IO::AIO::FADV_SEQUENTIAL>,
C<IO::AIO::FADV_RANDOM>, C<IO::AIO::FADV_NOREUSE>,
C<IO::AIO::FADV_WILLNEED>, C<IO::AIO::FADV_DONTNEED>.

On systems that do not implement C<posix_fadvise>, this function returns
ENOSYS, otherwise the return value of C<posix_fadvise>.

=item IO::AIO::madvise $scalar, $offset, $len, $advice

Simply calls the C<posix_madvise> function (see its
manpage for details). The following advice constants are
available: C<IO::AIO::MADV_NORMAL>, C<IO::AIO::MADV_SEQUENTIAL>,
C<IO::AIO::MADV_RANDOM>, C<IO::AIO::MADV_WILLNEED>, C<IO::AIO::MADV_DONTNEED>.

On systems that do not implement C<posix_madvise>, this function returns
ENOSYS, otherwise the return value of C<posix_madvise>.

=item IO::AIO::mprotect $scalar, $offset, $len, $protect

Simply calls the C<mprotect> function on the preferably AIO::mmap'ed
$scalar (see its manpage for details). The following protect
constants are available: C<IO::AIO::PROT_NONE>, C<IO::AIO::PROT_READ>,
C<IO::AIO::PROT_WRITE>, C<IO::AIO::PROT_EXEC>.

On systems that do not implement C<mprotect>, this function returns
ENOSYS, otherwise the return value of C<mprotect>.

=item IO::AIO::mmap $scalar, $length, $prot, $flags, $fh[, $offset]

Memory-maps a file (or anonymous memory range) and attaches it to the
given C<$scalar>, which will act like a string scalar. Returns true on
success, and false otherwise.

The only operations allowed on the scalar are C<substr>/C<vec> that don't
change the string length, and most read-only operations such as copying it
or searching it with regexes and so on.

Anything else is unsafe and will, at best, result in memory leaks.

The memory map associated with the C<$scalar> is automatically removed
when the C<$scalar> is destroyed, or when the C<IO::AIO::mmap> or
C<IO::AIO::munmap> functions are called.

This calls the C<mmap>(2) function internally. See your system's manual
page for details on the C<$length>, C<$prot> and C<$flags> parameters.

The C<$length> must be larger than zero and smaller than the actual
filesize.

C<$prot> is a combination of C<IO::AIO::PROT_NONE>, C<IO::AIO::PROT_EXEC>,
C<IO::AIO::PROT_READ> and/or C<IO::AIO::PROT_WRITE>,

C<$flags> can be a combination of C<IO::AIO::MAP_SHARED> or
C<IO::AIO::MAP_PRIVATE>, or a number of system-specific flags (when
not available, the are defined as 0): C<IO::AIO::MAP_ANONYMOUS>
(which is set to C<MAP_ANON> if your system only provides this
constant), C<IO::AIO::MAP_HUGETLB>, C<IO::AIO::MAP_LOCKED>,
C<IO::AIO::MAP_NORESERVE>, C<IO::AIO::MAP_POPULATE> or
C<IO::AIO::MAP_NONBLOCK>

If C<$fh> is C<undef>, then a file descriptor of C<-1> is passed.

C<$offset> is the offset from the start of the file - it generally must be
a multiple of C<IO::AIO::PAGESIZE> and defaults to C<0>.

Example:

   use Digest::MD5;
   use IO::AIO;

   open my $fh, "<verybigfile"
      or die "$!";

   IO::AIO::mmap my $data, -s $fh, IO::AIO::PROT_READ, IO::AIO::MAP_SHARED, $fh
      or die "verybigfile: $!";

   my $fast_md5 = md5 $data;

=item IO::AIO::munmap $scalar

Removes a previous mmap and undefines the C<$scalar>.

=item IO::AIO::munlock $scalar, $offset = 0, $length = undef

Calls the C<munlock> function, undoing the effects of a previous
C<aio_mlock> call (see its description for details).

=item IO::AIO::munlockall

Calls the C<munlockall> function.

On systems that do not implement C<munlockall>, this function returns
ENOSYS, otherwise the return value of C<munlockall>.

=item IO::AIO::splice $r_fh, $r_off, $w_fh, $w_off, $length, $flags

Calls the GNU/Linux C<splice(2)> syscall, if available. If C<$r_off> or
C<$w_off> are C<undef>, then C<NULL> is passed for these, otherwise they
should be the file offset.

C<$r_fh> and C<$w_fh> should not refer to the same file, as splice might
silently corrupt the data in this case.

The following symbol flag values are available: C<IO::AIO::SPLICE_F_MOVE>,
C<IO::AIO::SPLICE_F_NONBLOCK>, C<IO::AIO::SPLICE_F_MORE> and
C<IO::AIO::SPLICE_F_GIFT>.

See the C<splice(2)> manpage for details.

=item IO::AIO::tee $r_fh, $w_fh, $length, $flags

Calls the GNU/Linux C<tee(2)> syscall, see it's manpage and the
description for C<IO::AIO::splice> above for details.

=item $actual_size = IO::AIO::pipesize $r_fh[, $new_size]

Attempts to query or change the pipe buffer size. Obviously works only
on pipes, and currently works only on GNU/Linux systems, and fails with
C<-1>/C<ENOSYS> everywhere else. If anybody knows how to influence pipe buffer
size on other systems, drop me a note.

=back

=cut

min_parallel 8;

END { flush }

1;

=head1 EVENT LOOP INTEGRATION

It is recommended to use L<AnyEvent::AIO> to integrate IO::AIO
automatically into many event loops:

 # AnyEvent integration (EV, Event, Glib, Tk, POE, urxvt, pureperl...)
 use AnyEvent::AIO;

You can also integrate IO::AIO manually into many event loops, here are
some examples of how to do this:

 # EV integration
 my $aio_w = EV::io IO::AIO::poll_fileno, EV::READ, \&IO::AIO::poll_cb;

 # Event integration
 Event->io (fd => IO::AIO::poll_fileno,
            poll => 'r',
            cb => \&IO::AIO::poll_cb);

 # Glib/Gtk2 integration
 add_watch Glib::IO IO::AIO::poll_fileno,
           in => sub { IO::AIO::poll_cb; 1 };

 # Tk integration
 Tk::Event::IO->fileevent (IO::AIO::poll_fileno, "",
                           readable => \&IO::AIO::poll_cb);

 # Danga::Socket integration
 Danga::Socket->AddOtherFds (IO::AIO::poll_fileno =>
                             \&IO::AIO::poll_cb);

=head2 FORK BEHAVIOUR

Usage of pthreads in a program changes the semantics of fork
considerably. Specifically, only async-safe functions can be called after
fork. Perl doesn't know about this, so in general, you cannot call fork
with defined behaviour in perl if pthreads are involved. IO::AIO uses
pthreads, so this applies, but many other extensions and (for inexplicable
reasons) perl itself often is linked against pthreads, so this limitation
applies to quite a lot of perls.

This module no longer tries to fight your OS, or POSIX. That means IO::AIO
only works in the process that loaded it. Forking is fully supported, but
using IO::AIO in the child is not.

You might get around by not I<using> IO::AIO before (or after)
forking. You could also try to call the L<IO::AIO::reinit> function in the
child:

=over 4

=item IO::AIO::reinit

Abandons all current requests and I/O threads and simply reinitialises all
data structures. This is not an operation supported by any standards, but
happens to work on GNU/Linux and some newer BSD systems.

The only reasonable use for this function is to call it after forking, if
C<IO::AIO> was used in the parent. Calling it while IO::AIO is active in
the process will result in undefined behaviour. Calling it at any time
will also result in any undefined (by POSIX) behaviour.

=back

=head2 MEMORY USAGE

Per-request usage:

Each aio request uses - depending on your architecture - around 100-200
bytes of memory. In addition, stat requests need a stat buffer (possibly
a few hundred bytes), readdir requires a result buffer and so on. Perl
scalars and other data passed into aio requests will also be locked and
will consume memory till the request has entered the done state.

This is not awfully much, so queuing lots of requests is not usually a
problem.

Per-thread usage:

In the execution phase, some aio requests require more memory for
temporary buffers, and each thread requires a stack and other data
structures (usually around 16k-128k, depending on the OS).

=head1 KNOWN BUGS

Known bugs will be fixed in the next release.

=head1 SEE ALSO

L<AnyEvent::AIO> for easy integration into event loops, L<Coro::AIO> for a
more natural syntax.

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

