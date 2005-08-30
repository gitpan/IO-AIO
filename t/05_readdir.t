#!/usr/bin/perl

use Test;
use IO::AIO;

# this is a lame test, but....

BEGIN { plan tests => 8 }

my %f;
ok ((opendir my $dir, "."), 1, "$!");
$f{$_}++ for readdir $dir;

my %x = %f;

aio_readdir ".", sub {
   delete $x{"."};
   delete $x{".."};
   if ($_[0]) {
      ok (1);
      my $ok = 1;
      $ok &&= delete $x{$_} for @{$_[0]};
      ok ($ok);
      ok (!scalar keys %x);
   } else {
      ok (0,1,"$!");
   }
};

IO::AIO::poll;

%x = %f;

aio_scandir ".", 0, sub {
   delete $x{"."};
   delete $x{".."};
   if (@_) {
      ok (1);
      my $ok = 1;
      $ok &&= delete $x{$_} for (@{$_[0]}, @{$_[1]});
      ok ($ok);
      ok (!scalar keys %x);
   } else {
      ok (0,1,"$!");
   }
};

IO::AIO::poll while IO::AIO::nreqs;

ok (1);

