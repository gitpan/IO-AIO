#include "xthread.h"

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

#ifdef _WIN32

# define SIGIO 0
  typedef Direntry_t X_DIRENT;
#undef malloc
#undef free

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

# include "autoconf/config.h"
# include <sys/time.h>
# include <sys/select.h>
# include <unistd.h>
# include <utime.h>
# include <signal.h>
  typedef struct dirent X_DIRENT;

#endif

#if HAVE_SENDFILE
# if __linux
#  include <sys/sendfile.h>
# elif __freebsd
#  include <sys/socket.h>
#  include <sys/uio.h>
# elif __hpux
#  include <sys/socket.h>
# elif __solaris /* not yet */
#  include <sys/sendfile.h>
# else
#  error sendfile support requested but not available
# endif
#endif

/* number of seconds after which idle threads exit */
#define IDLE_TIMEOUT 10

/* used for struct dirent, AIX doesn't provide it */
#ifndef NAME_MAX
# define NAME_MAX 4096
#endif

/* buffer size for various temporary buffers */
#define AIO_BUFSIZE 65536

/* use NV for 32 bit perls as it allows larger offsets */
#if IVSIZE >= 8
# define SvVAL64 SvIV
#else
# define SvVAL64 SvNV
#endif

static HV *stash;

#define dBUF	 				\
  char *aio_buf;				\
  X_LOCK (wrklock);				\
  self->dbuf = aio_buf = malloc (AIO_BUFSIZE);	\
  X_UNLOCK (wrklock);				\
  if (!aio_buf)					\
    return -1;

typedef SV SV8; /* byte-sv, used for argument-checking */

enum {
  REQ_QUIT,
  REQ_OPEN, REQ_CLOSE,
  REQ_READ, REQ_WRITE,
  REQ_READAHEAD, REQ_SENDFILE,
  REQ_STAT, REQ_LSTAT, REQ_FSTAT,
  REQ_TRUNCATE, REQ_FTRUNCATE,
  REQ_UTIME, REQ_FUTIME,
  REQ_CHMOD, REQ_FCHMOD,
  REQ_CHOWN, REQ_FCHOWN,
  REQ_SYNC, REQ_FSYNC, REQ_FDATASYNC,
  REQ_UNLINK, REQ_RMDIR, REQ_MKDIR, REQ_RENAME,
  REQ_MKNOD, REQ_READDIR,
  REQ_LINK, REQ_SYMLINK, REQ_READLINK,
  REQ_GROUP, REQ_NOP,
  REQ_BUSY,
};

#define AIO_REQ_KLASS "IO::AIO::REQ"
#define AIO_GRP_KLASS "IO::AIO::GRP"

typedef struct aio_cb
{
  struct aio_cb *volatile next;

  SV *callback;
  SV *sv1, *sv2;
  void *ptr1, *ptr2;
  off_t offs;
  size_t size;
  ssize_t result;
  double nv1, nv2;

  STRLEN stroffset;
  int type;
  int int1, int2, int3;
  int errorno;
  mode_t mode; /* open */

  unsigned char flags;
  unsigned char pri;

  SV *self; /* the perl counterpart of this request, if any */
  struct aio_cb *grp, *grp_prev, *grp_next, *grp_first;
} aio_cb;

enum {
  FLAG_CANCELLED     = 0x01, /* request was cancelled */
  FLAG_SV2_RO_OFF    = 0x40, /* data was set readonly */
  FLAG_PTR2_FREE     = 0x80, /* need to free(ptr2) */
};

typedef aio_cb *aio_req;
typedef aio_cb *aio_req_ornot;

enum {
  PRI_MIN     = -4,
  PRI_MAX     =  4,

  DEFAULT_PRI = 0,
  PRI_BIAS    = -PRI_MIN,
  NUM_PRI     = PRI_MAX + PRI_BIAS + 1,
};

#define AIO_TICKS ((1000000 + 1023) >> 10)

static unsigned int max_poll_time = 0;
static unsigned int max_poll_reqs = 0;

/* calculcate time difference in ~1/AIO_TICKS of a second */
static int tvdiff (struct timeval *tv1, struct timeval *tv2)
{
  return  (tv2->tv_sec  - tv1->tv_sec ) * AIO_TICKS
       + ((tv2->tv_usec - tv1->tv_usec) >> 10);
}

static thread_t main_tid;
static int main_sig;
static int block_sig_level;

void block_sig (void)
{
  sigset_t ss;

  if (block_sig_level++)
    return;

  if (!main_sig)
    return;

  sigemptyset (&ss);
  sigaddset (&ss, main_sig);
  pthread_sigmask (SIG_BLOCK, &ss, 0);
}

void unblock_sig (void)
{
  sigset_t ss;

  if (--block_sig_level)
    return;

  if (!main_sig)
    return;

  sigemptyset (&ss);
  sigaddset (&ss, main_sig);
  pthread_sigmask (SIG_UNBLOCK, &ss, 0);
}

static int next_pri = DEFAULT_PRI + PRI_BIAS;

static unsigned int started, idle, wanted;

/* worker threads management */
static mutex_t wrklock = X_MUTEX_INIT;

typedef struct worker {
  /* locked by wrklock */
  struct worker *prev, *next;

  thread_t tid;

  /* locked by reslock, reqlock or wrklock */
  aio_req req; /* currently processed request */
  void *dbuf;
  DIR *dirp;
} worker;

static worker wrk_first = { &wrk_first, &wrk_first, 0 };

static void worker_clear (worker *wrk)
{
  if (wrk->dirp)
    {
      closedir (wrk->dirp);
      wrk->dirp = 0;
    }

  if (wrk->dbuf)
    {
      free (wrk->dbuf);
      wrk->dbuf = 0;
    }
}

static void worker_free (worker *wrk)
{
  wrk->next->prev = wrk->prev;
  wrk->prev->next = wrk->next;

  free (wrk);
}

static volatile unsigned int nreqs, nready, npending;
static volatile unsigned int max_idle = 4;
static volatile unsigned int max_outstanding = 0xffffffff;
static int respipe_osf [2], respipe [2] = { -1, -1 };

static mutex_t reslock = X_MUTEX_INIT;
static mutex_t reqlock = X_MUTEX_INIT;
static cond_t  reqwait = X_COND_INIT;

#if WORDACCESS_UNSAFE

static unsigned int get_nready (void)
{
  unsigned int retval;

  X_LOCK   (reqlock);
  retval = nready;
  X_UNLOCK (reqlock);

  return retval;
}

static unsigned int get_npending (void)
{
  unsigned int retval;

  X_LOCK   (reslock);
  retval = npending;
  X_UNLOCK (reslock);

  return retval;
}

static unsigned int get_nthreads (void)
{
  unsigned int retval;

  X_LOCK   (wrklock);
  retval = started;
  X_UNLOCK (wrklock);

  return retval;
}

#else

# define get_nready()   nready
# define get_npending() npending
# define get_nthreads() started

#endif

/*
 * a somewhat faster data structure might be nice, but
 * with 8 priorities this actually needs <20 insns
 * per shift, the most expensive operation.
 */
typedef struct {
  aio_req qs[NUM_PRI], qe[NUM_PRI]; /* qstart, qend */
  int size;
} reqq;

static reqq req_queue;
static reqq res_queue;

int reqq_push (reqq *q, aio_req req)
{
  int pri = req->pri;
  req->next = 0;

  if (q->qe[pri])
    {
      q->qe[pri]->next = req;
      q->qe[pri] = req;
    }
  else
    q->qe[pri] = q->qs[pri] = req;

  return q->size++;
}

aio_req reqq_shift (reqq *q)
{
  int pri;

  if (!q->size)
    return 0;

  --q->size;

  for (pri = NUM_PRI; pri--; )
    {
      aio_req req = q->qs[pri];

      if (req)
        {
          if (!(q->qs[pri] = req->next))
            q->qe[pri] = 0;

          return req;
        }
    }

  abort ();
}

static int poll_cb (void);
static int req_invoke (aio_req req);
static void req_destroy (aio_req req);
static void req_cancel (aio_req req);

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
  block_sig ();

  while (grp->size < grp->int2 && !(grp->flags & FLAG_CANCELLED))
    {
      int old_len = grp->size;

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

      /* stop if no progress has been made */
      if (old_len == grp->size)
        {
          SvREFCNT_dec (grp->sv2);
          grp->sv2 = 0;
          break;
        }
    }

  unblock_sig ();
}

static void aio_grp_dec (aio_req grp)
{
  --grp->size;

  /* call feeder, if applicable */
  aio_grp_feed (grp);

  /* finish, if done */
  if (!grp->size && grp->int1)
    {
      block_sig ();

      if (!req_invoke (grp))
        {
          req_destroy (grp);
          unblock_sig ();
          croak (0);
        }

      req_destroy (grp);
      unblock_sig ();
    }
}

static int req_invoke (aio_req req)
{
  dSP;

  if (req->flags & FLAG_SV2_RO_OFF)
    SvREADONLY_off (req->sv2);

  if (!(req->flags & FLAG_CANCELLED) && SvOK (req->callback))
    {
      ENTER;
      SAVETMPS;
      PUSHMARK (SP);
      EXTEND (SP, 1);

      switch (req->type)
        {
          case REQ_READDIR:
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
                      SV *sv = newSVpv (buf, 0);

                      av_store (av, i, sv);
                      buf += SvCUR (sv) + 1;
                    }

                  rv = sv_2mortal (newRV_noinc ((SV *)av));
                }

              PUSHs (rv);
            }
            break;

          case REQ_OPEN:
            {
              /* convert fd to fh */
              SV *fh = &PL_sv_undef;

              if (req->result >= 0)
                {
                  GV *gv = (GV *)sv_newmortal ();
                  int flags = req->int1 & (O_RDONLY | O_WRONLY | O_RDWR);
                  char sym [64];
                  int symlen;
                  
                  symlen = snprintf (sym, sizeof (sym), "fd#%d", req->result);
                  gv_init (gv, stash, sym, symlen, 0);

                  symlen = snprintf (
                     sym,
                     sizeof (sym),
                     "%s&=%d",
                     flags == O_RDONLY ? "<" : flags == O_WRONLY ? ">" : "+<",
                     req->result
                  );

                  if (do_open (gv, sym, symlen, 0, 0, 0, 0))
                    fh = (SV *)gv;
                }

              PUSHs (fh);
            }
            break;

          case REQ_GROUP:
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

          case REQ_NOP:
          case REQ_BUSY:
            break;

          case REQ_READLINK:
            if (req->result > 0)
              {
                SvCUR_set (req->sv2, req->result);
                *SvEND (req->sv2) = 0;
                PUSHs (req->sv2);
              }
            break;

          case REQ_STAT:
          case REQ_LSTAT:
          case REQ_FSTAT:
            PL_laststype   = req->type == REQ_LSTAT ? OP_LSTAT : OP_STAT;
            PL_laststatval = req->result;
            PL_statcache   = *(Stat_t *)(req->ptr2);
            PUSHs (sv_2mortal (newSViv (req->result)));
            break;

          case REQ_READ:
            SvCUR_set (req->sv2, req->stroffset + (req->result > 0 ? req->result : 0));
            *SvEND (req->sv2) = 0;
            PUSHs (sv_2mortal (newSViv (req->result)));
            break;

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

  if (req->grp)
    {
      aio_req grp = req->grp;

      /* unlink request */
      if (req->grp_next) req->grp_next->grp_prev = req->grp_prev;
      if (req->grp_prev) req->grp_prev->grp_next = req->grp_next;

      if (grp->grp_first == req)
        grp->grp_first = req->grp_next;

      aio_grp_dec (grp);
    }

  return !SvTRUE (ERRSV);
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

  if (req->flags & FLAG_PTR2_FREE)
    free (req->ptr2);

  Safefree (req);
}

static void req_cancel_subs (aio_req grp)
{
  aio_req sub;

  if (grp->type != REQ_GROUP)
    return;

  SvREFCNT_dec (grp->sv2);
  grp->sv2 = 0;

  for (sub = grp->grp_first; sub; sub = sub->grp_next)
    req_cancel (sub);
}

static void req_cancel (aio_req req)
{
  req->flags |= FLAG_CANCELLED;

  req_cancel_subs (req);
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

X_THREAD_PROC (aio_proc);

static void start_thread (void)
{
  worker *wrk = calloc (1, sizeof (worker));

  if (!wrk)
    croak ("unable to allocate worker thread data");

  X_LOCK (wrklock);

  if (thread_create (&wrk->tid, aio_proc, (void *)wrk))
    {
      wrk->prev = &wrk_first;
      wrk->next = wrk_first.next;
      wrk_first.next->prev = wrk;
      wrk_first.next = wrk;
      ++started;
    }
  else
    free (wrk);

  X_UNLOCK (wrklock);
}

static void maybe_start_thread (void)
{
  if (get_nthreads () >= wanted)
    return;
  
  /* todo: maybe use idle here, but might be less exact */
  if (0 <= (int)get_nthreads () + (int)get_npending () - (int)nreqs)
    return;

  start_thread ();
}

static void req_send (aio_req req)
{
  block_sig ();

  ++nreqs;

  X_LOCK (reqlock);
  ++nready;
  reqq_push (&req_queue, req);
  X_COND_SIGNAL (reqwait);
  X_UNLOCK (reqlock);

  unblock_sig ();

  maybe_start_thread ();
}

static void end_thread (void)
{
  aio_req req;

  Newz (0, req, 1, aio_cb);

  req->type = REQ_QUIT;
  req->pri  = PRI_MAX + PRI_BIAS;

  X_LOCK (reqlock);
  reqq_push (&req_queue, req);
  X_COND_SIGNAL (reqwait);
  X_UNLOCK (reqlock);

  X_LOCK (wrklock);
  --started;
  X_UNLOCK (wrklock);
}

static void set_max_idle (int nthreads)
{
  if (WORDACCESS_UNSAFE) X_LOCK   (reqlock);
  max_idle = nthreads <= 0 ? 1 : nthreads;
  if (WORDACCESS_UNSAFE) X_UNLOCK (reqlock);
}

static void min_parallel (int nthreads)
{
  if (wanted < nthreads)
    wanted = nthreads;
}

static void max_parallel (int nthreads)
{
  if (wanted > nthreads)
    wanted = nthreads;

  while (started > wanted)
    end_thread ();
}

static void poll_wait (void)
{
  fd_set rfd;

  while (nreqs)
    {
      int size;
      if (WORDACCESS_UNSAFE) X_LOCK   (reslock);
      size = res_queue.size;
      if (WORDACCESS_UNSAFE) X_UNLOCK (reslock);

      if (size)
        return;

      maybe_start_thread ();

      FD_ZERO (&rfd);
      FD_SET (respipe [0], &rfd);

      PerlSock_select (respipe [0] + 1, &rfd, 0, 0, 0);
    }
}

static int poll_cb (void)
{
  dSP;
  int count = 0;
  int maxreqs = max_poll_reqs;
  int do_croak = 0;
  struct timeval tv_start, tv_now;
  aio_req req;

  if (max_poll_time)
    gettimeofday (&tv_start, 0);

  block_sig ();

  for (;;)
    {
      for (;;)
        {
          maybe_start_thread ();

          X_LOCK (reslock);
          req = reqq_shift (&res_queue);

          if (req)
            {
              --npending;

              if (!res_queue.size)
                {
                  /* read any signals sent by the worker threads */
                  char buf [4];
                  while (respipe_read (respipe [0], buf, 4) == 4)
                    ;
                }
            }

          X_UNLOCK (reslock);

          if (!req)
            break;

          --nreqs;

          if (req->type == REQ_GROUP && req->size)
            {
              req->int1 = 1; /* mark request as delayed */
              continue;
            }
          else
            {
              if (!req_invoke (req))
                {
                  req_destroy (req);
                  unblock_sig ();
                  croak (0);
                }

              count++;
            }

          req_destroy (req);

          if (maxreqs && !--maxreqs)
            break;

          if (max_poll_time)
            {
              gettimeofday (&tv_now, 0);

              if (tvdiff (&tv_start, &tv_now) >= max_poll_time)
                break;
            }
        }

      if (nreqs <= max_outstanding)
        break;

      poll_wait ();

      ++maxreqs;
    }

  unblock_sig ();
  return count;
}

/*****************************************************************************/
/* work around various missing functions */

#if !HAVE_PREADWRITE
# define pread  aio_pread
# define pwrite aio_pwrite

/*
 * make our pread/pwrite safe against themselves, but not against
 * normal read/write by using a mutex. slows down execution a lot,
 * but that's your problem, not mine.
 */
static mutex_t preadwritelock = X_MUTEX_INIT;

static ssize_t pread (int fd, void *buf, size_t count, off_t offset)
{
  ssize_t res;
  off_t ooffset;

  X_LOCK (preadwritelock);
  ooffset = lseek (fd, 0, SEEK_CUR);
  lseek (fd, offset, SEEK_SET);
  res = read (fd, buf, count);
  lseek (fd, ooffset, SEEK_SET);
  X_UNLOCK (preadwritelock);

  return res;
}

static ssize_t pwrite (int fd, void *buf, size_t count, off_t offset)
{
  ssize_t res;
  off_t ooffset;

  X_LOCK (preadwritelock);
  ooffset = lseek (fd, 0, SEEK_CUR);
  lseek (fd, offset, SEEK_SET);
  res = write (fd, buf, count);
  lseek (fd, offset, SEEK_SET);
  X_UNLOCK (preadwritelock);

  return res;
}
#endif

#ifndef HAVE_FUTIMES

# define utimes(path,times)  aio_utimes  (path, times)
# define futimes(fd,times)   aio_futimes (fd, times)

int aio_utimes (const char *filename, const struct timeval times[2])
{
  if (times)
    {
      struct utimbuf buf;

      buf.actime  = times[0].tv_sec;
      buf.modtime = times[1].tv_sec;

      return utime (filename, &buf);
    }
  else
    return utime (filename, 0);
}

int aio_futimes (int fd, const struct timeval tv[2])
{
  errno = ENOSYS;
  return -1;
}

#endif

#if !HAVE_FDATASYNC
# define fdatasync fsync
#endif

#if !HAVE_READAHEAD
# define readahead(fd,offset,count) aio_readahead (fd, offset, count, self)

static ssize_t aio_readahead (int fd, off_t offset, size_t count, worker *self)
{
  size_t todo = count;
  dBUF;

  while (todo > 0)
    {
      size_t len = todo < AIO_BUFSIZE ? todo : AIO_BUFSIZE;

      pread (fd, aio_buf, len, offset);
      offset += len;
      todo   -= len;
    }

  errno = 0;
  return count;
}

#endif

#if !HAVE_READDIR_R
# define readdir_r aio_readdir_r

static mutex_t readdirlock = X_MUTEX_INIT;
  
static int readdir_r (DIR *dirp, X_DIRENT *ent, X_DIRENT **res)
{
  X_DIRENT *e;
  int errorno;

  X_LOCK (readdirlock);

  e = readdir (dirp);
  errorno = errno;

  if (e)
    {
      *res = ent;
      strcpy (ent->d_name, e->d_name);
    }
  else
    *res = 0;

  X_UNLOCK (readdirlock);

  errno = errorno;
  return e ? 0 : -1;
}
#endif

/* sendfile always needs emulation */
static ssize_t sendfile_ (int ofd, int ifd, off_t offset, size_t count, worker *self)
{
  ssize_t res;

  if (!count)
    return 0;

#if HAVE_SENDFILE
# if __linux
  res = sendfile (ofd, ifd, &offset, count);

# elif __freebsd
  /*
   * Of course, the freebsd sendfile is a dire hack with no thoughts
   * wasted on making it similar to other I/O functions.
   */
  {
    off_t sbytes;
    res = sendfile (ifd, ofd, offset, count, 0, &sbytes, 0);

    if (res < 0 && sbytes)
      /* maybe only on EAGAIN: as usual, the manpage leaves you guessing */
      res = sbytes;
  }

# elif __hpux
  res = sendfile (ofd, ifd, offset, count, 0, 0);

# elif __solaris
  {
    struct sendfilevec vec;
    size_t sbytes;

    vec.sfv_fd   = ifd;
    vec.sfv_flag = 0;
    vec.sfv_off  = offset;
    vec.sfv_len  = count;

    res = sendfilev (ofd, &vec, 1, &sbytes);

    if (res < 0 && sbytes)
      res = sbytes;
  }

# endif
#else
  res = -1;
  errno = ENOSYS;
#endif

  if (res <  0
      && (errno == ENOSYS || errno == EINVAL || errno == ENOTSOCK
#if __solaris
          || errno == EAFNOSUPPORT || errno == EPROTOTYPE
#endif
         )
      )
    {
      /* emulate sendfile. this is a major pain in the ass */
      dBUF;

      res = 0;

      while (count)
        {
          ssize_t cnt;
          
          cnt = pread (ifd, aio_buf, count > AIO_BUFSIZE ? AIO_BUFSIZE : count, offset);

          if (cnt <= 0)
            {
              if (cnt && !res) res = -1;
              break;
            }

          cnt = write (ofd, aio_buf, cnt);

          if (cnt <= 0)
            {
              if (cnt && !res) res = -1;
              break;
            }

          offset += cnt;
          res    += cnt;
          count  -= cnt;
        }
    }

  return res;
}

/* read a full directory */
static void scandir_ (aio_req req, worker *self)
{
  DIR *dirp;
  union
  {    
    X_DIRENT d;
    char b [offsetof (X_DIRENT, d_name) + NAME_MAX + 1];
  } *u;
  X_DIRENT *entp;
  char *name, *names;
  int memlen = 4096;
  int memofs = 0;
  int res = 0;

  X_LOCK (wrklock);
  self->dirp = dirp = opendir (req->ptr1);
  self->dbuf = u = malloc (sizeof (*u));
  req->flags |= FLAG_PTR2_FREE;
  req->ptr2 = names = malloc (memlen);
  X_UNLOCK (wrklock);

  if (dirp && u && names)
    for (;;)
      {
        errno = 0;
        readdir_r (dirp, &u->d, &entp);

        if (!entp)
          break;

        name = entp->d_name;

        if (name [0] != '.' || (name [1] && (name [1] != '.' || name [2])))
          {
            int len = strlen (name) + 1;

            res++;

            while (memofs + len > memlen)
              {
                memlen *= 2;
                X_LOCK (wrklock);
                req->ptr2 = names = realloc (names, memlen);
                X_UNLOCK (wrklock);

                if (!names)
                  break;
              }

            memcpy (names + memofs, name, len);
            memofs += len;
          }
      }

  if (errno)
    res = -1;
  
  req->result = res;
}

/*****************************************************************************/

X_THREAD_PROC (aio_proc)
{
    {//D
  aio_req req;
  struct timespec ts;
  worker *self = (worker *)thr_arg;

  /* try to distribute timeouts somewhat randomly */
  ts.tv_nsec = ((unsigned long)self & 1023UL) * (1000000000UL / 1024UL);

  for (;;)
    {
      ts.tv_sec  = time (0) + IDLE_TIMEOUT;

      X_LOCK (reqlock);

      for (;;)
        {
          self->req = req = reqq_shift (&req_queue);

          if (req)
            break;

          ++idle;

          if (X_COND_TIMEDWAIT (reqwait, reqlock, ts)
              == ETIMEDOUT)
            {
              if (idle > max_idle)
                {
                  --idle;
                  X_UNLOCK (reqlock);
                  X_LOCK (wrklock);
                  --started;
                  X_UNLOCK (wrklock);
                  goto quit;
                }

              /* we are allowed to idle, so do so without any timeout */
              X_COND_WAIT (reqwait, reqlock);
              ts.tv_sec  = time (0) + IDLE_TIMEOUT;
            }

          --idle;
        }

      --nready;

      X_UNLOCK (reqlock);
     
      errno = 0; /* strictly unnecessary */

      if (!(req->flags & FLAG_CANCELLED))
        switch (req->type)
          {
            case REQ_READ:      req->result = req->offs >= 0
                                            ? pread     (req->int1, req->ptr1, req->size, req->offs)
                                            : read      (req->int1, req->ptr1, req->size); break;
            case REQ_WRITE:     req->result = req->offs >= 0
                                            ? pwrite    (req->int1, req->ptr1, req->size, req->offs)
                                            : write     (req->int1, req->ptr1, req->size); break;

            case REQ_READAHEAD: req->result = readahead (req->int1, req->offs, req->size); break;
            case REQ_SENDFILE:  req->result = sendfile_ (req->int1, req->int2, req->offs, req->size, self); break;

            case REQ_STAT:      req->result = stat      (req->ptr1, (Stat_t *)req->ptr2); break;
            case REQ_LSTAT:     req->result = lstat     (req->ptr1, (Stat_t *)req->ptr2); break;
            case REQ_FSTAT:     req->result = fstat     (req->int1, (Stat_t *)req->ptr2); break;

            case REQ_CHOWN:     req->result = chown     (req->ptr1, req->int2, req->int3); break;
            case REQ_FCHOWN:    req->result = fchown    (req->int1, req->int2, req->int3); break;
            case REQ_CHMOD:     req->result = chmod     (req->ptr1, req->mode); break;
            case REQ_FCHMOD:    req->result = fchmod    (req->int1, req->mode); break;
            case REQ_TRUNCATE:  req->result = truncate  (req->ptr1, req->offs); break;
            case REQ_FTRUNCATE: req->result = ftruncate (req->int1, req->offs); break;

            case REQ_OPEN:      req->result = open      (req->ptr1, req->int1, req->mode); break;
            case REQ_CLOSE:     req->result = close     (req->int1); break;
            case REQ_UNLINK:    req->result = unlink    (req->ptr1); break;
            case REQ_RMDIR:     req->result = rmdir     (req->ptr1); break;
            case REQ_MKDIR:     req->result = mkdir     (req->ptr1, req->mode); break;
            case REQ_RENAME:    req->result = rename    (req->ptr2, req->ptr1); break;
            case REQ_LINK:      req->result = link      (req->ptr2, req->ptr1); break;
            case REQ_SYMLINK:   req->result = symlink   (req->ptr2, req->ptr1); break;
            case REQ_MKNOD:     req->result = mknod     (req->ptr2, req->mode, (dev_t)req->offs); break;
            case REQ_READLINK:  req->result = readlink  (req->ptr2, req->ptr1, NAME_MAX); break;

            case REQ_SYNC:      req->result = 0; sync (); break;
            case REQ_FSYNC:     req->result = fsync     (req->int1); break;
            case REQ_FDATASYNC: req->result = fdatasync (req->int1); break;

            case REQ_READDIR:   scandir_ (req, self); break;

            case REQ_BUSY:
#ifdef _WIN32
	      Sleep (req->nv1 * 1000.);
#else
              {
                struct timeval tv;

                tv.tv_sec  = req->nv1;
                tv.tv_usec = (req->nv1 - tv.tv_sec) * 1000000.;

                req->result = select (0, 0, 0, 0, &tv);
              }
#endif
              break;

            case REQ_UTIME:
            case REQ_FUTIME:
              {
                struct timeval tv[2];
                struct timeval *times;

                if (req->nv1 != -1. || req->nv2 != -1.)
                  {
                    tv[0].tv_sec  = req->nv1;
                    tv[0].tv_usec = (req->nv1 - tv[0].tv_sec) * 1000000.;
                    tv[1].tv_sec  = req->nv2;
                    tv[1].tv_usec = (req->nv2 - tv[1].tv_sec) * 1000000.;

                    times = tv;
                  }
                else
                  times = 0;


                req->result = req->type == REQ_FUTIME
                              ? futimes (req->int1, times)
                              : utimes  (req->ptr1, times);
              }

            case REQ_GROUP:
            case REQ_NOP:
              break;

            case REQ_QUIT:
              goto quit;

            default:
              req->result = -1;
              break;
          }

      req->errorno = errno;

      X_LOCK (reslock);

      ++npending;

      if (!reqq_push (&res_queue, req))
        {
          /* write a dummy byte to the pipe so fh becomes ready */
          respipe_write (respipe_osf [1], (const void *)&respipe_osf, 1);

          /* optionally signal the main thread asynchronously */
          if (main_sig)
            pthread_kill (main_tid, main_sig);
        }

      self->req = 0;
      worker_clear (self);

      X_UNLOCK (reslock);
    }

quit:
  X_LOCK (wrklock);
  worker_free (self);
  X_UNLOCK (wrklock);

  return 0;
    }//D
}

/*****************************************************************************/

static void atfork_prepare (void)
{
  X_LOCK (wrklock);
  X_LOCK (reqlock);
  X_LOCK (reslock);
#if !HAVE_PREADWRITE
  X_LOCK (preadwritelock);
#endif
#if !HAVE_READDIR_R
  X_LOCK (readdirlock);
#endif
}

static void atfork_parent (void)
{
#if !HAVE_READDIR_R
  X_UNLOCK (readdirlock);
#endif
#if !HAVE_PREADWRITE
  X_UNLOCK (preadwritelock);
#endif
  X_UNLOCK (reslock);
  X_UNLOCK (reqlock);
  X_UNLOCK (wrklock);
}

static void atfork_child (void)
{
  aio_req prv;

  while (prv = reqq_shift (&req_queue))
    req_destroy (prv);

  while (prv = reqq_shift (&res_queue))
    req_destroy (prv);

  while (wrk_first.next != &wrk_first)
    {
      worker *wrk = wrk_first.next;

      if (wrk->req)
        req_destroy (wrk->req);

      worker_clear (wrk);
      worker_free (wrk);
    }

  started  = 0;
  idle     = 0;
  nreqs    = 0;
  nready   = 0;
  npending = 0;

  create_respipe ();

  atfork_parent ();
}

#define dREQ							\
  aio_req req;							\
  int req_pri = next_pri;					\
  next_pri = DEFAULT_PRI + PRI_BIAS;				\
								\
  if (SvOK (callback) && !SvROK (callback))			\
    croak ("callback must be undef or of reference type");	\
								\
  Newz (0, req, 1, aio_cb);					\
  if (!req)							\
    croak ("out of memory during aio_req allocation");		\
								\
  req->callback = newSVsv (callback);				\
  req->pri = req_pri

#define REQ_SEND						\
  req_send (req);						\
								\
  if (GIMME_V != G_VOID)					\
    XPUSHs (req_sv (req, AIO_REQ_KLASS));
	
MODULE = IO::AIO                PACKAGE = IO::AIO

PROTOTYPES: ENABLE

BOOT:
{
	stash = gv_stashpv ("IO::AIO", 1);

        newCONSTSUB (stash, "EXDEV",    newSViv (EXDEV));
        newCONSTSUB (stash, "O_RDONLY", newSViv (O_RDONLY));
        newCONSTSUB (stash, "O_WRONLY", newSViv (O_WRONLY));
        newCONSTSUB (stash, "O_CREAT",  newSViv (O_CREAT));
        newCONSTSUB (stash, "O_TRUNC",  newSViv (O_TRUNC));
#ifdef _WIN32
        X_MUTEX_CHECK (wrklock);
        X_MUTEX_CHECK (reslock);
        X_MUTEX_CHECK (reqlock);
        X_MUTEX_CHECK (reqwait);
        X_MUTEX_CHECK (preadwritelock);
        X_MUTEX_CHECK (readdirlock);

	X_COND_CHECK  (reqwait);
#else
        newCONSTSUB (stash, "S_IFIFO",  newSViv (S_IFIFO));
        newCONSTSUB (stash, "SIGIO",    newSViv (SIGIO));
#endif

        create_respipe ();

        X_THREAD_ATFORK (atfork_prepare, atfork_parent, atfork_child);
}

void
max_poll_reqs (int nreqs)
	PROTOTYPE: $
        CODE:
        max_poll_reqs = nreqs;

void
max_poll_time (double nseconds)
	PROTOTYPE: $
        CODE:
        max_poll_time = nseconds * AIO_TICKS;

void
min_parallel (int nthreads)
	PROTOTYPE: $

void
max_parallel (int nthreads)
	PROTOTYPE: $

void
max_idle (int nthreads)
	PROTOTYPE: $
        CODE:
        set_max_idle (nthreads);

int
max_outstanding (int maxreqs)
	PROTOTYPE: $
        CODE:
        RETVAL = max_outstanding;
        max_outstanding = maxreqs;
	OUTPUT:
        RETVAL

void
aio_open (SV8 *pathname, int flags, int mode, SV *callback=&PL_sv_undef)
	PROTOTYPE: $$$;$
	PPCODE:
{
        dREQ;

        req->type = REQ_OPEN;
        req->sv1  = newSVsv (pathname);
        req->ptr1 = SvPVbyte_nolen (req->sv1);
        req->int1 = flags;
        req->mode = mode;

        REQ_SEND;
}

void
aio_fsync (SV *fh, SV *callback=&PL_sv_undef)
	PROTOTYPE: $;$
        ALIAS:
           aio_fsync     = REQ_FSYNC
           aio_fdatasync = REQ_FDATASYNC
	PPCODE:
{
        dREQ;

        req->type = ix;
        req->sv1  = newSVsv (fh);
        req->int1 = PerlIO_fileno (IoIFP (sv_2io (fh)));

        REQ_SEND (req);
}

int
_dup (int fd)
	PROTOTYPE: $
        CODE:
        RETVAL = dup (fd);
	OUTPUT:
        RETVAL

void
_aio_close (int fd, SV *callback=&PL_sv_undef)
	PROTOTYPE: $;$
	PPCODE:
{
        dREQ;

        req->type = REQ_CLOSE;
        req->int1 = fd;

        REQ_SEND (req);
}

void
aio_read (SV *fh, SV *offset, SV *length, SV8 *data, IV dataoffset, SV *callback=&PL_sv_undef)
        ALIAS:
           aio_read  = REQ_READ
           aio_write = REQ_WRITE
	PROTOTYPE: $$$$$;$
        PPCODE:
{
        STRLEN svlen;
        char *svptr = SvPVbyte (data, svlen);
        UV len = SvUV (length);

        SvUPGRADE (data, SVt_PV);
        SvPOK_on (data);

        if (dataoffset < 0)
          dataoffset += svlen;

        if (dataoffset < 0 || dataoffset > svlen)
          croak ("dataoffset outside of data scalar");

        if (ix == REQ_WRITE)
          {
            /* write: check length and adjust. */
            if (!SvOK (length) || len + dataoffset > svlen)
              len = svlen - dataoffset;
          }
        else
          {
            /* read: grow scalar as necessary */
            svptr = SvGROW (data, len + dataoffset + 1);
          }

        if (len < 0)
          croak ("length must not be negative");

        {
          dREQ;

          req->type = ix;
          req->sv1  = newSVsv (fh);
          req->int1 = PerlIO_fileno (ix == REQ_READ ? IoIFP (sv_2io (fh))
                                                    : IoOFP (sv_2io (fh)));
          req->offs = SvOK (offset) ? SvVAL64 (offset) : -1;
          req->size = len;
          req->sv2  = SvREFCNT_inc (data);
          req->ptr1 = (char *)svptr + dataoffset;
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

        data = newSV (NAME_MAX);
        SvPOK_on (data);

        req->type = REQ_READLINK;
        req->sv1  = newSVsv (path);
        req->ptr2 = SvPVbyte_nolen (req->sv1);
        req->sv2  = data;
        req->ptr1 = SvPVbyte_nolen (data);

        REQ_SEND;
}

void
aio_sendfile (SV *out_fh, SV *in_fh, SV *in_offset, UV length, SV *callback=&PL_sv_undef)
	PROTOTYPE: $$$$;$
        PPCODE:
{
	dREQ;

        req->type = REQ_SENDFILE;
        req->sv1  = newSVsv (out_fh);
        req->int1 = PerlIO_fileno (IoIFP (sv_2io (out_fh)));
        req->sv2  = newSVsv (in_fh);
        req->int2 = PerlIO_fileno (IoIFP (sv_2io (in_fh)));
        req->offs = SvVAL64 (in_offset);
        req->size = length;

        REQ_SEND;
}

void
aio_readahead (SV *fh, SV *offset, IV length, SV *callback=&PL_sv_undef)
	PROTOTYPE: $$$;$
        PPCODE:
{
	dREQ;

        req->type = REQ_READAHEAD;
        req->sv1  = newSVsv (fh);
        req->int1 = PerlIO_fileno (IoIFP (sv_2io (fh)));
        req->offs = SvVAL64 (offset);
        req->size = length;

        REQ_SEND;
}

void
aio_stat (SV8 *fh_or_path, SV *callback=&PL_sv_undef)
        ALIAS:
           aio_stat  = REQ_STAT
           aio_lstat = REQ_LSTAT
	PPCODE:
{
	dREQ;

        req->ptr2 = malloc (sizeof (Stat_t));
        if (!req->ptr2)
          {
            req_destroy (req);
            croak ("out of memory during aio_stat statdata allocation");
          }

        req->flags |= FLAG_PTR2_FREE;
        req->sv1 = newSVsv (fh_or_path);

        if (SvPOK (fh_or_path))
          {
            req->type = ix;
            req->ptr1 = SvPVbyte_nolen (req->sv1);
          }
        else
          {
            req->type = REQ_FSTAT;
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

        if (SvPOK (fh_or_path))
          {
            req->type = REQ_UTIME;
            req->ptr1 = SvPVbyte_nolen (req->sv1);
          }
        else
          {
            req->type = REQ_FUTIME;
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

        if (SvPOK (fh_or_path))
          {
            req->type = REQ_TRUNCATE;
            req->ptr1 = SvPVbyte_nolen (req->sv1);
          }
        else
          {
            req->type = REQ_FTRUNCATE;
            req->int1 = PerlIO_fileno (IoIFP (sv_2io (fh_or_path)));
          }

        REQ_SEND;
}

void
aio_chmod (SV8 *fh_or_path, int mode, SV *callback=&PL_sv_undef)
	PPCODE:
{
	dREQ;

        req->mode = mode;
        req->sv1  = newSVsv (fh_or_path);

        if (SvPOK (fh_or_path))
          {
            req->type = REQ_CHMOD;
            req->ptr1 = SvPVbyte_nolen (req->sv1);
          }
        else
          {
            req->type = REQ_FCHMOD;
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

        if (SvPOK (fh_or_path))
          {
            req->type = REQ_CHOWN;
            req->ptr1 = SvPVbyte_nolen (req->sv1);
          }
        else
          {
            req->type = REQ_FCHOWN;
            req->int1 = PerlIO_fileno (IoIFP (sv_2io (fh_or_path)));
          }

        REQ_SEND;
}

void
aio_unlink (SV8 *pathname, SV *callback=&PL_sv_undef)
        ALIAS:
           aio_unlink  = REQ_UNLINK
           aio_rmdir   = REQ_RMDIR
           aio_readdir = REQ_READDIR
	PPCODE:
{
	dREQ;
	
        req->type = ix;
	req->sv1  = newSVsv (pathname);
	req->ptr1 = SvPVbyte_nolen (req->sv1);

	REQ_SEND;
}

void
aio_mkdir (SV8 *pathname, int mode, SV *callback=&PL_sv_undef)
	PPCODE:
{
	dREQ;
	
        req->type = REQ_MKDIR;
	req->sv1  = newSVsv (pathname);
	req->ptr1 = SvPVbyte_nolen (req->sv1);
        req->mode = mode;

	REQ_SEND;
}

void
aio_link (SV8 *oldpath, SV8 *newpath, SV *callback=&PL_sv_undef)
        ALIAS:
           aio_link    = REQ_LINK
           aio_symlink = REQ_SYMLINK
           aio_rename  = REQ_RENAME
	PPCODE:
{
	dREQ;
	
        req->type = ix;
	req->sv2  = newSVsv (oldpath);
	req->ptr2 = SvPVbyte_nolen (req->sv2);
	req->sv1  = newSVsv (newpath);
	req->ptr1 = SvPVbyte_nolen (req->sv1);
	
	REQ_SEND;
}

void
aio_mknod (SV8 *pathname, int mode, UV dev, SV *callback=&PL_sv_undef)
	PPCODE:
{
	dREQ;
	
        req->type = REQ_MKNOD;
	req->sv1  = newSVsv (pathname);
	req->ptr1 = SvPVbyte_nolen (req->sv1);
        req->mode = (mode_t)mode;
        req->offs = dev;
	
	REQ_SEND;
}

void
aio_busy (double delay, SV *callback=&PL_sv_undef)
	PPCODE:
{
	dREQ;

        req->type = REQ_BUSY;
        req->nv1  = delay < 0. ? 0. : delay;

	REQ_SEND;
}

void
aio_group (SV *callback=&PL_sv_undef)
	PROTOTYPE: ;$
        PPCODE:
{
	dREQ;

        req->type = REQ_GROUP;

        req_send (req);
        XPUSHs (req_sv (req, AIO_GRP_KLASS));
}

void
aio_nop (SV *callback=&PL_sv_undef)
	ALIAS:
           aio_nop  = REQ_NOP
           aio_sync = REQ_SYNC
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
	RETVAL = next_pri - PRI_BIAS;
	if (items > 0)
	  {
	    if (pri < PRI_MIN) pri = PRI_MIN;
	    if (pri > PRI_MAX) pri = PRI_MAX;
	    next_pri = pri + PRI_BIAS;
	  }
	OUTPUT:
	RETVAL

void
aioreq_nice (int nice = 0)
	CODE:
	nice = next_pri - nice;
	if (nice < PRI_MIN) nice = PRI_MIN;
	if (nice > PRI_MAX) nice = PRI_MAX;
	next_pri = nice + PRI_BIAS;

void
flush ()
	PROTOTYPE:
	CODE:
        while (nreqs)
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

void
setsig (int signum = SIGIO)
	PROTOTYPE: ;$
        CODE:
{
        if (block_sig_level)
          croak ("cannot call IO::AIO::setsig from within aio_block/callback");

        X_LOCK (reslock);
        main_tid = pthread_self ();
        main_sig = signum;
        X_UNLOCK (reslock);

        if (main_sig && npending)
	  pthread_kill (main_tid, main_sig);
}

void
aio_block (SV *cb)
	PROTOTYPE: &
        PPCODE:
{
	int count;

        block_sig ();
        PUSHMARK (SP);
        PUTBACK;
        count = call_sv (cb, GIMME_V | G_NOARGS | G_EVAL);
        unblock_sig ();

        if (SvTRUE (ERRSV))
          croak (0);

        XSRETURN (count);
}

int
nreqs()
	PROTOTYPE:
	CODE:
        RETVAL = nreqs;
	OUTPUT:
	RETVAL

int
nready()
	PROTOTYPE:
	CODE:
        RETVAL = get_nready ();
	OUTPUT:
	RETVAL

int
npending()
	PROTOTYPE:
	CODE:
        RETVAL = get_npending ();
	OUTPUT:
	RETVAL

int
nthreads()
	PROTOTYPE:
	CODE:
        if (WORDACCESS_UNSAFE) X_LOCK   (wrklock);
        RETVAL = started;
        if (WORDACCESS_UNSAFE) X_UNLOCK (wrklock);
	OUTPUT:
	RETVAL

PROTOTYPES: DISABLE

MODULE = IO::AIO                PACKAGE = IO::AIO::REQ

void
cancel (aio_req_ornot req)
	CODE:
        req_cancel (req);

void
cb (aio_req_ornot req, SV *callback=&PL_sv_undef)
	CODE:
        SvREFCNT_dec (req->callback);
        req->callback = newSVsv (callback);

MODULE = IO::AIO                PACKAGE = IO::AIO::GRP

void
add (aio_req grp, ...)
        PPCODE:
{
	int i;
        aio_req req;

        if (main_sig && !block_sig_level)
          croak ("aio_group->add called outside aio_block/callback context while IO::AIO::setsig is in use");

        if (grp->int1 == 2)
          croak ("cannot add requests to IO::AIO::GRP after the group finished");

	for (i = 1; i < items; ++i )
          {
            if (GIMME_V != G_VOID)
              XPUSHs (sv_2mortal (newSVsv (ST (i))));

            req = SvAIO_REQ (ST (i));

            if (req)
              {
                ++grp->size;
                req->grp = grp;

                req->grp_prev = 0;
                req->grp_next = grp->grp_first;

                if (grp->grp_first)
                  grp->grp_first->grp_prev = req;

                grp->grp_first = req;
              }
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
        grp->int2 = limit;
        aio_grp_feed (grp);

void
feed (aio_req grp, SV *callback=&PL_sv_undef)
	CODE:
{
        SvREFCNT_dec (grp->sv2);
        grp->sv2 = newSVsv (callback);

        if (grp->int2 <= 0)
          grp->int2 = 2;

        aio_grp_feed (grp);
}

