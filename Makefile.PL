use v5.8.8;

use ExtUtils::MakeMaker;

use Config;

if ($^O =~ /win32/i or $^O =~ /mswin/) {

   # configuration on windows is hardcoded - as always

   warn "your platform is not standards-compliant, you have to port this module first\n";
   warn "using some hardcoded config that will not work on your system\n";

   $INC  = "-I/Perl/lib/CORE -I/sdk/include -I/vc98/include -I/gtk/include -I/gtk/include/pango-1.0 -I/gtk/include/glib-2.0 -I/gtk/lib/glib-2.0/include/ -I/gtk/include/freetype2";
   $LIBS = ["-L/gtk/lib -lpthreadVC2"];

} else {

   $INC  = "";
   $LIBS = ['-lpthread', '-lpthreads', '-lpthreadVC2', ''];

   if ($^O =~ /freebsd/i) {
      print <<EOF;

This package seems to deadlock or otherwise misbehave under FreeBSD. As
documentation on FreeBSD threading is sorely lacking and confusing, I'll
just call FreeBSD broken with regards to threading.

If you find out whats wrong, please tell me.

Some people had luck with using OPTIMIZE=-O instead of -O2, so you might
want to try that.

EOF
   }

   {
      local %ENV = %ENV;

      while (my ($k, $v) = each %Config) {
         $ENV{$k} = $v;
      }

      $ENV{MAKE}     = $Config{make};
      $ENV{SHELL}    = $Config{sh};
      $ENV{CC}       = $Config{cc};
      $ENV{CPPFLAGS} = $Config{cppflags};
      $ENV{CFLAGS}   = $Config{ccflags};
      $ENV{LDFLAGS}  = $Config{ldflags};
      $ENV{LIBS}     = $Config{libs};
      $ENV{LINKER}   = $Config{ld}; # nonstandard

      system $ENV{SHELL}, -c => "./configure --prefix \Q$Config{prefixexp}\E"
         and exit $? >> 8;
   }
}

if ($^O =~ /linux/ && $Config{usemymalloc} eq "y") {
   print <<EOF;

***
*** WARNING:
***
*** Your perl uses it's own memory allocator (-Dusemymalloc=y),
*** which is known not to be threadsafe on GNU/Linux and probably
*** other platforms (even when not used concurrently, it trashes
*** the data structures of the system malloc running concurrently),
*** for perls up to 5.8.8 and possibly later versions.
***
*** If you are unsure wether your perl has been fixed, your system
*** is safe for other reasons, or you experience spurious segfaults,
*** please compile your perl with -Dusemymalloc=n.
***

EOF
}

my $mm = MM->new({
    dist         => {
       PREOP	=> 'pod2text AIO.pm | tee README >$(DISTVNAME)/README; chmod -R u=rwX,go=rX . ;',
       COMPRESS	=> 'gzip -9v',
       SUFFIX	=> '.gz',
	            },
    depend => {
       "AIO.c" => "libeio/eio.h libeio/xthread.h libeio/eio.c libeio/config.h",
    },
    NAME         => "IO::AIO",
    VERSION_FROM => "AIO.pm",
    INC          => $INC,
    LIBS         => $LIBS,
    PM           => {
    		    'AIO.pm'		=> '$(INST_LIBDIR)/AIO.pm',
                    },
    clean        => { FILES => "libeio/config.h libeio/config.log libeio/config.status" },
});

$mm->flush;

