use ExtUtils::MakeMaker;

use Config;

require "autoconf.pm";

if ($^O =~ /win32/i or $^O =~ /mswin/) {

   # configuration on windows is hardcoded - as always

   die "your platform is not standards-compliant, you have to port this module first\n";#d#

} else {

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

   autoconf::run_script()
      and die "\nconfigure failed, check it's output above and autoconf/config.log\n\n";
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
    NAME         => "IO::AIO",
    VERSION_FROM => "AIO.pm",
    LIBS         => ['-lpthread -lrt', '-lpthread', '-lpthreads', ''],
    PM           => {
    		    'AIO.pm'		=> '$(INST_LIBDIR)/IO/AIO.pm',
                    },
    clean        => { FILES => "autoconf/config.h autoconf/config.log autoconf/config.status" },
});

$mm->flush;

