use ExtUtils::MakeMaker;

use Config;

require "autoconf.pm";

if ($^O =~ /freebsd/i) {
   print <<EOF;

This package seems to deadlock under FreeBSD. As documentation on FreeBSD
threading is sorely lacking and confusing, I'll just call FreeBSD broken
with regards to threading.

If you get it to work, tell me how (maybe you need to specify magical link
flags despite man pthread telling me otherwise, maybe yo need special
library, maybe you need magical preprocessor symbols, maybe you need to
recompile or re-link perl with threads enabled (a bad idea) - I have no
idea, and I no longer care). Or maybe I do, but am frustrated about the
continous "we are different=broken" attitude.

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

