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

 # AnyEvent
 open my $fh, "<&=" . IO::AIO::poll_fileno or die "$!";
 my $w = AnyEvent->io (fh => $fh, poll => 'r', cb => sub { IO::AIO::poll_cb });

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

no warnings;
use strict 'vars';

use base 'Exporter';

BEGIN {
   our $VERSION = '1.8';

   our @EXPORT = qw(aio_sendfile aio_read aio_write aio_open aio_close aio_stat
                    aio_lstat aio_unlink aio_rmdir aio_readdir aio_scandir aio_symlink
                    aio_fsync aio_fdatasync aio_readahead aio_rename aio_link aio_move);
   our @EXPORT_OK = qw(poll_fileno poll_cb min_parallel max_parallel max_outstanding nreqs);

   require XSLoader;
   XSLoader::load ("IO::AIO", $VERSION);
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

All functions expecting a filehandle keep a copy of the filehandle
internally until the request has finished.

The pathnames you pass to these routines I<must> be absolute and
encoded in byte form. The reason for the former is that at the time the
request is being executed, the current working directory could have
changed. Alternatively, you can make sure that you never change the
current working directory.

To encode pathnames to byte form, either make sure you either: a)
always pass in filenames you got from outside (command line, readdir
etc.), b) are ASCII or ISO 8859-1, c) use the Encode module and encode
your pathnames to the locale (or other) encoding in effect in the user
environment, d) use Glib::filename_from_unicode on unicode filenames or e)
use something else.

=over 4

=item aio_open $pathname, $flags, $mode, $callback->($fh)

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

=item aio_close $fh, $callback->($status)

Asynchronously close a file and call the callback with the result
code. I<WARNING:> although accepted, you should not pass in a perl
filehandle here, as perl will likely close the file descriptor another
time when the filehandle is destroyed. Normally, you can safely call perls
C<close> or just let filehandles go out of scope.

This is supposed to be a bug in the API, so that might change. It's
therefore best to avoid this function.

=item aio_read  $fh,$offset,$length, $data,$dataoffset, $callback->($retval)

=item aio_write $fh,$offset,$length, $data,$dataoffset, $callback->($retval)

Reads or writes C<length> bytes from the specified C<fh> and C<offset>
into the scalar given by C<data> and offset C<dataoffset> and calls the
callback without the actual number of bytes read (or -1 on error, just
like the syscall).

The C<$data> scalar I<MUST NOT> be modified in any way while the request
is outstanding. Modifying it can result in segfaults or WW3 (if the
necessary/optional hardware is installed).

Example: Read 15 bytes at offset 7 into scalar C<$buffer>, starting at
offset C<0> within the scalar:

   aio_read $fh, 7, 15, $buffer, 0, sub {
      $_[0] > 0 or die "read error: $!";
      print "read $_[0] bytes: <$buffer>\n";
   };

=item aio_move $srcpath, $dstpath, $callback->($status)

[EXPERIMENTAL]

Try to move the I<file> (directories not supported as either source or destination)
from C<$srcpath> to C<$dstpath> and call the callback with the C<0> (error) or C<-1> ok.

This is a composite request that tries to rename(2) the file first. If
rename files with C<EXDEV>, it creates the destination file with mode 0200
and copies the contents of the source file into it using C<aio_sendfile>,
followed by restoring atime, mtime, access mode and uid/gid, in that
order, and unlinking the C<$srcpath>.

If an error occurs, the partial destination file will be unlinked, if
possible, except when setting atime, mtime, access mode and uid/gid, where
errors are being ignored.

=cut

sub aio_move($$$) {
   my ($src, $dst, $cb) = @_;

   aio_rename $src, $dst, sub {
      if ($_[0] && $! == EXDEV) {
         aio_open $src, O_RDONLY, 0, sub {
            if (my $src_fh = $_[0]) {
               my @stat = stat $src_fh;

               aio_open $dst, O_WRONLY, 0200, sub {
                  if (my $dst_fh = $_[0]) {
                     aio_sendfile $dst_fh, $src_fh, 0, $stat[7], sub {
                        close $src_fh;

                        if ($_[0] == $stat[7]) {
                           utime $stat[8], $stat[9], $dst;
                           chmod $stat[2] & 07777, $dst_fh;
                           chown $stat[4], $stat[5], $dst_fh;
                           close $dst_fh;

                           aio_unlink $src, sub {
                              $cb->($_[0]);
                           };
                        } else {
                           my $errno = $!;
                           aio_unlink $dst, sub {
                              $! = $errno;
                              $cb->(-1);
                           };
                        }
                     };
                  } else {
                     $cb->(-1);
                  }
               },

            } else {
               $cb->(-1);
            }
         };
      } else {
         $cb->($_[0]);
      }
   };
}

=item aio_sendfile $out_fh, $in_fh, $in_offset, $length, $callback->($retval)

Tries to copy C<$length> bytes from C<$in_fh> to C<$out_fh>. It starts
reading at byte offset C<$in_offset>, and starts writing at the current
file offset of C<$out_fh>. Because of that, it is not safe to issue more
than one C<aio_sendfile> per C<$out_fh>, as they will interfere with each
other.

This call tries to make use of a native C<sendfile> syscall to provide
zero-copy operation. For this to work, C<$out_fh> should refer to a
socket, and C<$in_fh> should refer to mmap'able file.

If the native sendfile call fails or is not implemented, it will be
emulated, so you can call C<aio_sendfile> on any type of filehandle
regardless of the limitations of the operating system.

Please note, however, that C<aio_sendfile> can read more bytes from
C<$in_fh> than are written, and there is no way to find out how many
bytes have been read from C<aio_sendfile> alone, as C<aio_sendfile> only
provides the number of bytes written to C<$out_fh>. Only if the result
value equals C<$length> one can assume that C<$length> bytes have been
read.

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

Example: Print the length of F</etc/passwd>:

   aio_stat "/etc/passwd", sub {
      $_[0] and die "stat failed: $!";
      print "size is ", -s _, "\n";
   };

=item aio_unlink $pathname, $callback->($status)

Asynchronously unlink (delete) a file and call the callback with the
result code.

=item aio_link $srcpath, $dstpath, $callback->($status)

Asynchronously create a new link to the existing object at C<$srcpath> at
the path C<$dstpath> and call the callback with the result code.

=item aio_symlink $srcpath, $dstpath, $callback->($status)

Asynchronously create a new symbolic link to the existing object at C<$srcpath> at
the path C<$dstpath> and call the callback with the result code.

=item aio_rename $srcpath, $dstpath, $callback->($status)

Asynchronously rename the object at C<$srcpath> to C<$dstpath>, just as
rename(2) and call the callback with the result code.

=item aio_rmdir $pathname, $callback->($status)

Asynchronously rmdir (delete) a directory and call the callback with the
result code.

=item aio_readdir $pathname, $callback->($entries)

Unlike the POSIX call of the same name, C<aio_readdir> reads an entire
directory (i.e. opendir + readdir + closedir). The entries will not be
sorted, and will B<NOT> include the C<.> and C<..> entries.

The callback a single argument which is either C<undef> or an array-ref
with the filenames.

=item aio_scandir $path, $maxreq, $callback->($dirs, $nondirs)

Scans a directory (similar to C<aio_readdir>) and tries to separate the
entries of directory C<$path> into two sets of names, ones you can recurse
into (directories), and ones you cannot recurse into (everything else).

C<aio_scandir> is a composite request that consists of many
aio-primitives. C<$maxreq> specifies the maximum number of outstanding
aio requests that this function generates. If it is C<< <= 0 >>, then a
suitable default will be chosen (currently 8).

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

After reading the directory, the modification time, size etc. of the
directory before and after the readdir is checked, and if they match, the
link count will be used to decide how many entries are directories (if
>= 2). Otherwise, no knowledge of the number of subdirectories will be
assumed.

Then entires will be sorted into likely directories (everything without a
non-initial dot) and likely non-directories (everything else).  Then every
entry + C</.> will be C<stat>'ed, likely directories first. This is often
faster because filesystems might detect the type of the entry without
reading the inode data (e.g. ext2fs filetype feature). If that succeeds,
it assumes that the entry is a directory or a symlink to directory (which
will be checked seperately).

If the known number of directories has been reached, the rest of the
entries is assumed to be non-directories.

=cut

sub aio_scandir($$$) {
   my ($path, $maxreq, $cb) = @_;

   $maxreq = 8 if $maxreq <= 0;

   # stat once
   aio_stat $path, sub {
      return $cb->() if $_[0];
      my $hash1 = join ":", (stat _)[0,1,3,7,9];

      # read the directory entries
      aio_readdir $path, sub {
         my $entries = shift
            or return $cb->();

         # stat the dir another time
         aio_stat $path, sub {
            my $hash2 = join ":", (stat _)[0,1,3,7,9];

            my $ndirs;

            # take the slow route if anything looks fishy
            if ($hash1 ne $hash2) {
               $ndirs = -1;
            } else {
               # if nlink == 2, we are finished
               # on non-posix-fs's, we rely on nlink < 2
               $ndirs = (stat _)[3] - 2
                  or return $cb->([], $entries);
            }

            # sort into likely dirs and likely nondirs
            # dirs == files without ".", short entries first
            $entries = [map $_->[0],
                           sort { $b->[1] cmp $a->[1] }
                              map [$_, sprintf "%s%04d", (/.\./ ? "1" : "0"), length],
                                 @$entries];

            my (@dirs, @nondirs);

            my ($statcb, $schedcb);
            my $nreq = 0;

            $schedcb = sub {
               if (@$entries) {
                  if ($nreq < $maxreq) {
                     my $ent = pop @$entries;
                     $nreq++;
                     aio_stat "$path/$ent/.", sub { $statcb->($_[0], $ent) };
                  }
               } elsif (!$nreq) {
                  # finished
                  undef $statcb;
                  undef $schedcb;
                  $cb->(\@dirs, \@nondirs) if $cb;
                  undef $cb;
               }
            };
            $statcb = sub {
               my ($status, $entry) = @_;

               if ($status < 0) {
                  $nreq--;
                  push @nondirs, $entry;
                  &$schedcb;
               } else {
                  # need to check for real directory
                  aio_lstat "$path/$entry", sub {
                     $nreq--;

                     if (-d _) {
                        push @dirs, $entry;

                        if (!--$ndirs) {
                           push @nondirs, @$entries;
                           $entries = [];
                        }
                     } else {
                        push @nondirs, $entry;
                     }

                     &$schedcb;
                  }
               }
            };

            &$schedcb while @$entries && $nreq < $maxreq;
         };
      };
   };
}

=item aio_fsync $fh, $callback->($status)

Asynchronously call fsync on the given filehandle and call the callback
with the fsync result code.

=item aio_fdatasync $fh, $callback->($status)

Asynchronously call fdatasync on the given filehandle and call the
callback with the fdatasync result code.

If this call isn't available because your OS lacks it or it couldn't be
detected, it will be emulated by calling C<fsync> instead.

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

Set the minimum number of AIO threads to C<$nthreads>. The current default
is C<4>, which means four asynchronous operations can be done at one time
(the number of outstanding operations, however, is unlimited).

IO::AIO starts threads only on demand, when an AIO request is queued and
no free thread exists.

It is recommended to keep the number of threads low, as some Linux
kernel versions will scale negatively with the number of threads (higher
parallelity => MUCH higher latency). With current Linux 2.6 versions, 4-32
threads should be fine.

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

=item $oldnreqs = IO::AIO::max_outstanding $nreqs

Sets the maximum number of outstanding requests to C<$nreqs>. If you
try to queue up more than this number of requests, the caller will block until
some requests have been handled.

The default is very large, so normally there is no practical limit. If you
queue up many requests in a loop it often improves speed if you set
this to a relatively low number, such as C<100>.

Under normal circumstances you don't need to call this function.

=back

=cut

# support function to convert a fd into a perl filehandle
sub _fd2fh {
   return undef if $_[0] < 0;

   # try to generate nice filehandles
   my $sym = "IO::AIO::fd#$_[0]";
   local *$sym;

   open *$sym, "+<&=$_[0]"      # usually works under any unix
      or open *$sym, "<&=$_[0]" # cygwin needs this
      or open *$sym, ">&=$_[0]" # or this
      or return undef;

   *$sym
}

min_parallel 4;

END {
   max_parallel 0;
}

1;

=head2 FORK BEHAVIOUR

Before the fork, IO::AIO enters a quiescent state where no requests
can be added in other threads and no results will be processed. After
the fork the parent simply leaves the quiescent state and continues
request/result processing, while the child clears the request/result
queue (so the requests started before the fork will only be handled in
the parent). Threats will be started on demand until the limit ste in the
parent process has been reached again.

=head1 SEE ALSO

L<Coro>, L<Linux::AIO>.

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

