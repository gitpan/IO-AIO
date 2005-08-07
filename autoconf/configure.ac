AC_PREREQ(2.59)
AC_INIT
AC_CONFIG_HEADERS([config.h])

AC_PROG_CC

AC_CACHE_CHECK(for readahead, ac_cv_readahead, [AC_LINK_IFELSE([
#include <fcntl.h>
int main(void)
{
   int fd = 0;
   off64_t offset = 1;
   size_t count = 2;
   ssize_t res;
   res = readahead (fd, offset, count);
   return 0;
}
],ac_cv_readahead=yes,ac_cv_readahead=no)])
test $ac_cv_readahead = yes && AC_DEFINE(HAVE_READAHEAD, 1, readahead(2) is available (linux))

AC_CACHE_CHECK(for fdatasync, ac_cv_fdatasync, [AC_LINK_IFELSE([
#include <unistd.h>
int main(void)
{
   int fd = 0;
   fdatasync (fd);
   return 0;
}
],ac_cv_fdatasync=yes,ac_cv_fdatasync=no)])
test $ac_cv_fdatasync = yes && AC_DEFINE(HAVE_FDATASYNC, 1, fdatasync(2) is available)

AC_CACHE_CHECK(for pread and pwrite, ac_cv_preadwrite, [AC_LINK_IFELSE([
#include <unistd.h>
int main(void)
{
   int fd = 0;
   size_t count = 1;
   char buf;
   off_t offset = 1;
   ssize_t res;
   res = pread (fd, &buf, count, offset);
   res = pwrite (fd, &buf, count, offset);
   return 0;
}
],ac_cv_preadwrite=yes,ac_cv_preadwrite=no)])
test $ac_cv_preadwrite = yes && AC_DEFINE(HAVE_PREADWRITE, 1, pread(2) and pwrite(2) are available)

AC_OUTPUT
