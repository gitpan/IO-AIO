#include "libeio/xthread.h"

#include <errno.h>

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <stddef.h>
#include <stdlib.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <limits.h>
#include <fcntl.h>
#include <sched.h>

/* perl namespace pollution */
#undef VERSION

#ifdef _WIN32

# define EIO_STRUCT_DIRENT Direntry_t
# undef malloc
# undef free

// perl overrides all those nice win32 functions
# undef open
# undef read
# undef write
# undef send
# undef recv
# undef stat
# undef fstat
# define lstat stat
# undef truncate
# undef ftruncate
# undef open
# undef close
# undef unlink
# undef rmdir
# undef rename
# undef lseek

# define chown(a,b,c)    (errno = ENOSYS, -1)
# define fchown(a,b,c)   (errno = ENOSYS, -1)
# define fchmod(a,b)     (errno = ENOSYS, -1)
# define symlink(a,b)    (errno = ENOSYS, -1)
# define readlink(a,b,c) (errno = ENOSYS, -1)
# define mknod(a,b,c)    (errno = ENOSYS, -1)
# define truncate(a,b)   (errno = ENOSYS, -1)
# define ftruncate(fd,o) chsize ((fd), (o))
# define fsync(fd)       _commit (fd)
# define opendir(fd)     (errno = ENOSYS, 0)
# define readdir(fd)     (errno = ENOSYS, -1)
# define closedir(fd)    (errno = ENOSYS, -1)
# define mkdir(a,b)      mkdir (a)

#else

# include <sys/time.h>
# include <sys/select.h>
# include <unistd.h>
# include <utime.h>
# include <signal.h>
# define EIO_STRUCT_DIRENT struct dirent

#endif

/* perl stupidly overrides readdir and maybe others */
/* with thread-unsafe versions, imagine that :( */
#undef readdir
#undef opendir
#undef closedir

#define EIO_STRUCT_STAT Stat_t

/* use NV for 32 bit perls as it allows larger offsets */
#if IVSIZE >= 8
# define SvVAL64 SvIV
#else
# define SvVAL64 SvNV
#endif

/*****************************************************************************/

#if __GNUC__ >= 3
# define expect(expr,value) __builtin_expect ((expr),(value))
#else
# define expect(expr,value) (expr)
#endif

#define expect_false(expr) expect ((expr) != 0, 0)
#define expect_true(expr)  expect ((expr) != 0, 1)

/*****************************************************************************/

static HV *stash;
typedef SV SV8; /* byte-sv, used for argument-checking */

#define AIO_REQ_KLASS "IO::AIO::REQ"
#define AIO_GRP_KLASS "IO::AIO::GRP"

#define EIO_REQ_MEMBERS	\
  SV *callback;		\
  SV *sv1, *sv2;	\
  STRLEN stroffset;	\
  SV *self;

#define EIO_NO_WRAPPERS 1

#include "libeio/eio.h"

static int req_invoke    (eio_req *req);
#define EIO_FINISH(req)  req_invoke (req)
static void req_destroy  (eio_req *grp);
#define EIO_DESTROY(req) req_destroy (req)

enum {
  FLAG_SV2_RO_OFF = 0x40, /* data was set readonly */
};

#include "libeio/eio.c"

typedef eio_req *aio_req;
typedef eio_req *aio_req_ornot;

static SV *on_next_submit;
static int next_pri = EIO_PRI_DEFAULT;
static int max_outstanding;

static int respipe_osf [2], respipe [2] = { -1, -1 };

static void req_destroy (aio_req req);
static void req_cancel (aio_req req);

static void want_poll (void)
{
  /* write a dummy byte to the pipe so fh becomes ready */
  respipe_write (respipe_osf [1], (const void *)&respipe_osf, 1);
}

static void done_poll (void)
{
  /* read any signals sent by the worker threads */
  char buf [4];
  while (respipe_read (respipe [0], buf, 4) == 4)
    ;
}

/* must be called at most once */
static SV *req_sv (aio_req req, const char *klass)
{
  if (!req->self)
    {
      req->self = (SV *)newHV ();
      sv_magic (req->self, 0, PERL_MAGIC_ext, (char *)req, 0);
    }

  return sv_2mortal (sv_bless (newRV_inc (req->self), gv_stashpv (klass, 1)));
}

static aio_req SvAIO_REQ (SV *sv)
{
  MAGIC *mg;

  if (!sv_derived_from (sv, AIO_REQ_KLASS) || !SvROK (sv))
    croak ("object of class " AIO_REQ_KLASS " expected");

  mg = mg_find (SvRV (sv), PERL_MAGIC_ext);

  return mg ? (aio_req)mg->mg_ptr : 0;
}

static void aio_grp_feed (aio_req grp)
{
  if (grp->sv2 && SvOK (grp->sv2))
    {
      dSP;

      ENTER;
      SAVETMPS;
      PUSHMARK (SP);
      XPUSHs (req_sv (grp, AIO_GRP_KLASS));
      PUTBACK;
      call_sv (grp->sv2, G_VOID | G_EVAL | G_KEEPERR);
      SPAGAIN;
      FREETMPS;
      LEAVE;
    }
}

static void req_submit (eio_req *req)
{
  eio_submit (req);

  if (expect_false (on_next_submit))
    {
      dSP;
      SV *cb = sv_2mortal (on_next_submit);

      on_next_submit = 0;

      PUSHMARK (SP);
      PUTBACK;
      call_sv (cb, G_DISCARD | G_EVAL);
    }
}

static int req_invoke (eio_req *req)
{
  dSP;

  if (req->flags & FLAG_SV2_RO_OFF)
    SvREADONLY_off (req->sv2);

  if (!EIO_CANCELLED (req) && req->callback)
    {
      ENTER;
      SAVETMPS;
      PUSHMARK (SP);
      EXTEND (SP, 1);

      switch (req->type)
        {
          case EIO_READDIR:
            {
              SV *rv = &PL_sv_undef;

              if (req->result >= 0)
                {
                  int i;
                  char *buf = req->ptr2;
                  AV *av = newAV ();

                  av_extend (av, req->result - 1);

                  for (i = 0; i < req->result; ++i)
                    {
                      if (req->int1 & EIO_READDIR_DENTS)
                        {
                          eio_dirent *ent = (eio_dirent *)buf;
                          SV *namesv = newSVpvn (ent->name, ent->namelen);

                          if (req->int1 & EIO_READDIR_CUSTOM2)
                            {
                              static SV *sv_type [EIO_DT_MAX + 1]; /* type sv cache */
                              AV *avent = newAV ();

                              av_extend (avent, 2);

                              if (!sv_type [ent->type])
                                {
                                  sv_type [ent->type] = newSViv (ent->type);
                                  SvREADONLY_on (sv_type [ent->type]);
                                }

                              av_store (avent, 0, namesv);
                              av_store (avent, 1, SvREFCNT_inc (sv_type [ent->type]));
                              av_store (avent, 2, IVSIZE >= 8 ? newSVuv (ent->inode) : newSVnv (ent->inode));

                              av_store (av, i, newRV_noinc ((SV *)avent));
                            }
                          else
                            av_store (av, i, namesv);

                          buf += sizeof (eio_dirent);
                        }
                      else
                        {
                          SV *name = newSVpv (buf, 0);
                          av_store (av, i, name);
                          buf += SvCUR (name) + 1;
                        }
                    }

                  rv = sv_2mortal (newRV_noinc ((SV *)av));
                }

              PUSHs (rv);

              if (req->int1 & EIO_READDIR_CUSTOM1)
                XPUSHs (sv_2mortal (newSViv (req->int1 & ~(EIO_READDIR_CUSTOM1 | EIO_READDIR_CUSTOM2))));
            }
            break;

          case EIO_OPEN:
            {
              /* convert fd to fh */
              SV *fh = &PL_sv_undef;

              if (req->result >= 0)
                {
                  GV *gv = (GV *)sv_newmortal ();
                  int flags = req->int1 & (O_RDONLY | O_WRONLY | O_RDWR);
                  char sym [64];
                  int symlen;
                  
                  symlen = snprintf (sym, sizeof (sym), "fd#%d", (int)req->result);
                  gv_init (gv, stash, sym, symlen, 0);

                  symlen = snprintf (
                     sym,
                     sizeof (sym),
                     "%s&=%d",
                     flags == O_RDONLY ? "<" : flags == O_WRONLY ? ">" : "+<",
                     (int)req->result
                  );

                  if (do_open (gv, sym, symlen, 0, 0, 0, 0))
                    fh = (SV *)gv;
                }

              PUSHs (fh);
            }
            break;

          case EIO_GROUP:
            req->int1 = 2; /* mark group as finished */

            if (req->sv1)
              {
                int i;
                AV *av = (AV *)req->sv1;

                EXTEND (SP, AvFILL (av) + 1);
                for (i = 0; i <= AvFILL (av); ++i)
                  PUSHs (*av_fetch (av, i, 0));
              }
            break;

          case EIO_NOP:
          case EIO_BUSY:
            break;

          case EIO_READLINK:
            if (req->result > 0)
              PUSHs (sv_2mortal (newSVpvn (req->ptr2, req->result)));
            break;

          case EIO_STAT:
          case EIO_LSTAT:
          case EIO_FSTAT:
            PL_laststype   = req->type == EIO_LSTAT ? OP_LSTAT : OP_STAT;
            PL_laststatval = req->result;
            PL_statcache   = *(EIO_STRUCT_STAT *)(req->ptr2);
            PUSHs (sv_2mortal (newSViv (req->result)));
            break;

          case EIO_READ:
            {
              SvCUR_set (req->sv2, req->stroffset + (req->result > 0 ? req->result : 0));
              *SvEND (req->sv2) = 0;
              SvPOK_only (req->sv2);
              SvSETMAGIC (req->sv2);
              PUSHs (sv_2mortal (newSViv (req->result)));
            }
            break;

          case EIO_DUP2:
            if (req->result > 0)
              req->result = 0;
            /* FALLTHROUGH */

          default:
            PUSHs (sv_2mortal (newSViv (req->result)));
            break;
        }

      errno = req->errorno;

      PUTBACK;
      call_sv (req->callback, G_VOID | G_EVAL | G_DISCARD);
      SPAGAIN;

      FREETMPS;
      LEAVE;

      PUTBACK;
    }

  return !!SvTRUE (ERRSV);
}

static void req_destroy (aio_req req)
{
  if (req->self)
    {
      sv_unmagic (req->self, PERL_MAGIC_ext);
      SvREFCNT_dec (req->self);
    }

  SvREFCNT_dec (req->sv1);
  SvREFCNT_dec (req->sv2);
  SvREFCNT_dec (req->callback);

  Safefree (req);
}

static void req_cancel_subs (aio_req grp)
{
  aio_req sub;

  if (grp->type != EIO_GROUP)
    return;

  SvREFCNT_dec (grp->sv2);
  grp->sv2 = 0;

  eio_grp_cancel (grp);
}

#ifdef USE_SOCKETS_AS_HANDLES
# define TO_SOCKET(x) (win32_get_osfhandle (x))
#else
# define TO_SOCKET(x) (x)
#endif

static void
create_respipe (void)
{
  int old_readfd = respipe [0];

  if (respipe [1] >= 0)
    respipe_close (TO_SOCKET (respipe [1]));

#ifdef _WIN32
  if (PerlSock_socketpair (AF_UNIX, SOCK_STREAM, 0, respipe))
#else
  if (pipe (respipe))
#endif
    croak ("unable to initialize result pipe");

  if (old_readfd >= 0)
    {
      if (dup2 (TO_SOCKET (respipe [0]), TO_SOCKET (old_readfd)) < 0)
        croak ("unable to initialize result pipe(2)");

      respipe_close (respipe [0]);
      respipe [0] = old_readfd;
    }

#ifdef _WIN32
  int arg = 1;
  if (ioctlsocket (TO_SOCKET (respipe [0]), FIONBIO, &arg)
      || ioctlsocket (TO_SOCKET (respipe [1]), FIONBIO, &arg))
#else
  if (fcntl (respipe [0], F_SETFL, O_NONBLOCK)
      || fcntl (respipe [1], F_SETFL, O_NONBLOCK))
#endif
    croak ("unable to initialize result pipe(3)");

  respipe_osf [0] = TO_SOCKET (respipe [0]);
  respipe_osf [1] = TO_SOCKET (respipe [1]);
}

static void poll_wait (void)
{
  fd_set rfd;

  while (eio_nreqs ())
    {
      int size;

      X_LOCK   (reslock);
      size = res_queue.size;
      X_UNLOCK (reslock);

      if (size)
        return;

      etp_maybe_start_thread ();

      FD_ZERO (&rfd);
      FD_SET (respipe [0], &rfd);

      PerlSock_select (respipe [0] + 1, &rfd, 0, 0, 0);
    }
}

static int poll_cb (void)
{
  for (;;)
    {
      int res = eio_poll ();

      if (res > 0)
        croak (0);

      if (!max_outstanding || max_outstanding > eio_nreqs ())
        return res;

      poll_wait ();
    }
}

static void atfork_child (void)
{
  create_respipe ();
}

static SV *
get_cb (SV *cb_sv)
{
  HV *st;
  GV *gvp;
  CV *cv;

  if (!SvOK (cb_sv))
    return 0;

  cv = sv_2cv (cb_sv, &st, &gvp, 0);

  if (!cv)
    croak ("IO::AIO callback must be undef or a CODE reference");

  return (SV *)cv;
}

#define dREQ							\
  SV *cb_cv;							\
  aio_req req;							\
  int req_pri = next_pri;					\
  next_pri = EIO_PRI_DEFAULT;					\
								\
  cb_cv = get_cb (callback);					\
								\
  Newz (0, req, 1, eio_req);					\
  if (!req)							\
    croak ("out of memory during eio_req allocation");		\
								\
  req->callback = SvREFCNT_inc (cb_cv);				\
  req->pri = req_pri

#define REQ_SEND						\
  PUTBACK;							\
  req_submit (req);						\
  SPAGAIN;							\
								\
  if (GIMME_V != G_VOID)					\
    XPUSHs (req_sv (req, AIO_REQ_KLASS));

static int
extract_fd (SV *fh, int wr)
{
  int fd = PerlIO_fileno (wr ? IoOFP (sv_2io (fh)) : IoIFP (sv_2io (fh)));

  if (fd < 0)
    croak ("illegal fh argument, either not an OS file or read/write mode mismatch");

  return fd;
}

MODULE = IO::AIO                PACKAGE = IO::AIO

PROTOTYPES: ENABLE

BOOT:
{
  static const struct {
    const char *name;
    IV iv;
  } *civ, const_iv[] = {
#   define const_iv(name, value) { # name, (IV) value },
#   define const_eio(name) { # name, (IV) EIO_ ## name },
    const_iv (EXDEV   , EXDEV)
    const_iv (ENOSYS  , ENOSYS)
    const_iv (O_RDONLY, O_RDONLY)
    const_iv (O_WRONLY, O_WRONLY)
    const_iv (O_CREAT , O_CREAT)
    const_iv (O_TRUNC , O_TRUNC)
#ifndef _WIN32
    const_iv (S_IFIFO , S_IFIFO)
#endif
    const_eio (SYNC_FILE_RANGE_WAIT_BEFORE)
    const_eio (SYNC_FILE_RANGE_WRITE)
    const_eio (SYNC_FILE_RANGE_WAIT_AFTER)

    const_eio (READDIR_DENTS)
    const_eio (READDIR_DIRS_FIRST)
    const_eio (READDIR_STAT_ORDER)
    const_eio (READDIR_FOUND_UNKNOWN)

    const_eio (DT_UNKNOWN)
    const_eio (DT_FIFO)
    const_eio (DT_CHR)
    const_eio (DT_DIR)
    const_eio (DT_BLK)
    const_eio (DT_REG)
    const_eio (DT_LNK)
    const_eio (DT_SOCK)
    const_eio (DT_WHT)
  };

  stash = gv_stashpv ("IO::AIO", 1);

  for (civ = const_iv + sizeof (const_iv) / sizeof (const_iv [0]); civ-- > const_iv; )
    newCONSTSUB (stash, (char *)civ->name, newSViv (civ->iv));

  create_respipe ();

  if (eio_init (want_poll, done_poll) < 0)
    croak ("IO::AIO: unable to initialise eio library");

  /* atfork child called in fifo order, so before eio's handler */
  X_THREAD_ATFORK (0, 0, atfork_child);
}

void
max_poll_reqs (int nreqs)
	PROTOTYPE: $
        CODE:
        eio_set_max_poll_reqs (nreqs);

void
max_poll_time (double nseconds)
	PROTOTYPE: $
        CODE:
        eio_set_max_poll_time (nseconds);

void
min_parallel (int nthreads)
	PROTOTYPE: $
        CODE:
        eio_set_min_parallel (nthreads);

void
max_parallel (int nthreads)
	PROTOTYPE: $
        CODE:
        eio_set_max_parallel (nthreads);

void
max_idle (int nthreads)
	PROTOTYPE: $
        CODE:
        eio_set_max_idle (nthreads);

void
max_outstanding (int maxreqs)
	PROTOTYPE: $
        CODE:
        max_outstanding = maxreqs;

void
aio_open (SV8 *pathname, int flags, int mode, SV *callback=&PL_sv_undef)
	PROTOTYPE: $$$;$
	PPCODE:
{
        dREQ;

        req->type = EIO_OPEN;
        req->sv1  = newSVsv (pathname);
        req->ptr1 = SvPVbyte_nolen (req->sv1);
        req->int1 = flags;
        req->int2 = mode;

        REQ_SEND;
}

void
aio_fsync (SV *fh, SV *callback=&PL_sv_undef)
	PROTOTYPE: $;$
        ALIAS:
           aio_fsync     = EIO_FSYNC
           aio_fdatasync = EIO_FDATASYNC
	PPCODE:
{
  	int fd = extract_fd (fh, 0);
        dREQ;

        req->type = ix;
        req->sv1  = newSVsv (fh);
        req->int1 = fd;

        REQ_SEND (req);
}

void
aio_sync_file_range (SV *fh, SV *offset, SV *nbytes, IV flags, SV *callback=&PL_sv_undef)
	PROTOTYPE: $$$$;$
	PPCODE:
{
  	int fd = extract_fd (fh, 0);
        dREQ;

        req->type = EIO_SYNC_FILE_RANGE;
        req->sv1  = newSVsv (fh);
        req->int1 = fd;
        req->offs = SvVAL64 (offset);
        req->size = SvVAL64 (nbytes);
        req->int2 = flags;

        REQ_SEND (req);
}

void
aio_close (SV *fh, SV *callback=&PL_sv_undef)
	PROTOTYPE: $;$
	PPCODE:
{
        static int close_pipe = -1; /* dummy fd to close fds via dup2 */
  	int fd = extract_fd (fh, 0);
        dREQ;

        if (close_pipe < 0)
          {
            int pipefd [2];

            if (pipe (pipefd) < 0
                || close (pipefd [1]) < 0
                || fcntl (pipefd [0], F_SETFD, FD_CLOEXEC) < 0)
              abort (); /*D*/

            close_pipe = pipefd [0];
          }

        req->type = EIO_DUP2;
        req->int1 = close_pipe;
        req->sv2  = newSVsv (fh);
        req->int2 = fd;

        REQ_SEND (req);
}

void
aio_read (SV *fh, SV *offset, SV *length, SV8 *data, IV dataoffset, SV *callback=&PL_sv_undef)
        ALIAS:
           aio_read  = EIO_READ
           aio_write = EIO_WRITE
	PROTOTYPE: $$$$$;$
        PPCODE:
{
        STRLEN svlen;
        int fd = extract_fd (fh, ix == EIO_WRITE);
        char *svptr = SvPVbyte (data, svlen);
        UV len = SvUV (length);

        if (dataoffset < 0)
          dataoffset += svlen;

        if (dataoffset < 0 || dataoffset > svlen)
          croak ("dataoffset outside of data scalar");

        if (ix == EIO_WRITE)
          {
            /* write: check length and adjust. */
            if (!SvOK (length) || len + dataoffset > svlen)
              len = svlen - dataoffset;
          }
        else
          {
            /* read: check type and grow scalar as necessary */
            SvUPGRADE (data, SVt_PV);
            svptr = SvGROW (data, len + dataoffset + 1);
          }

        {
          dREQ;

          req->type = ix;
          req->sv1  = newSVsv (fh);
          req->int1 = fd;
          req->offs = SvOK (offset) ? SvVAL64 (offset) : -1;
          req->size = len;
          req->sv2  = SvREFCNT_inc (data);
          req->ptr2 = (char *)svptr + dataoffset;
          req->stroffset = dataoffset;

          if (!SvREADONLY (data))
            {
              SvREADONLY_on (data);
              req->flags |= FLAG_SV2_RO_OFF;
            }

          REQ_SEND;
        }
}

void
aio_readlink (SV8 *path, SV *callback=&PL_sv_undef)
	PROTOTYPE: $$;$
        PPCODE:
{
	SV *data;
        dREQ;

        req->type = EIO_READLINK;
        req->sv1  = newSVsv (path);
        req->ptr1 = SvPVbyte_nolen (req->sv1);

        REQ_SEND;
}

void
aio_sendfile (SV *out_fh, SV *in_fh, SV *in_offset, UV length, SV *callback=&PL_sv_undef)
	PROTOTYPE: $$$$;$
        PPCODE:
{
  	int ifd = extract_fd (in_fh , 0);
  	int ofd = extract_fd (out_fh, 0);
	dREQ;

        req->type = EIO_SENDFILE;
        req->sv1  = newSVsv (out_fh);
        req->int1 = ofd;
        req->sv2  = newSVsv (in_fh);
        req->int2 = ifd;
        req->offs = SvVAL64 (in_offset);
        req->size = length;

        REQ_SEND;
}

void
aio_readahead (SV *fh, SV *offset, IV length, SV *callback=&PL_sv_undef)
	PROTOTYPE: $$$;$
        PPCODE:
{
  	int fd = extract_fd (fh, 0);
	dREQ;

        req->type = EIO_READAHEAD;
        req->sv1  = newSVsv (fh);
        req->int1 = fd;
        req->offs = SvVAL64 (offset);
        req->size = length;

        REQ_SEND;
}

void
aio_stat (SV8 *fh_or_path, SV *callback=&PL_sv_undef)
        ALIAS:
           aio_stat  = EIO_STAT
           aio_lstat = EIO_LSTAT
	PPCODE:
{
	dREQ;

        req->sv1 = newSVsv (fh_or_path);

        if (SvPOK (req->sv1))
          {
            req->type = ix;
            req->ptr1 = SvPVbyte_nolen (req->sv1);
          }
        else
          {
            req->type = EIO_FSTAT;
            req->int1 = PerlIO_fileno (IoIFP (sv_2io (fh_or_path)));
          }

        REQ_SEND;
}

void
aio_utime (SV8 *fh_or_path, SV *atime, SV *mtime, SV *callback=&PL_sv_undef)
	PPCODE:
{
	dREQ;

        req->nv1 = SvOK (atime) ? SvNV (atime) : -1.;
        req->nv2 = SvOK (mtime) ? SvNV (mtime) : -1.;
        req->sv1 = newSVsv (fh_or_path);

        if (SvPOK (req->sv1))
          {
            req->type = EIO_UTIME;
            req->ptr1 = SvPVbyte_nolen (req->sv1);
          }
        else
          {
            req->type = EIO_FUTIME;
            req->int1 = PerlIO_fileno (IoIFP (sv_2io (fh_or_path)));
          }

        REQ_SEND;
}

void
aio_truncate (SV8 *fh_or_path, SV *offset, SV *callback=&PL_sv_undef)
	PPCODE:
{
	dREQ;

        req->sv1  = newSVsv (fh_or_path);
        req->offs = SvOK (offset) ? SvVAL64 (offset) : -1;

        if (SvPOK (req->sv1))
          {
            req->type = EIO_TRUNCATE;
            req->ptr1 = SvPVbyte_nolen (req->sv1);
          }
        else
          {
            req->type = EIO_FTRUNCATE;
            req->int1 = PerlIO_fileno (IoIFP (sv_2io (fh_or_path)));
          }

        REQ_SEND;
}

void
aio_chmod (SV8 *fh_or_path, int mode, SV *callback=&PL_sv_undef)
	ALIAS:
        aio_chmod  = EIO_CHMOD
        aio_mkdir  = EIO_MKDIR
	PPCODE:
{
	dREQ;

        req->int2 = mode;
        req->sv1  = newSVsv (fh_or_path);

        if (SvPOK (req->sv1))
          {
            req->type = ix;
            req->ptr1 = SvPVbyte_nolen (req->sv1);
          }
        else
          {
            req->type = EIO_FCHMOD;
            req->int1 = PerlIO_fileno (IoIFP (sv_2io (fh_or_path)));
          }

        REQ_SEND;
}

void
aio_chown (SV8 *fh_or_path, SV *uid, SV *gid, SV *callback=&PL_sv_undef)
	PPCODE:
{
	dREQ;

        req->int2 = SvOK (uid) ? SvIV (uid) : -1;
        req->int3 = SvOK (gid) ? SvIV (gid) : -1;
        req->sv1  = newSVsv (fh_or_path);

        if (SvPOK (req->sv1))
          {
            req->type = EIO_CHOWN;
            req->ptr1 = SvPVbyte_nolen (req->sv1);
          }
        else
          {
            req->type = EIO_FCHOWN;
            req->int1 = PerlIO_fileno (IoIFP (sv_2io (fh_or_path)));
          }

        REQ_SEND;
}

void
aio_readdirx (SV8 *pathname, IV flags, SV *callback=&PL_sv_undef)
	PPCODE:
{
	dREQ;
	
        req->type = EIO_READDIR;
	req->sv1  = newSVsv (pathname);
	req->ptr1 = SvPVbyte_nolen (req->sv1);
        req->int1 = flags | EIO_READDIR_DENTS | EIO_READDIR_CUSTOM1;

        if (flags & EIO_READDIR_DENTS)
          req->int1 |= EIO_READDIR_CUSTOM2;

	REQ_SEND;
}

void
aio_unlink (SV8 *pathname, SV *callback=&PL_sv_undef)
        ALIAS:
           aio_unlink  = EIO_UNLINK
           aio_rmdir   = EIO_RMDIR
           aio_readdir = EIO_READDIR
	PPCODE:
{
	dREQ;
	
        req->type = ix;
	req->sv1  = newSVsv (pathname);
	req->ptr1 = SvPVbyte_nolen (req->sv1);

	REQ_SEND;
}

void
aio_link (SV8 *oldpath, SV8 *newpath, SV *callback=&PL_sv_undef)
        ALIAS:
           aio_link    = EIO_LINK
           aio_symlink = EIO_SYMLINK
           aio_rename  = EIO_RENAME
	PPCODE:
{
	dREQ;
	
        req->type = ix;
	req->sv1  = newSVsv (oldpath);
	req->ptr1 = SvPVbyte_nolen (req->sv1);
	req->sv2  = newSVsv (newpath);
	req->ptr2 = SvPVbyte_nolen (req->sv2);
	
	REQ_SEND;
}

void
aio_mknod (SV8 *pathname, int mode, UV dev, SV *callback=&PL_sv_undef)
	PPCODE:
{
	dREQ;
	
        req->type = EIO_MKNOD;
	req->sv1  = newSVsv (pathname);
	req->ptr1 = SvPVbyte_nolen (req->sv1);
        req->int2 = (mode_t)mode;
        req->offs = dev;
	
	REQ_SEND;
}

void
aio_busy (double delay, SV *callback=&PL_sv_undef)
	PPCODE:
{
	dREQ;

        req->type = EIO_BUSY;
        req->nv1  = delay < 0. ? 0. : delay;

	REQ_SEND;
}

void
aio_group (SV *callback=&PL_sv_undef)
	PROTOTYPE: ;$
        PPCODE:
{
	dREQ;

        req->type = EIO_GROUP;

        req_submit (req);
        XPUSHs (req_sv (req, AIO_GRP_KLASS));
}

void
aio_nop (SV *callback=&PL_sv_undef)
	ALIAS:
           aio_nop  = EIO_NOP
           aio_sync = EIO_SYNC
	PPCODE:
{
	dREQ;

        req->type = ix;

	REQ_SEND;
}

int
aioreq_pri (int pri = 0)
	PROTOTYPE: ;$
	CODE:
	RETVAL = next_pri;
	if (items > 0)
	  {
	    if (pri < EIO_PRI_MIN) pri = EIO_PRI_MIN;
	    if (pri > EIO_PRI_MAX) pri = EIO_PRI_MAX;
	    next_pri = pri;
	  }
	OUTPUT:
	RETVAL

void
aioreq_nice (int nice = 0)
	CODE:
	nice = next_pri - nice;
	if (nice < EIO_PRI_MIN) nice = EIO_PRI_MIN;
	if (nice > EIO_PRI_MAX) nice = EIO_PRI_MAX;
	next_pri = nice;

void
flush ()
	PROTOTYPE:
	CODE:
        while (eio_nreqs ())
          {
            poll_wait ();
            poll_cb ();
          }

int
poll()
	PROTOTYPE:
	CODE:
        poll_wait ();
        RETVAL = poll_cb ();
	OUTPUT:
	RETVAL

int
poll_fileno()
	PROTOTYPE:
	CODE:
        RETVAL = respipe [0];
	OUTPUT:
	RETVAL

int
poll_cb(...)
	PROTOTYPE:
	CODE:
        RETVAL = poll_cb ();
	OUTPUT:
	RETVAL

void
poll_wait()
	PROTOTYPE:
	CODE:
        poll_wait ();

int
nreqs()
	PROTOTYPE:
	CODE:
        RETVAL = eio_nreqs ();
	OUTPUT:
	RETVAL

int
nready()
	PROTOTYPE:
	CODE:
        RETVAL = eio_nready ();
	OUTPUT:
	RETVAL

int
npending()
	PROTOTYPE:
	CODE:
        RETVAL = eio_npending ();
	OUTPUT:
	RETVAL

int
nthreads()
	PROTOTYPE:
	CODE:
        RETVAL = eio_nthreads ();
	OUTPUT:
	RETVAL

void _on_next_submit (SV *cb)
	CODE:
        SvREFCNT_dec (on_next_submit);
        on_next_submit = SvOK (cb) ? newSVsv (cb) : 0;

PROTOTYPES: DISABLE

MODULE = IO::AIO                PACKAGE = IO::AIO::REQ

void
cancel (aio_req_ornot req)
	CODE:
        eio_cancel (req);

void
cb (aio_req_ornot req, SV *callback=&PL_sv_undef)
	PPCODE:
{
        if (GIMME_V != G_VOID)
          XPUSHs (req->callback ? sv_2mortal (newRV_inc (req->callback)) : &PL_sv_undef);

        if (items > 1)
          {
            SV *cb_cv = get_cb (callback);

            SvREFCNT_dec (req->callback);
            req->callback = SvREFCNT_inc (cb_cv);
          }
}

MODULE = IO::AIO                PACKAGE = IO::AIO::GRP

void
add (aio_req grp, ...)
        PPCODE:
{
	int i;

        if (grp->int1 == 2)
          croak ("cannot add requests to IO::AIO::GRP after the group finished");

	for (i = 1; i < items; ++i )
          {
            aio_req req;

            if (GIMME_V != G_VOID)
              XPUSHs (sv_2mortal (newSVsv (ST (i))));

            req = SvAIO_REQ (ST (i));

            if (req)
              eio_grp_add (grp, req);
          }
}

void
cancel_subs (aio_req_ornot req)
	CODE:
        req_cancel_subs (req);

void
result (aio_req grp, ...)
        CODE:
{
        int i;
        AV *av;

        grp->errorno = errno;

        av = newAV ();
        av_extend (av, items - 1);

        for (i = 1; i < items; ++i )
          av_push (av, newSVsv (ST (i)));

        SvREFCNT_dec (grp->sv1);
        grp->sv1 = (SV *)av;
}

void
errno (aio_req grp, int errorno = errno)
        CODE:
        grp->errorno = errorno;

void
limit (aio_req grp, int limit)
	CODE:
        eio_grp_limit (grp, limit);

void
feed (aio_req grp, SV *callback=&PL_sv_undef)
	CODE:
{
        SvREFCNT_dec (grp->sv2);
        grp->sv2  = newSVsv (callback);
        grp->feed = aio_grp_feed;

        if (grp->int2 <= 0)
          grp->int2 = 2;

        eio_grp_limit (grp, grp->int2);
}

