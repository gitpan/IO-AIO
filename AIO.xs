/* solaris */
#define _POSIX_PTHREAD_SEMANTICS 1

#if __linux && !defined(_GNU_SOURCE)
# define _GNU_SOURCE
#endif

/* just in case */
#define _REENTRANT 1

#include <errno.h>

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "autoconf/config.h"

#include <pthread.h>

#include <stddef.h>
#include <stdlib.h>
#include <errno.h>
#include <sys/time.h>
#include <sys/select.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <limits.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <sched.h>

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

#ifndef PTHREAD_STACK_MIN
/* care for broken platforms, e.g. windows */
# define PTHREAD_STACK_MIN 16384
#endif

#if __ia64
# define STACKSIZE 65536
#elif __i386 || __x86_64 /* 16k is unreasonably high :( */
# define STACKSIZE PTHREAD_STACK_MIN
#else
# define STACKSIZE 16384
#endif

/* wether word reads are potentially non-atomic.
 * this is conservatice, likely most arches this runs
 * on have atomic word read/writes.
 */
#ifndef WORDACCESS_UNSAFE
# if __i386 || __x86_64
#  define WORDACCESS_UNSAFE 0
# else
#  define WORDACCESS_UNSAFE 1
# endif
#endif

/* buffer size for various temporary buffers */
#define AIO_BUFSIZE 65536

#define dBUF	 				\
  char *aio_buf;				\
  LOCK (wrklock);				\
  self->dbuf = aio_buf = malloc (AIO_BUFSIZE);	\
  UNLOCK (wrklock);				\
  if (!aio_buf)					\
    return -1;

typedef SV SV8; /* byte-sv, used for argument-checking */

enum {
  REQ_QUIT,
  REQ_OPEN, REQ_CLOSE,
  REQ_READ, REQ_WRITE, REQ_READAHEAD,
  REQ_SENDFILE,
  REQ_STAT, REQ_LSTAT, REQ_FSTAT,
  REQ_FSYNC, REQ_FDATASYNC,
  REQ_UNLINK, REQ_RMDIR, REQ_RENAME,
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

  SV *callback, *fh;
  SV *sv1, *sv2;
  void *ptr1, *ptr2;
  off_t offs;
  size_t size;
  ssize_t result;

  STRLEN stroffset;
  int type;
  int int1, int2;
  int errorno;
  mode_t mode; /* open */

  unsigned char flags;
  unsigned char pri;

  SV *self; /* the perl counterpart of this request, if any */
  struct aio_cb *grp, *grp_prev, *grp_next, *grp_first;
} aio_cb;

enum {
  FLAG_CANCELLED     = 0x01, /* request was cancelled */
  FLAG_SV1_RO_OFF    = 0x40, /* data was set readonly */
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

static pthread_t main_tid;
static int main_sig;
static int block_sig_level;

void block_sig ()
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

void unblock_sig ()
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

#if __linux && defined (PTHREAD_ADAPTIVE_MUTEX_INITIALIZER_NP)
# define AIO_MUTEX_INIT PTHREAD_ADAPTIVE_MUTEX_INITIALIZER_NP
#else
# define AIO_MUTEX_INIT PTHREAD_MUTEX_INITIALIZER
#endif

#define LOCK(mutex)   pthread_mutex_lock   (&(mutex))
#define UNLOCK(mutex) pthread_mutex_unlock (&(mutex))

/* worker threads management */
static pthread_mutex_t wrklock = AIO_MUTEX_INIT;

typedef struct worker {
  /* locked by wrklock */
  struct worker *prev, *next;

  pthread_t tid;

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
static int respipe [2];

static pthread_mutex_t reslock = AIO_MUTEX_INIT;
static pthread_mutex_t reqlock = AIO_MUTEX_INIT;
static pthread_cond_t  reqwait = PTHREAD_COND_INITIALIZER;

#if WORDACCESS_UNSAFE

static unsigned int get_nready ()
{
  unsigned int retval;

  LOCK   (reqlock);
  retval = nready;
  UNLOCK (reqlock);

  return retval;
}

static unsigned int get_npending ()
{
  unsigned int retval;

  LOCK   (reslock);
  retval = npending;
  UNLOCK (reslock);

  return retval;
}

static unsigned int get_nthreads ()
{
  unsigned int retval;

  LOCK   (wrklock);
  retval = started;
  UNLOCK (wrklock);

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

static int poll_cb ();
static int req_invoke (aio_req req);
static void req_free (aio_req req);
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
          req_free (grp);
          unblock_sig ();
          croak (0);
        }

      req_free (grp);
      unblock_sig ();
    }
}

static int req_invoke (aio_req req)
{
  dSP;

  if (req->flags & FLAG_SV1_RO_OFF)
    SvREADONLY_off (req->sv1);

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
              SV *fh;

              PUSHs (sv_2mortal (newSViv (req->result)));
              PUTBACK;
              call_pv ("IO::AIO::_fd2fh", G_SCALAR | G_EVAL);
              SPAGAIN;

              fh = POPs;
              PUSHMARK (SP);
              XPUSHs (fh);
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
                SvCUR_set (req->sv1, req->result);
                *SvEND (req->sv1) = 0;
                PUSHs (req->sv1);
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
            SvCUR_set (req->sv1, req->stroffset + (req->result > 0 ? req->result : 0));
            *SvEND (req->sv1) = 0;
            PUSHs (sv_2mortal (newSViv (req->result)));
            break;

          default:
            PUSHs (sv_2mortal (newSViv (req->result)));
            break;
        }

      errno = req->errorno;

      PUTBACK;
      call_sv (req->callback, G_VOID | G_EVAL);
      SPAGAIN;

      FREETMPS;
      LEAVE;
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

static void req_free (aio_req req)
{
  if (req->self)
    {
      sv_unmagic (req->self, PERL_MAGIC_ext);
      SvREFCNT_dec (req->self);
    }

  SvREFCNT_dec (req->fh);
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

static void *aio_proc(void *arg);

static void start_thread (void)
{
  sigset_t fullsigset, oldsigset;
  pthread_attr_t attr;

  worker *wrk = calloc (1, sizeof (worker));

  if (!wrk)
    croak ("unable to allocate worker thread data");

  pthread_attr_init (&attr);
  pthread_attr_setstacksize (&attr, STACKSIZE);
  pthread_attr_setdetachstate (&attr, PTHREAD_CREATE_DETACHED);
#ifdef PTHREAD_SCOPE_PROCESS
  pthread_attr_setscope (&attr, PTHREAD_SCOPE_PROCESS);
#endif

  sigfillset (&fullsigset);

  LOCK (wrklock);
  pthread_sigmask (SIG_SETMASK, &fullsigset, &oldsigset);

  if (pthread_create (&wrk->tid, &attr, aio_proc, (void *)wrk) == 0)
    {
      wrk->prev = &wrk_first;
      wrk->next = wrk_first.next;
      wrk_first.next->prev = wrk;
      wrk_first.next = wrk;
      ++started;
    }
  else
    free (wrk);

  pthread_sigmask (SIG_SETMASK, &oldsigset, 0);
  UNLOCK (wrklock);
}

static void maybe_start_thread ()
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

  LOCK (reqlock);
  ++nready;
  reqq_push (&req_queue, req);
  pthread_cond_signal (&reqwait);
  UNLOCK (reqlock);

  unblock_sig ();

  maybe_start_thread ();
}

static void end_thread (void)
{
  aio_req req;

  Newz (0, req, 1, aio_cb);

  req->type = REQ_QUIT;
  req->pri  = PRI_MAX + PRI_BIAS;

  LOCK (reqlock);
  reqq_push (&req_queue, req);
  pthread_cond_signal (&reqwait);
  UNLOCK (reqlock);

  LOCK (wrklock);
  --started;
  UNLOCK (wrklock);
}

static void set_max_idle (int nthreads)
{
  if (WORDACCESS_UNSAFE) LOCK   (reqlock);
  max_idle = nthreads <= 0 ? 1 : nthreads;
  if (WORDACCESS_UNSAFE) UNLOCK (reqlock);
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

static void poll_wait ()
{
  fd_set rfd;

  while (nreqs)
    {
      int size;
      if (WORDACCESS_UNSAFE) LOCK   (reslock);
      size = res_queue.size;
      if (WORDACCESS_UNSAFE) UNLOCK (reslock);

      if (size)
        return;

      maybe_start_thread ();

      FD_ZERO(&rfd);
      FD_SET(respipe [0], &rfd);

      select (respipe [0] + 1, &rfd, 0, 0, 0);
    }
}

static int poll_cb ()
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

          LOCK (reslock);
          req = reqq_shift (&res_queue);

          if (req)
            {
              --npending;

              if (!res_queue.size)
                {
                  /* read any signals sent by the worker threads */
                  char buf [4];
                  while (read (respipe [0], buf, 4) == 4)
                    ;
                }
            }

          UNLOCK (reslock);

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
                  req_free (req);
                  unblock_sig ();
                  croak (0);
                }

              count++;
            }

          req_free (req);

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

static void create_pipe ()
{
  if (pipe (respipe))
    croak ("unable to initialize result pipe");

  if (fcntl (respipe [0], F_SETFL, O_NONBLOCK))
    croak ("cannot set result pipe to nonblocking mode");

  if (fcntl (respipe [1], F_SETFL, O_NONBLOCK))
    croak ("cannot set result pipe to nonblocking mode");
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
static pthread_mutex_t preadwritelock = PTHREAD_MUTEX_INITIALIZER;

static ssize_t pread (int fd, void *buf, size_t count, off_t offset)
{
  ssize_t res;
  off_t ooffset;

  LOCK (preadwritelock);
  ooffset = lseek (fd, 0, SEEK_CUR);
  lseek (fd, offset, SEEK_SET);
  res = read (fd, buf, count);
  lseek (fd, ooffset, SEEK_SET);
  UNLOCK (preadwritelock);

  return res;
}

static ssize_t pwrite (int fd, void *buf, size_t count, off_t offset)
{
  ssize_t res;
  off_t ooffset;

  LOCK (preadwritelock);
  ooffset = lseek (fd, 0, SEEK_CUR);
  lseek (fd, offset, SEEK_SET);
  res = write (fd, buf, count);
  lseek (fd, offset, SEEK_SET);
  UNLOCK (preadwritelock);

  return res;
}
#endif

#if !HAVE_FDATASYNC
# define fdatasync fsync
#endif

#if !HAVE_READAHEAD
# define readahead(fd,offset,count) aio_readahead (fd, offset, count, self)

static ssize_t aio_readahead (int fd, off_t offset, size_t count, worker *self)
{
  dBUF;

  while (count > 0)
    {
      size_t len = count < AIO_BUFSIZE ? count : AIO_BUFSIZE;

      pread (fd, aio_buf, len, offset);
      offset += len;
      count  -= len;
    }

  errno = 0;
}

#endif

#if !HAVE_READDIR_R
# define readdir_r aio_readdir_r

static pthread_mutex_t readdirlock = PTHREAD_MUTEX_INITIALIZER;
  
static int readdir_r (DIR *dirp, struct dirent *ent, struct dirent **res)
{
  struct dirent *e;
  int errorno;

  LOCK (readdirlock);

  e = readdir (dirp);
  errorno = errno;

  if (e)
    {
      *res = ent;
      strcpy (ent->d_name, e->d_name);
    }
  else
    *res = 0;

  UNLOCK (readdirlock);

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
    struct dirent d;
    char b [offsetof (struct dirent, d_name) + NAME_MAX + 1];
  } *u;
  struct dirent *entp;
  char *name, *names;
  int memlen = 4096;
  int memofs = 0;
  int res = 0;
  int errorno;

  LOCK (wrklock);
  self->dirp = dirp = opendir (req->ptr1);
  self->dbuf = u = malloc (sizeof (*u));
  req->flags |= FLAG_PTR2_FREE;
  req->ptr2 = names = malloc (memlen);
  UNLOCK (wrklock);

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
                LOCK (wrklock);
                req->ptr2 = names = realloc (names, memlen);
                UNLOCK (wrklock);

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

static void *aio_proc (void *thr_arg)
{
  aio_req req;
  struct timespec ts;
  worker *self = (worker *)thr_arg;

  /* try to distribute timeouts somewhat evenly */
  ts.tv_nsec = (((unsigned long)self + (unsigned long)ts.tv_sec) & 1023UL)
               * (1000000000UL / 1024UL);

  for (;;)
    {
      ts.tv_sec  = time (0) + IDLE_TIMEOUT;

      LOCK (reqlock);

      for (;;)
        {
          self->req = req = reqq_shift (&req_queue);

          if (req)
            break;

          ++idle;

          if (pthread_cond_timedwait (&reqwait, &reqlock, &ts)
              == ETIMEDOUT)
            {
              if (idle > max_idle)
                {
                  --idle;
                  UNLOCK (reqlock);
                  LOCK (wrklock);
                  --started;
                  UNLOCK (wrklock);
                  goto quit;
                }

              /* we are allowed to idle, so do so without any timeout */
              pthread_cond_wait (&reqwait, &reqlock);
              ts.tv_sec  = time (0) + IDLE_TIMEOUT;
            }

          --idle;
        }

      --nready;

      UNLOCK (reqlock);
     
      errno = 0; /* strictly unnecessary */

      if (!(req->flags & FLAG_CANCELLED))
        switch (req->type)
          {
            case REQ_READ:      req->result = pread     (req->int1, req->ptr1, req->size, req->offs); break;
            case REQ_WRITE:     req->result = pwrite    (req->int1, req->ptr1, req->size, req->offs); break;

            case REQ_READAHEAD: req->result = readahead (req->int1, req->offs, req->size); break;
            case REQ_SENDFILE:  req->result = sendfile_ (req->int1, req->int2, req->offs, req->size, self); break;

            case REQ_STAT:      req->result = stat      (req->ptr1, (Stat_t *)req->ptr2); break;
            case REQ_LSTAT:     req->result = lstat     (req->ptr1, (Stat_t *)req->ptr2); break;
            case REQ_FSTAT:     req->result = fstat     (req->int1, (Stat_t *)req->ptr2); break;

            case REQ_OPEN:      req->result = open      (req->ptr1, req->int1, req->mode); break;
            case REQ_CLOSE:     req->result = close     (req->int1); break;
            case REQ_UNLINK:    req->result = unlink    (req->ptr1); break;
            case REQ_RMDIR:     req->result = rmdir     (req->ptr1); break;
            case REQ_RENAME:    req->result = rename    (req->ptr2, req->ptr1); break;
            case REQ_LINK:      req->result = link      (req->ptr2, req->ptr1); break;
            case REQ_SYMLINK:   req->result = symlink   (req->ptr2, req->ptr1); break;
            case REQ_MKNOD:     req->result = mknod     (req->ptr2, req->mode, (dev_t)req->offs); break;
            case REQ_READLINK:  req->result = readlink  (req->ptr2, req->ptr1, NAME_MAX); break;

            case REQ_FDATASYNC: req->result = fdatasync (req->int1); break;
            case REQ_FSYNC:     req->result = fsync     (req->int1); break;
            case REQ_READDIR:   scandir_ (req, self); break;

            case REQ_BUSY:
              {
                struct timeval tv;

                tv.tv_sec  = req->int1;
                tv.tv_usec = req->int2;

                req->result = select (0, 0, 0, 0, &tv);
              }

            case REQ_GROUP:
            case REQ_NOP:
              break;

            case REQ_QUIT:
              goto quit;

            default:
              req->result = ENOSYS;
              break;
          }

      req->errorno = errno;

      LOCK (reslock);

      ++npending;

      if (!reqq_push (&res_queue, req))
        {
          /* write a dummy byte to the pipe so fh becomes ready */
          write (respipe [1], &respipe, 1);

          /* optionally signal the main thread asynchronously */
          if (main_sig)
            pthread_kill (main_tid, main_sig);
        }

      self->req = 0;
      worker_clear (self);

      UNLOCK (reslock);
    }

quit:
  LOCK (wrklock);
  worker_free (self);
  UNLOCK (wrklock);

  return 0;
}

/*****************************************************************************/

static void atfork_prepare (void)
{
  LOCK (wrklock);
  LOCK (reqlock);
  LOCK (reslock);
#if !HAVE_PREADWRITE
  LOCK (preadwritelock);
#endif
#if !HAVE_READDIR_R
  LOCK (readdirlock);
#endif
}

static void atfork_parent (void)
{
#if !HAVE_READDIR_R
  UNLOCK (readdirlock);
#endif
#if !HAVE_PREADWRITE
  UNLOCK (preadwritelock);
#endif
  UNLOCK (reslock);
  UNLOCK (reqlock);
  UNLOCK (wrklock);
}

static void atfork_child (void)
{
  aio_req prv;

  while (prv = reqq_shift (&req_queue))
    req_free (prv);

  while (prv = reqq_shift (&res_queue))
    req_free (prv);

  while (wrk_first.next != &wrk_first)
    {
      worker *wrk = wrk_first.next;

      if (wrk->req)
        req_free (wrk->req);

      worker_clear (wrk);
      worker_free (wrk);
    }

  started  = 0;
  idle     = 0;
  nreqs    = 0;
  nready   = 0;
  npending = 0;

  close (respipe [0]);
  close (respipe [1]);
  create_pipe ();

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
	HV *stash = gv_stashpv ("IO::AIO", 1);

        newCONSTSUB (stash, "EXDEV",    newSViv (EXDEV));
        newCONSTSUB (stash, "O_RDONLY", newSViv (O_RDONLY));
        newCONSTSUB (stash, "O_WRONLY", newSViv (O_WRONLY));
        newCONSTSUB (stash, "O_CREAT",  newSViv (O_CREAT));
        newCONSTSUB (stash, "O_TRUNC",  newSViv (O_TRUNC));
        newCONSTSUB (stash, "S_IFIFO",  newSViv (S_IFIFO));
        newCONSTSUB (stash, "SIGIO",    newSViv (SIGIO));

	create_pipe ();
        pthread_atfork (atfork_prepare, atfork_parent, atfork_child);
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
aio_open (pathname,flags,mode,callback=&PL_sv_undef)
	SV8 *	pathname
        int	flags
        int	mode
        SV *	callback
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
aio_close (fh,callback=&PL_sv_undef)
	SV *	fh
        SV *	callback
	PROTOTYPE: $;$
        ALIAS:
           aio_close     = REQ_CLOSE
           aio_fsync     = REQ_FSYNC
           aio_fdatasync = REQ_FDATASYNC
	PPCODE:
{
        dREQ;

        req->type = ix;
        req->fh   = newSVsv (fh);
        req->int1 = PerlIO_fileno (IoIFP (sv_2io (fh)));

        REQ_SEND (req);
}

void
aio_read (fh,offset,length,data,dataoffset,callback=&PL_sv_undef)
	SV *	fh
        UV	offset
        UV	length
        SV8 *	data
        UV	dataoffset
        SV *	callback
        ALIAS:
           aio_read  = REQ_READ
           aio_write = REQ_WRITE
	PROTOTYPE: $$$$$;$
        PPCODE:
{
        STRLEN svlen;
        char *svptr = SvPVbyte (data, svlen);

        SvUPGRADE (data, SVt_PV);
        SvPOK_on (data);

        if (dataoffset < 0)
          dataoffset += svlen;

        if (dataoffset < 0 || dataoffset > svlen)
          croak ("data offset outside of string");

        if (ix == REQ_WRITE)
          {
            /* write: check length and adjust. */
            if (length < 0 || length + dataoffset > svlen)
              length = svlen - dataoffset;
          }
        else
          {
            /* read: grow scalar as necessary */
            svptr = SvGROW (data, length + dataoffset + 1);
          }

        if (length < 0)
          croak ("length must not be negative");

        {
          dREQ;

          req->type = ix;
          req->fh   = newSVsv (fh);
          req->int1 = PerlIO_fileno (ix == REQ_READ ? IoIFP (sv_2io (fh))
                                                    : IoOFP (sv_2io (fh)));
          req->offs = offset;
          req->size = length;
          req->sv1  = SvREFCNT_inc (data);
          req->ptr1 = (char *)svptr + dataoffset;
          req->stroffset = dataoffset;

          if (!SvREADONLY (data))
            {
              SvREADONLY_on (data);
              req->flags |= FLAG_SV1_RO_OFF;
            }

          REQ_SEND;
        }
}

void
aio_readlink (path,callback=&PL_sv_undef)
	SV8 *	path
        SV *	callback
	PROTOTYPE: $$;$
        PPCODE:
{
	SV *data;
        dREQ;

        data = newSV (NAME_MAX);
        SvPOK_on (data);

        req->type = REQ_READLINK;
        req->fh   = newSVsv (path);
        req->ptr2 = SvPVbyte_nolen (req->fh);
        req->sv1  = data;
        req->ptr1 = SvPVbyte_nolen (data);

        REQ_SEND;
}

void
aio_sendfile (out_fh,in_fh,in_offset,length,callback=&PL_sv_undef)
        SV *	out_fh
        SV *	in_fh
        UV	in_offset
        UV	length
        SV *	callback
	PROTOTYPE: $$$$;$
        PPCODE:
{
	dREQ;

        req->type = REQ_SENDFILE;
        req->fh   = newSVsv (out_fh);
        req->int1 = PerlIO_fileno (IoIFP (sv_2io (out_fh)));
        req->sv2  = newSVsv (in_fh);
        req->int2 = PerlIO_fileno (IoIFP (sv_2io (in_fh)));
        req->offs = in_offset;
        req->size = length;

        REQ_SEND;
}

void
aio_readahead (fh,offset,length,callback=&PL_sv_undef)
        SV *	fh
        UV	offset
        IV	length
        SV *	callback
	PROTOTYPE: $$$;$
        PPCODE:
{
	dREQ;

        req->type = REQ_READAHEAD;
        req->fh   = newSVsv (fh);
        req->int1 = PerlIO_fileno (IoIFP (sv_2io (fh)));
        req->offs = offset;
        req->size = length;

        REQ_SEND;
}

void
aio_stat (fh_or_path,callback=&PL_sv_undef)
        SV8 *		fh_or_path
        SV *		callback
        ALIAS:
           aio_stat  = REQ_STAT
           aio_lstat = REQ_LSTAT
	PPCODE:
{
	dREQ;

        req->ptr2 = malloc (sizeof (Stat_t));
        if (!req->ptr2)
          {
            req_free (req);
            croak ("out of memory during aio_stat statdata allocation");
          }

        req->flags |= FLAG_PTR2_FREE;

        if (SvPOK (fh_or_path))
          {
            req->type = ix;
            req->sv1  = newSVsv (fh_or_path);
            req->ptr1 = SvPVbyte_nolen (req->sv1);
          }
        else
          {
            req->type = REQ_FSTAT;
            req->fh   = newSVsv (fh_or_path);
            req->int1 = PerlIO_fileno (IoIFP (sv_2io (fh_or_path)));
          }

        REQ_SEND;
}

void
aio_unlink (pathname,callback=&PL_sv_undef)
	SV8 *	pathname
	SV *	callback
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
aio_link (oldpath,newpath,callback=&PL_sv_undef)
	SV8 *	oldpath
	SV8 *	newpath
	SV *	callback
        ALIAS:
           aio_link    = REQ_LINK
           aio_symlink = REQ_SYMLINK
           aio_rename  = REQ_RENAME
	PPCODE:
{
	dREQ;
	
        req->type = ix;
	req->fh   = newSVsv (oldpath);
	req->ptr2 = SvPVbyte_nolen (req->fh);
	req->sv1  = newSVsv (newpath);
	req->ptr1 = SvPVbyte_nolen (req->sv1);
	
	REQ_SEND;
}

void
aio_mknod (pathname,mode,dev,callback=&PL_sv_undef)
	SV8 *	pathname
	SV *	callback
        UV	mode
        UV	dev
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
aio_busy (delay,callback=&PL_sv_undef)
	double	delay
	SV *	callback
	PPCODE:
{
	dREQ;

        req->type = REQ_BUSY;
        req->int1 = delay < 0. ? 0 : delay;
        req->int2 = delay < 0. ? 0 : 1000. * (delay - req->int1);

	REQ_SEND;
}

void
aio_group (callback=&PL_sv_undef)
        SV *	callback
	PROTOTYPE: ;$
        PPCODE:
{
	dREQ;

        req->type = REQ_GROUP;

        req_send (req);
        XPUSHs (req_sv (req, AIO_GRP_KLASS));
}

void
aio_nop (callback=&PL_sv_undef)
	SV *	callback
	PPCODE:
{
	dREQ;

        req->type = REQ_NOP;

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

        LOCK (reslock);
        main_tid = pthread_self ();
        main_sig = signum;
        UNLOCK (reslock);

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
        SPAGAIN;
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
        if (WORDACCESS_UNSAFE) LOCK   (wrklock);
        RETVAL = started;
        if (WORDACCESS_UNSAFE) UNLOCK (wrklock);
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

