=head1 NAME

IO::AIO - Asynchronous Input/Output

=head1 SYNOPSIS

 use IO::AIO;

 aio_open "/etc/passwd", O_RDONLY, 0, sub {
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

 # AnyEvent integration
 open my $fh, "<&=" . IO::AIO::poll_fileno or die "$!";
 my $w = AnyEvent->io (fh => $fh, poll => 'r', cb => sub { IO::AIO::poll_cb });

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

=head1 DESCRIPTION

This module implements asynchronous I/O using whatever means your
operating system supports.

Asynchronous means that operations that can normally block your program
(e.g. reading from disk) will be done asynchronously: the operation
will still block, but you can do something else in the meantime. This
is extremely useful for programs that need to stay interactive even
when doing heavy I/O (GUI programs, high performance network servers
etc.), but can also be used to easily do operations in parallel that are
normally done sequentially, e.g. stat'ing many files, which is much faster
on a RAID volume or over NFS when you do a number of stat operations
concurrently.

While most of this works on all types of file descriptors (for example
sockets), using these functions on file descriptors that support
nonblocking operation (again, sockets, pipes etc.) is very inefficient or
might not work (aio_read fails on sockets/pipes/fifos). Use an event loop
for that (such as the L<Event|Event> module): IO::AIO will naturally fit
into such an event loop itself.

In this version, a number of threads are started that execute your
requests and signal their completion. You don't need thread support
in perl, and the threads created by this module will not be visible
to perl. In the future, this module might make use of the native aio
functions available on many operating systems. However, they are often
not well-supported or restricted (GNU/Linux doesn't allow them on normal
files currently, for example), and they would only support aio_read and
aio_write, so the remaining functionality would have to be implemented
using threads anyway.

Although the module will work with in the presence of other (Perl-)
threads, it is currently not reentrant in any way, so use appropriate
locking yourself, always call C<poll_cb> from within the same thread, or
never call C<poll_cb> (or other C<aio_> functions) recursively.

=head2 EXAMPLE

This is a simple example that uses the Event module and loads
F</etc/passwd> asynchronously:

   use Fcntl;
   use Event;
   use IO::AIO;

   # register the IO::AIO callback with Event
   Event->io (fd => IO::AIO::poll_fileno,
              poll => 'r',
              cb => \&IO::AIO::poll_cb);

   # queue the request to open /etc/passwd
   aio_open "/etc/passwd", O_RDONLY, 0, sub {
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
         Event::unloop;
      };
   };

   # possibly queue up other requests, or open GUI windows,
   # check for sockets etc. etc.

   # process events as long as there are some:
   Event::loop;

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

no warnings;
use strict 'vars';

use base 'Exporter';

BEGIN {
   our $VERSION = '2.33';

   our @AIO_REQ = qw(aio_sendfile aio_read aio_write aio_open aio_close aio_stat
                     aio_lstat aio_unlink aio_rmdir aio_readdir aio_scandir aio_symlink
                     aio_readlink aio_fsync aio_fdatasync aio_readahead aio_rename aio_link
                     aio_move aio_copy aio_group aio_nop aio_mknod aio_load aio_rmtree aio_mkdir);
   our @EXPORT = (@AIO_REQ, qw(aioreq_pri aioreq_nice aio_block));
   our @EXPORT_OK = qw(poll_fileno poll_cb poll_wait flush
                       min_parallel max_parallel max_idle
                       nreqs nready npending nthreads
                       max_poll_time max_poll_reqs);

   @IO::AIO::GRP::ISA = 'IO::AIO::REQ';

   require XSLoader;
   XSLoader::load ("IO::AIO", $VERSION);
}

=head1 FUNCTIONS

=head2 AIO REQUEST FUNCTIONS

All the C<aio_*> calls are more or less thin wrappers around the syscall
with the same name (sans C<aio_>). The arguments are similar or identical,
and they all accept an additional (and optional) C<$callback> argument
which must be a code reference. This code reference will get called with
the syscall return code (e.g. most syscalls return C<-1> on error, unlike
perl, which usually delivers "false") as it's sole argument when the given
syscall has been executed asynchronously.

All functions expecting a filehandle keep a copy of the filehandle
internally until the request has finished.

All functions return request objects of type L<IO::AIO::REQ> that allow
further manipulation of those requests while they are in-flight.

The pathnames you pass to these routines I<must> be absolute and
encoded as octets. The reason for the former is that at the time the
request is being executed, the current working directory could have
changed. Alternatively, you can make sure that you never change the
current working directory anywhere in the program and then use relative
paths.

To encode pathnames as octets, either make sure you either: a) always pass
in filenames you got from outside (command line, readdir etc.) without
tinkering, b) are ASCII or ISO 8859-1, c) use the Encode module and encode
your pathnames to the locale (or other) encoding in effect in the user
environment, d) use Glib::filename_from_unicode on unicode filenames or e)
use something else to ensure your scalar has the correct contents.

This works, btw. independent of the internal UTF-8 bit, which IO::AIO
handles correctly wether it is set or not.

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
created filehandle for the file.

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

=item aio_mknod $path, $mode, $dev, $callback->($status)

[EXPERIMENTAL]

Asynchronously create a device node (or fifo). See mknod(2).

The only (POSIX-) portable way of calling this function is:

   aio_mknod $path, IO::AIO::S_IFIFO | $mode, 0, sub { ...

=item aio_link $srcpath, $dstpath, $callback->($status)

Asynchronously create a new link to the existing object at C<$srcpath> at
the path C<$dstpath> and call the callback with the result code.

=item aio_symlink $srcpath, $dstpath, $callback->($status)

Asynchronously create a new symbolic link to the existing object at C<$srcpath> at
the path C<$dstpath> and call the callback with the result code.

=item aio_readlink $path, $callback->($link)

Asynchronously read the symlink specified by C<$path> and pass it to
the callback. If an error occurs, nothing or undef gets passed to the
callback.

=item aio_rename $srcpath, $dstpath, $callback->($status)

Asynchronously rename the object at C<$srcpath> to C<$dstpath>, just as
rename(2) and call the callback with the result code.

=item aio_mkdir $pathname, $mode, $callback->($status)

Asynchronously mkdir (create) a directory and call the callback with
the result code. C<$mode> will be modified by the umask at the time the
request is executed, so do not change your umask.

=item aio_rmdir $pathname, $callback->($status)

Asynchronously rmdir (delete) a directory and call the callback with the
result code.

=item aio_readdir $pathname, $callback->($entries)

Unlike the POSIX call of the same name, C<aio_readdir> reads an entire
directory (i.e. opendir + readdir + closedir). The entries will not be
sorted, and will B<NOT> include the C<.> and C<..> entries.

The callback a single argument which is either C<undef> or an array-ref
with the filenames.

=item aio_load $path, $data, $callback->($status)

This is a composite request that tries to fully load the given file into
memory. Status is the same as with aio_read.

=cut

sub aio_load($$;$) {
   aio_block {
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
}

=item aio_copy $srcpath, $dstpath, $callback->($status)

Try to copy the I<file> (directories not supported as either source or
destination) from C<$srcpath> to C<$dstpath> and call the callback with
the C<0> (error) or C<-1> ok.

This is a composite request that it creates the destination file with
mode 0200 and copies the contents of the source file into it using
C<aio_sendfile>, followed by restoring atime, mtime, access mode and
uid/gid, in that order.

If an error occurs, the partial destination file will be unlinked, if
possible, except when setting atime, mtime, access mode and uid/gid, where
errors are being ignored.

=cut

sub aio_copy($$;$) {
   aio_block {
      my ($src, $dst, $cb) = @_;

      my $pri = aioreq_pri;
      my $grp = aio_group $cb;

      aioreq_pri $pri;
      add $grp aio_open $src, O_RDONLY, 0, sub {
         if (my $src_fh = $_[0]) {
            my @stat = stat $src_fh;

            aioreq_pri $pri;
            add $grp aio_open $dst, O_CREAT | O_WRONLY | O_TRUNC, 0200, sub {
               if (my $dst_fh = $_[0]) {
                  aioreq_pri $pri;
                  add $grp aio_sendfile $dst_fh, $src_fh, 0, $stat[7], sub {
                     if ($_[0] == $stat[7]) {
                        $grp->result (0);
                        close $src_fh;

                        # those should not normally block. should. should.
                        utime $stat[8], $stat[9], $dst;
                        chmod $stat[2] & 07777, $dst_fh;
                        chown $stat[4], $stat[5], $dst_fh;
                        close $dst_fh;
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
}

=item aio_move $srcpath, $dstpath, $callback->($status)

Try to move the I<file> (directories not supported as either source or
destination) from C<$srcpath> to C<$dstpath> and call the callback with
the C<0> (error) or C<-1> ok.

This is a composite request that tries to rename(2) the file first. If
rename files with C<EXDEV>, it copies the file with C<aio_copy> and, if
that is successful, unlinking the C<$srcpath>.

=cut

sub aio_move($$;$) {
   aio_block {
      my ($src, $dst, $cb) = @_;

      my $pri = aioreq_pri;
      my $grp = aio_group $cb;

      aioreq_pri $pri;
      add $grp aio_rename $src, $dst, sub {
         if ($_[0] && $! == EXDEV) {
            aioreq_pri $pri;
            add $grp aio_copy $src, $dst, sub {
               $grp->result ($_[0]);

               if (!$_[0]) {
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
}

=item aio_scandir $path, $maxreq, $callback->($dirs, $nondirs)

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

After reading the directory, the modification time, size etc. of the
directory before and after the readdir is checked, and if they match (and
isn't the current time), the link count will be used to decide how many
entries are directories (if >= 2). Otherwise, no knowledge of the number
of subdirectories will be assumed.

Then entries will be sorted into likely directories (everything without
a non-initial dot currently) and likely non-directories (everything
else). Then every entry plus an appended C</.> will be C<stat>'ed,
likely directories first. If that succeeds, it assumes that the entry
is a directory or a symlink to directory (which will be checked
seperately). This is often faster than stat'ing the entry itself because
filesystems might detect the type of the entry without reading the inode
data (e.g. ext2fs filetype feature).

If the known number of directories (link count - 2) has been reached, the
rest of the entries is assumed to be non-directories.

This only works with certainty on POSIX (= UNIX) filesystems, which
fortunately are the vast majority of filesystems around.

It will also likely work on non-POSIX filesystems with reduced efficiency
as those tend to return 0 or 1 as link counts, which disables the
directory counting heuristic.

=cut

sub aio_scandir($$;$) {
   aio_block {
      my ($path, $maxreq, $cb) = @_;

      my $pri = aioreq_pri;

      my $grp = aio_group $cb;

      $maxreq = 4 if $maxreq <= 0;

      # stat once
      aioreq_pri $pri;
      add $grp aio_stat $path, sub {
         return $grp->result () if $_[0];
         my $now = time;
         my $hash1 = join ":", (stat _)[0,1,3,7,9];

         # read the directory entries
         aioreq_pri $pri;
         add $grp aio_readdir $path, sub {
            my $entries = shift
               or return $grp->result ();

            # stat the dir another time
            aioreq_pri $pri;
            add $grp aio_stat $path, sub {
               my $hash2 = join ":", (stat _)[0,1,3,7,9];

               my $ndirs;

               # take the slow route if anything looks fishy
               if ($hash1 ne $hash2 or (stat _)[9] == $now) {
                  $ndirs = -1;
               } else {
                  # if nlink == 2, we are finished
                  # on non-posix-fs's, we rely on nlink < 2
                  $ndirs = (stat _)[3] - 2
                     or return $grp->result ([], $entries);
               }

               # sort into likely dirs and likely nondirs
               # dirs == files without ".", short entries first
               $entries = [map $_->[0],
                              sort { $b->[1] cmp $a->[1] }
                                 map [$_, sprintf "%s%04d", (/.\./ ? "1" : "0"), length],
                                    @$entries];

               my (@dirs, @nondirs);

               my $statgrp = add $grp aio_group sub {
                  $grp->result (\@dirs, \@nondirs);
               };

               limit $statgrp $maxreq;
               feed $statgrp sub {
                  return unless @$entries;
                  my $entry = pop @$entries;

                  aioreq_pri $pri;
                  add $statgrp aio_stat "$path/$entry/.", sub {
                     if ($_[0] < 0) {
                        push @nondirs, $entry;
                     } else {
                        # need to check for real directory
                        aioreq_pri $pri;
                        add $statgrp aio_lstat "$path/$entry", sub {
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

      $grp
   }
}

=item aio_rmtree $path, $callback->($status)

Delete a directory tree starting (and including) C<$path>, return the
status of the final C<rmdir> only.  This is a composite request that
uses C<aio_scandir> to recurse into and rmdir directories, and unlink
everything else.

=cut

sub aio_rmtree;
sub aio_rmtree($;$) {
   aio_block {
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
}

=item aio_fsync $fh, $callback->($status)

Asynchronously call fsync on the given filehandle and call the callback
with the fsync result code.

=item aio_fdatasync $fh, $callback->($status)

Asynchronously call fdatasync on the given filehandle and call the
callback with the fdatasync result code.

If this call isn't available because your OS lacks it or it couldn't be
detected, it will be emulated by calling C<fsync> instead.

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

=head2 IO::AIO::REQ CLASS

All non-aggregate C<aio_*> functions return an object of this class when
called in non-void context.

=over 4

=item cancel $req

Cancels the request, if possible. Has the effect of skipping execution
when entering the B<execute> state and skipping calling the callback when
entering the the B<result> state, but will leave the request otherwise
untouched. That means that requests that currently execute will not be
stopped and resources held by the request will not be freed prematurely.

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

That means after creating a group you have some time to add requests. And
in the callbacks of those requests, you can add further requests to the
group. And only when all those requests have finished will the the group
itself finish.

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

=item $grp->result (...)

Set the result value(s) that will be passed to the group callback when all
subrequests have finished and set thre groups errno to the current value
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
this might starve other requests for a potentially long time.  For
example, C<aio_scandir> might generate hundreds of thousands C<aio_stat>
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

If the feed limit is C<0>, it will be set to C<2> automatically.

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

=back

=head2 SUPPORT FUNCTIONS

=head3 EVENT PROCESSING AND EVENT LOOP INTEGRATION

=over 4

=item $fileno = IO::AIO::poll_fileno

Return the I<request result pipe file descriptor>. This filehandle must be
polled for reading by some mechanism outside this module (e.g. Event or
select, see below or the SYNOPSIS). If the pipe becomes readable you have
to call C<poll_cb> to check the results.

See C<poll_cb> for an example.

=item IO::AIO::poll_cb

Process some outstanding events on the result pipe. You have to call this
regularly. Returns the number of events processed. Returns immediately
when no events are outstanding. The amount of events processed depends on
the settings of C<IO::AIO::max_poll_req> and C<IO::AIO::max_poll_time>.

If not all requests were processed for whatever reason, the filehandle
will still be ready when C<poll_cb> returns.

Example: Install an Event watcher that automatically calls
IO::AIO::poll_cb with high priority:

   Event->io (fd => IO::AIO::poll_fileno,
              poll => 'r', async => 1,
              cb => \&IO::AIO::poll_cb);

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

=item IO::AIO::poll_wait

If there are any outstanding requests and none of them in the result
phase, wait till the result filehandle becomes ready for reading (simply
does a C<select> on the filehandle. This is useful if you want to
synchronously wait for some requests to finish).

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

=head3 CONTROLLING THE NUMBER OF THREADS

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

Limit the number of threads (default: 4) that are allowed to idle (i.e.,
threads that did not get a request to process within 10 seconds). That
means if a thread becomes idle while C<$nthreads> other threads are also
idle, it will free its resources and exit.

This is useful when you allow a large number of threads (e.g. 100 or 1000)
to allow for extremely high load situations, but want to free resources
under normal circumstances (1000 threads can easily consume 30MB of RAM).

The default is probably ok in most situations, especially if thread
creation is fast. If thread creation is very slow on your system you might
want to use larger values.

=item $oldmaxreqs = IO::AIO::max_outstanding $maxreqs

This is a very bad function to use in interactive programs because it
blocks, and a bad way to reduce concurrency because it is inexact: Better
use an C<aio_group> together with a feed callback.

Sets the maximum number of outstanding requests to C<$nreqs>. If you
to queue up more than this number of requests, the next call to the
C<poll_cb> (and C<poll_some> and other functions calling C<poll_cb>)
function will block until the limit is no longer exceeded.

The default value is very large, so there is no practical limit on the
number of outstanding requests.

You can still queue as many requests as you want. Therefore,
C<max_oustsanding> is mainly useful in simple scripts (with low values) or
as a stop gap to shield against fatal memory overflow (with large values).

=head3 STATISTICAL INFORMATION

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

min_parallel 8;

END { flush }

1;

=head2 FORK BEHAVIOUR

This module should do "the right thing" when the process using it forks:

Before the fork, IO::AIO enters a quiescent state where no requests
can be added in other threads and no results will be processed. After
the fork the parent simply leaves the quiescent state and continues
request/result processing, while the child frees the request/result queue
(so that the requests started before the fork will only be handled in the
parent). Threads will be started on demand until the limit set in the
parent process has been reached again.

In short: the parent will, after a short pause, continue as if fork had
not been called, while the child will act as if IO::AIO has not been used
yet.

=head2 MEMORY USAGE

Per-request usage:

Each aio request uses - depending on your architecture - around 100-200
bytes of memory. In addition, stat requests need a stat buffer (possibly
a few hundred bytes), readdir requires a result buffer and so on. Perl
scalars and other data passed into aio requests will also be locked and
will consume memory till the request has entered the done state.

This is now awfully much, so queuing lots of requests is not usually a
problem.

Per-thread usage:

In the execution phase, some aio requests require more memory for
temporary buffers, and each thread requires a stack and other data
structures (usually around 16k-128k, depending on the OS).

=head1 KNOWN BUGS

Known bugs will be fixed in the next release.

=head1 SEE ALSO

L<Coro::AIO>.

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

