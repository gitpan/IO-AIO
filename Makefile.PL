use ExtUtils::MakeMaker;

use Config;

require "autoconf.pm";

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

my $mm = MM->new({
    dist         => {
       PREOP	=> 'pod2text AIO.pm | tee README >$(DISTVNAME)/README; chmod -R u=rwX,go=rX . ;',
       COMPRESS	=> 'gzip -9v',
       SUFFIX	=> '.gz',
	            },
    NAME         => "IO::AIO",
    VERSION_FROM => "AIO.pm",
    LIBS         => ['-lpthread -lrt', '-lpthread', '-lpthreads', ''],
    clean        => { FILES => "autoconf/config.h autoconf/config.log autoconf/config.status" },
});

$mm->flush;

