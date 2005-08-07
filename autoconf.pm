package autoconf;

# I plan to improve this and make it a standalone ExtUtils::Autoconf module,
# but right now it just runs an external configure script.

use Config;

sub run_script(;$$) {
    my ($wd, $file) = @_;
    $wd     ||= "autoconf";
    $script ||= "./configure";

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

    my $status = system $ENV{SHELL}, -c => "cd \Q$wd\E && \Q$script\E --prefix \Q$Config{prefix}\E";
}

1
