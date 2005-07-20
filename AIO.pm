=head1 NAME

IO::AIO - Asynchronous Input/Output

=head1 SYNOPSIS

 use IO::AIO;

 aio_open "/etc/passwd", O_RDONLY, 0, sub {
    my ($fh) = @_;
    ...
 };

 aio_unlink "/tmp/file", sub { };

 aio_read $fh, 30000, 1024, $buffer, 0, sub {
    $_[0] > 0 or die "read error: $!";
 };

 # Event
 Event->io (fd => IO::AIO::poll_fileno,
            poll => 'r',
            cb => \&IO::AIO::poll_cb);

 # Glib/Gtk2
 add_watch Glib::IO IO::AIO::poll_fileno,
           in => sub { IO::AIO::poll_cb; 1 };

 # Tk
 Tk::Event::IO->fileevent (IO::AIO::poll_fileno, "",
                           readable => \&IO::AIO::poll_cb);

 # Danga::Socket
 Danga::Socket->AddOtherFds (IO::AIO::poll_fileno =>
                             \&IO::AIO::poll_cb);


=head1 DESCRIPTION

This module implements asynchronous I/O using whatever means your
operating system supports.

Currently, a number of threads are started that execute your read/writes
and signal their completion. You don't need thread support in your libc or
perl, and the threads created by this module will not be visible to the
pthreads library. In the future, this module might make use of the native
aio functions available on many operating systems. However, they are often
not well-supported (Linux doesn't allow them on normal files currently,
for example), and they would only support aio_read and aio_write, so the
remaining functionality would have to be implemented using threads anyway.

Although the module will work with in the presence of other threads, it is
currently not reentrant, so use appropriate locking yourself, always call
C<poll_cb> from within the same thread, or never call C<poll_cb> (or other
C<aio_> functions) recursively.

=cut

package IO::AIO;

use base 'Exporter';

use Fcntl ();

BEGIN {
   $VERSION = 0.9;

   @EXPORT = qw(aio_read aio_write aio_open aio_close aio_stat aio_lstat aio_unlink
                aio_fsync aio_fdatasync aio_readahead);
   @EXPORT_OK = qw(poll_fileno poll_cb min_parallel max_parallel max_outstanding nreqs);

   require XSLoader;
   XSLoader::load IO::AIO, $VERSION;
}

=head1 FUNCTIONS

=head2 AIO FUNCTIONS

All the C<aio_*> calls are more or less thin wrappers around the syscall
with the same name (sans C<aio_>). The arguments are similar or identical,
and they all accept an additional (and optional) C<$callback> argument
which must be a code reference. This code reference will get called with
the syscall return code (e.g. most syscalls return C<-1> on error, unlike
perl, which usually delivers "false") as it's sole argument when the given
syscall has been executed asynchronously.

All functions that expect a filehandle will also accept a file descriptor.

The filenames you pass to these routines I<must> be absolute. The reason
for this is that at the time the request is being executed, the current
working directory could have changed. Alternatively, you can make sure
that you never change the current working directory.

=over 4

=item aio_open $pathname, $flags, $mode, $callback

Asynchronously open or create a file and call the callback with a newly
created filehandle for the file.

The pathname passed to C<aio_open> must be absolute. See API NOTES, above,
for an explanation.

The C<$flags> argument is a bitmask. See the C<Fcntl> module for a
list. They are the same as used by C<sysopen>.

Likewise, C<$mode> specifies the mode of the newly created file, if it
didn't exist and C<O_CREAT> has been given, just like perl's C<sysopen>,
except that it is mandatory (i.e. use C<0> if you don't create new files,
and C<0666> or C<0777> if you do).

Example:

   aio_open "/etc/passwd", O_RDONLY, 0, sub {
      if ($_[0]) {
         print "open successful, fh is $_[0]\n";
         ...
      } else {
         die "open failed: $!\n";
      }
   };

=item aio_close $fh, $callback

Asynchronously close a file and call the callback with the result
code. I<WARNING:> although accepted, you should not pass in a perl
filehandle here, as perl will likely close the file descriptor another
time when the filehandle is destroyed. Normally, you can safely call perls
C<close> or just let filehandles go out of scope.

This is supposed to be a bug in the API, so that might change. It's
therefore best to avoid this function.

=item aio_read  $fh,$offset,$length, $data,$dataoffset,$callback

=item aio_write $fh,$offset,$length, $data,$dataoffset,$callback

Reads or writes C<length> bytes from the specified C<fh> and C<offset>
into the scalar given by C<data> and offset C<dataoffset> and calls the
callback without the actual number of bytes read (or -1 on error, just
like the syscall).

Example: Read 15 bytes at offset 7 into scalar C<$buffer>, starting at
offset C<0> within the scalar:

   aio_read $fh, 7, 15, $buffer, 0, sub {
      $_[0] > 0 or die "read error: $!";
      print "read $_[0] bytes: <$buffer>\n";
   };

=item aio_readahead $fh,$offset,$length, $callback

Asynchronously reads the specified byte range into the page cache, using
the C<readahead> syscall. If that syscall doesn't exist (likely if your OS
isn't Linux) the status will be C<-1> and C<$!> is set to C<ENOSYS>.

C<aio_readahead> populates the page cache with data from a file so that
subsequent reads from that file will not block on disk I/O. The C<$offset>
argument specifies the starting point from which data is to be read and
C<$length> specifies the number of bytes to be read. I/O is performed in
whole pages, so that offset is effectively rounded down to a page boundary
and bytes are read up to the next page boundary greater than or equal to
(off-set+length). C<aio_readahead> does not read beyond the end of the
file. The current file offset of the file is left unchanged.

=item aio_stat  $fh_or_path, $callback

=item aio_lstat $fh, $callback

Works like perl's C<stat> or C<lstat> in void context. The callback will
be called after the stat and the results will be available using C<stat _>
or C<-s _> etc...

The pathname passed to C<aio_stat> must be absolute. See API NOTES, above,
for an explanation.

Currently, the stats are always 64-bit-stats, i.e. instead of returning an
error when stat'ing a large file, the results will be silently truncated
unless perl itself is compiled with large file support.

Example: Print the length of F</etc/passwd>:

   aio_stat "/etc/passwd", sub {
      $_[0] and die "stat failed: $!";
      print "size is ", -s _, "\n";
   };

=item aio_unlink $pathname, $callback

Asynchronously unlink (delete) a file and call the callback with the
result code.

=item aio_fsync $fh, $callback

Asynchronously call fsync on the given filehandle and call the callback
with the fsync result code.

=item aio_fdatasync $fh, $callback

Asynchronously call fdatasync on the given filehandle and call the
callback with the fdatasync result code. Might set C<$!> to C<ENOSYS> if
C<fdatasync> is not available.

=back

=head2 SUPPORT FUNCTIONS

=over 4

=item $fileno = IO::AIO::poll_fileno

Return the I<request result pipe file descriptor>. This filehandle must be
polled for reading by some mechanism outside this module (e.g. Event or
select, see below or the SYNOPSIS). If the pipe becomes readable you have
to call C<poll_cb> to check the results.

See C<poll_cb> for an example.

=item IO::AIO::poll_cb

Process all outstanding events on the result pipe. You have to call this
regularly. Returns the number of events processed. Returns immediately
when no events are outstanding.

Example: Install an Event watcher that automatically calls
IO::AIO::poll_cb with high priority:

   Event->io (fd => IO::AIO::poll_fileno,
              poll => 'r', async => 1,
              cb => \&IO::AIO::poll_cb);

=item IO::AIO::poll_wait

Wait till the result filehandle becomes ready for reading (simply does a
C<select> on the filehandle. This is useful if you want to synchronously wait
for some requests to finish).

See C<nreqs> for an example.

=item IO::AIO::nreqs

Returns the number of requests currently outstanding (i.e. for which their
callback has not been invoked yet).

Example: wait till there are no outstanding requests anymore:

   IO::AIO::poll_wait, IO::AIO::poll_cb
      while IO::AIO::nreqs;

=item IO::AIO::flush

Wait till all outstanding AIO requests have been handled.

Strictly equivalent to:

   IO::AIO::poll_wait, IO::AIO::poll_cb
      while IO::AIO::nreqs;

=item IO::AIO::poll

Waits until some requests have been handled.

Strictly equivalent to:

   IO::AIO::poll_wait, IO::AIO::poll_cb
      if IO::AIO::nreqs;

=item IO::AIO::min_parallel $nthreads

Set the minimum number of AIO threads to C<$nthreads>. The default is
C<1>, which means a single asynchronous operation can be done at one time
(the number of outstanding operations, however, is unlimited).

It is recommended to keep the number of threads low, as some Linux
kernel versions will scale negatively with the number of threads (higher
parallelity => MUCH higher latency). With current Linux 2.6 versions, 4-32
threads should be fine.

Under normal circumstances you don't need to call this function, as this
module automatically starts some threads (the exact number might change,
and is currently 4).

=item IO::AIO::max_parallel $nthreads

Sets the maximum number of AIO threads to C<$nthreads>. If more than
the specified number of threads are currently running, kill them. This
function blocks until the limit is reached.

This module automatically runs C<max_parallel 0> at program end, to ensure
that all threads are killed and that there are no outstanding requests.

Under normal circumstances you don't need to call this function.

=item $oldnreqs = IO::AIO::max_outstanding $nreqs

Sets the maximum number of outstanding requests to C<$nreqs>. If you
try to queue up more than this number of requests, the caller will block until
some requests have been handled.

The default is very large, so normally there is no practical limit. If you
queue up many requests in a loop it it often improves speed if you set
this to a relatively low number, such as C<100>.

Under normal circumstances you don't need to call this function.

=back

=cut

# support function to convert a fd into a perl filehandle
sub _fd2fh {
   return undef if $_[0] < 0;

   # try to be perl5.6-compatible
   local *AIO_FH;
   open AIO_FH, "+<&=$_[0]"
      or return undef;

   *AIO_FH
}

min_parallel 4;

END {
   max_parallel 0;
}

1;

=head1 SEE ALSO

L<Coro>, L<Linux::AIO>.

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

