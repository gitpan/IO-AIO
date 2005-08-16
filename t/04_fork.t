#!/usr/bin/perl

use Test;
use IO::AIO;

# this is a lame test, but....

BEGIN { plan tests => 9 }

IO::AIO::min_parallel 2;

print "ok 1\n";

aio_stat "/", sub {
   print "ok 2\n"; # pre-fork
};

if (open FH, "-|") {
   print while <FH>;
   aio_stat "/", sub {
      print "ok 7\n";
   };
   print "ok 6\n";
   IO::AIO::poll;
   print "ok 8\n";
} else {
   print "ok 3\n";
   aio_stat "/", sub {
      print "ok 4\n";
   };
   IO::AIO::poll;
   print "ok 5\n";
   exit;
}

print "ok 9\n";

