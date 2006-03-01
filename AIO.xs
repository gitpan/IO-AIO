#define _REENTRANT 1
#include <errno.h>

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "autoconf/config.h"

#include <pthread.h>

#include <stddef.h>
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

/* used for struct dirent, AIX doesn't provide it */
#ifndef NAME_MAX
# define NAME_MAX 4096
#endif

#if __ia64
# define STACKSIZE 65536
#else
# define STACKSIZE  8192
#endif

enum {
  REQ_QUIT,
  REQ_OPEN, REQ_CLOSE,
  REQ_READ, REQ_WRITE, REQ_READAHEAD,
  REQ_SENDFILE,
  REQ_STAT, REQ_LSTAT, REQ_FSTAT,
  REQ_FSYNC, REQ_FDATASYNC,
  REQ_UNLINK, REQ_RMDIR,
  REQ_READDIR,
  REQ_SYMLINK,
};

typedef struct aio_cb {
  struct aio_cb *volatile next;

  int type;

  /* should receive a cleanup, with unions */
  int fd, fd2;
  off_t offset;
  size_t length;
  ssize_t result;
  mode_t mode; /* open */
  int errorno;
  SV *data, *callback;
  SV *fh, *fh2;
  void *dataptr, *data2ptr;
  STRLEN dataoffset;

  Stat_t *statdata;
} aio_cb;

typedef aio_cb *aio_req;

static int started, wanted;
static volatile int nreqs;
static int max_outstanding = 1<<30;
static int respipe [2];

static pthread_mutex_t reslock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t reqlock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  reqwait = PTHREAD_COND_INITIALIZER;

static volatile aio_req reqs, reqe; /* queue start, queue end */
static volatile aio_req ress, rese; /* queue start, queue end */

static void free_req (aio_req req)
{
  if (req->data)
    SvREFCNT_dec (req->data);

  if (req->fh)
    SvREFCNT_dec (req->fh);

  if (req->fh2)
    SvREFCNT_dec (req->fh2);

  if (req->statdata)
    Safefree (req->statdata);

  if (req->callback)
    SvREFCNT_dec (req->callback);

  if (req->type == REQ_READDIR && req->result >= 0)
    free (req->data2ptr);

  Safefree (req);
}

static void
poll_wait ()
{
  if (nreqs && !ress)
    {
      fd_set rfd;
      FD_ZERO(&rfd);
      FD_SET(respipe [0], &rfd);

      select (respipe [0] + 1, &rfd, 0, 0, 0);
    }
}

static int
poll_cb ()
{
  dSP;
  int count = 0;
  int do_croak = 0;
  aio_req req;

  for (;;)
    {
      pthread_mutex_lock (&reslock);
      req = ress;

      if (req)
        {
          ress = req->next;

          if (!ress)
            {
              /* read any signals sent by the worker threads */
              char buf [32];
              while (read (respipe [0], buf, 32) == 32)
                ;

              rese = 0;
            }
        }

      pthread_mutex_unlock (&reslock);

      if (!req)
        break;

      nreqs--;

      if (req->type == REQ_QUIT)
        started--;
      else
        {
          int errorno = errno;
          errno = req->errorno;

          if (req->type == REQ_READ)
            SvCUR_set (req->data, req->dataoffset + (req->result > 0 ? req->result : 0));

          if (req->data2ptr && (req->type == REQ_READ || req->type == REQ_WRITE))
            SvREADONLY_off (req->data);

          if (req->statdata)
            {
              PL_laststype   = req->type == REQ_LSTAT ? OP_LSTAT : OP_STAT;
              PL_laststatval = req->result;
              PL_statcache   = *(req->statdata);
            }

          ENTER;
          PUSHMARK (SP);

          if (req->type == REQ_READDIR)
            {
              SV *rv = &PL_sv_undef;

              if (req->result >= 0)
                {
                  char *buf = req->data2ptr;
                  AV *av = newAV ();

                  while (req->result)
                    {
                      SV *sv = newSVpv (buf, 0);

                      av_push (av, sv);
                      buf += SvCUR (sv) + 1;
                      req->result--;
                    }

                  rv = sv_2mortal (newRV_noinc ((SV *)av));
                }

              XPUSHs (rv);
            }
          else
            {
              XPUSHs (sv_2mortal (newSViv (req->result)));

              if (req->type == REQ_OPEN)
                {
                  /* convert fd to fh */
                  SV *fh;

                  PUTBACK;
                  call_pv ("IO::AIO::_fd2fh", G_SCALAR | G_EVAL);
                  SPAGAIN;

                  fh = SvREFCNT_inc (POPs);

                  PUSHMARK (SP);
                  XPUSHs (sv_2mortal (fh));
                }
            }

          if (SvOK (req->callback))
            {
              PUTBACK;
              call_sv (req->callback, G_VOID | G_EVAL);
              SPAGAIN;

              if (SvTRUE (ERRSV))
                {
                  free_req (req);
                  croak (0);
                }
            }

          LEAVE;

          errno = errorno;
          count++;
        }

      free_req (req);
    }

  return count;
}

static void *aio_proc(void *arg);

static void
start_thread (void)
{
  sigset_t fullsigset, oldsigset;
  pthread_t tid;
  pthread_attr_t attr;

  pthread_attr_init (&attr);
  pthread_attr_setstacksize (&attr, STACKSIZE);
  pthread_attr_setdetachstate (&attr, PTHREAD_CREATE_DETACHED);

  sigfillset (&fullsigset);
  sigprocmask (SIG_SETMASK, &fullsigset, &oldsigset);

  if (pthread_create (&tid, &attr, aio_proc, 0) == 0)
    started++;

  sigprocmask (SIG_SETMASK, &oldsigset, 0);
}

static void
send_req (aio_req req)
{
  while (started < wanted && nreqs >= started)
    start_thread ();

  nreqs++;

  pthread_mutex_lock (&reqlock);

  req->next = 0;

  if (reqe)
    {
      reqe->next = req;
      reqe = req;
    }
  else
    reqe = reqs = req;

  pthread_cond_signal (&reqwait);
  pthread_mutex_unlock (&reqlock);

  if (nreqs > max_outstanding)
    for (;;)
      {
        poll_cb ();

        if (nreqs <= max_outstanding)
          break;

        poll_wait ();
      }
}

static void
end_thread (void)
{
  aio_req req;
  Newz (0, req, 1, aio_cb);
  req->type = REQ_QUIT;

  send_req (req);
}

static void min_parallel (int nthreads)
{
  if (wanted < nthreads)
    wanted = nthreads;
}

static void max_parallel (int nthreads)
{
  int cur = started;

  if (wanted > nthreads)
    wanted = nthreads;

  while (cur > wanted)
    {
      end_thread ();
      cur--;
    }

  while (started > wanted)
    {
      poll_wait ();
      poll_cb ();
    }
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

static ssize_t
pread (int fd, void *buf, size_t count, off_t offset)
{
  ssize_t res;
  off_t ooffset;

  pthread_mutex_lock (&preadwritelock);
  ooffset = lseek (fd, 0, SEEK_CUR);
  lseek (fd, offset, SEEK_SET);
  res = read (fd, buf, count);
  lseek (fd, ooffset, SEEK_SET);
  pthread_mutex_unlock (&preadwritelock);

  return res;
}

static ssize_t
pwrite (int fd, void *buf, size_t count, off_t offset)
{
  ssize_t res;
  off_t ooffset;

  pthread_mutex_lock (&preadwritelock);
  ooffset = lseek (fd, 0, SEEK_CUR);
  lseek (fd, offset, SEEK_SET);
  res = write (fd, buf, count);
  lseek (fd, offset, SEEK_SET);
  pthread_mutex_unlock (&preadwritelock);

  return res;
}
#endif

#if !HAVE_FDATASYNC
# define fdatasync fsync
#endif

#if !HAVE_READAHEAD
# define readahead aio_readahead

static ssize_t
readahead (int fd, off_t offset, size_t count)
{
  char readahead_buf[4096];

  while (count > 0)
    {
      size_t len = count < sizeof (readahead_buf) ? count : sizeof (readahead_buf);

      pread (fd, readahead_buf, len, offset);
      offset += len;
      count  -= len;
    }

  errno = 0;
}
#endif

#if !HAVE_READDIR_R
# define readdir_r aio_readdir_r

static pthread_mutex_t readdirlock = PTHREAD_MUTEX_INITIALIZER;
  
static int
readdir_r (DIR *dirp, struct dirent *ent, struct dirent **res)
{
  struct dirent *e;
  int errorno;

  pthread_mutex_lock (&readdirlock);

  e = readdir (dirp);
  errorno = errno;

  if (e)
    {
      *res = ent;
      strcpy (ent->d_name, e->d_name);
    }
  else
    *res = 0;

  pthread_mutex_unlock (&readdirlock);

  errno = errorno;
  return e ? 0 : -1;
}
#endif

/* sendfile always needs emulation */
static ssize_t
sendfile_ (int ofd, int ifd, off_t offset, size_t count)
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
      /* maybe only on EAGAIN only: as usual, the manpage leaves you guessing */
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
      char buf[4096];
      res = 0;

      while (count)
        {
          ssize_t cnt;
          
          cnt = pread (ifd, buf, count > 4096 ? 4096 : count, offset);

          if (cnt <= 0)
            {
              if (cnt && !res) res = -1;
              break;
            }

          cnt = write (ofd, buf, cnt);

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
static int
scandir_ (const char *path, void **namesp)
{
  DIR *dirp = opendir (path);
  union
  {    
    struct dirent d;
    char b [offsetof (struct dirent, d_name) + NAME_MAX + 1];
  } u;
  struct dirent *entp;
  char *name, *names;
  int memlen = 4096;
  int memofs = 0;
  int res = 0;
  int errorno;

  if (!dirp)
    return -1;

  names = malloc (memlen);

  for (;;)
    {
      errno = 0, readdir_r (dirp, &u.d, &entp);

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
              names = realloc (names, memlen);
              if (!names)
                break;
            }

          memcpy (names + memofs, name, len);
          memofs += len;
        }
    }

  errorno = errno;
  closedir (dirp);

  if (errorno)
    {
      free (names);
      errno = errorno;
      res = -1;
    }

  *namesp = (void *)names;
  return res;
}

/*****************************************************************************/

static void *
aio_proc (void *thr_arg)
{
  aio_req req;
  int type;

  do
    {
      pthread_mutex_lock (&reqlock);

      for (;;)
        {
          req = reqs;

          if (reqs)
            {
              reqs = reqs->next;
              if (!reqs) reqe = 0;
            }

          if (req)
            break;

          pthread_cond_wait (&reqwait, &reqlock);
        }

      pthread_mutex_unlock (&reqlock);
     
      errno = 0; /* strictly unnecessary */

      type = req->type;

      switch (type)
        {
          case REQ_READ:      req->result = pread     (req->fd, req->dataptr, req->length, req->offset); break;
          case REQ_WRITE:     req->result = pwrite    (req->fd, req->dataptr, req->length, req->offset); break;

          case REQ_READAHEAD: req->result = readahead (req->fd, req->offset, req->length); break;
          case REQ_SENDFILE:  req->result = sendfile_ (req->fd, req->fd2, req->offset, req->length); break;

          case REQ_STAT:      req->result = stat      (req->dataptr, req->statdata); break;
          case REQ_LSTAT:     req->result = lstat     (req->dataptr, req->statdata); break;
          case REQ_FSTAT:     req->result = fstat     (req->fd     , req->statdata); break;

          case REQ_OPEN:      req->result = open      (req->dataptr, req->fd, req->mode); break;
          case REQ_CLOSE:     req->result = close     (req->fd); break;
          case REQ_UNLINK:    req->result = unlink    (req->dataptr); break;
          case REQ_RMDIR:     req->result = rmdir     (req->dataptr); break;
          case REQ_SYMLINK:   req->result = symlink   (req->data2ptr, req->dataptr); break;

          case REQ_FDATASYNC: req->result = fdatasync (req->fd); break;
          case REQ_FSYNC:     req->result = fsync     (req->fd); break;
          case REQ_READDIR:   req->result = scandir_  (req->dataptr, &req->data2ptr); break;

          case REQ_QUIT:
            break;

          default:
            req->result = ENOSYS;
            break;
        }

      req->errorno = errno;

      pthread_mutex_lock (&reslock);

      req->next = 0;

      if (rese)
        {
          rese->next = req;
          rese = req;
        }
      else
        {
          rese = ress = req;

          /* write a dummy byte to the pipe so fh becomes ready */
          write (respipe [1], &respipe, 1);
        }

      pthread_mutex_unlock (&reslock);
    }
  while (type != REQ_QUIT);

  return 0;
}

/*****************************************************************************/

static void atfork_prepare (void)
{
  pthread_mutex_lock (&reqlock);
  pthread_mutex_lock (&reslock);
#if !HAVE_PREADWRITE
  pthread_mutex_lock (&preadwritelock);
#endif
#if !HAVE_READDIR_R
  pthread_mutex_lock (&readdirlock);
#endif
}

static void atfork_parent (void)
{
#if !HAVE_READDIR_R
  pthread_mutex_unlock (&readdirlock);
#endif
#if !HAVE_PREADWRITE
  pthread_mutex_unlock (&preadwritelock);
#endif
  pthread_mutex_unlock (&reslock);
  pthread_mutex_unlock (&reqlock);
}

static void atfork_child (void)
{
  aio_req prv;

  started = 0;

  while (reqs)
    {
      prv = reqs;
      reqs = prv->next;
      free_req (prv);
    }

  reqs = reqe = 0;
      
  while (ress)
    {
      prv = ress;
      ress = prv->next;
      free_req (prv);
    }
      
  ress = rese = 0;

  close (respipe [0]);
  close (respipe [1]);
  create_pipe ();

  atfork_parent ();
}

#define dREQ							\
  aio_req req;							\
								\
  if (SvOK (callback) && !SvROK (callback))			\
    croak ("clalback must be undef or of reference type");	\
								\
  Newz (0, req, 1, aio_cb);					\
  if (!req)							\
    croak ("out of memory during aio_req allocation");		\
								\
  req->callback = newSVsv (callback);
	
MODULE = IO::AIO                PACKAGE = IO::AIO

PROTOTYPES: ENABLE

BOOT:
{
	create_pipe ();
        pthread_atfork (atfork_prepare, atfork_parent, atfork_child);
}

void
min_parallel(nthreads)
	int	nthreads
	PROTOTYPE: $

void
max_parallel(nthreads)
	int	nthreads
	PROTOTYPE: $

int
max_outstanding(nreqs)
	int nreqs
        PROTOTYPE: $
        CODE:
        RETVAL = max_outstanding;
        max_outstanding = nreqs;

void
aio_open(pathname,flags,mode,callback=&PL_sv_undef)
	SV *	pathname
        int	flags
        int	mode
        SV *	callback
	PROTOTYPE: $$$;$
	CODE:
{
        dREQ;

        req->type = REQ_OPEN;
        req->data = newSVsv (pathname);
        req->dataptr = SvPVbyte_nolen (req->data);
        req->fd = flags;
        req->mode = mode;

        send_req (req);
}

void
aio_close(fh,callback=&PL_sv_undef)
	SV *	fh
        SV *	callback
	PROTOTYPE: $;$
        ALIAS:
           aio_close     = REQ_CLOSE
           aio_fsync     = REQ_FSYNC
           aio_fdatasync = REQ_FDATASYNC
	CODE:
{
        dREQ;

        req->type = ix;
        req->fh = newSVsv (fh);
        req->fd = PerlIO_fileno (IoIFP (sv_2io (fh)));

        send_req (req);
}

void
aio_read(fh,offset,length,data,dataoffset,callback=&PL_sv_undef)
	SV *	fh
        UV	offset
        UV	length
        SV *	data
        UV	dataoffset
        SV *	callback
        ALIAS:
           aio_read  = REQ_READ
           aio_write = REQ_WRITE
	PROTOTYPE: $$$$$;$
        CODE:
{
        aio_req req;
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
            svptr = SvGROW (data, length + dataoffset);
          }

        if (length < 0)
          croak ("length must not be negative");

        {
          dREQ;

          req->type = ix;
          req->fh = newSVsv (fh);
          req->fd = PerlIO_fileno (ix == REQ_READ ? IoIFP (sv_2io (fh))
                                                  : IoOFP (sv_2io (fh)));
          req->offset = offset;
          req->length = length;
          req->data = SvREFCNT_inc (data);
          req->dataptr = (char *)svptr + dataoffset;

          if (!SvREADONLY (data))
            {
              SvREADONLY_on (data);
              req->data2ptr = (void *)data;
            }

          send_req (req);
        }
}

void
aio_sendfile(out_fh,in_fh,in_offset,length,callback=&PL_sv_undef)
        SV *	out_fh
        SV *	in_fh
        UV	in_offset
        UV	length
        SV *	callback
	PROTOTYPE: $$$$;$
        CODE:
{
	dREQ;

        req->type = REQ_SENDFILE;
        req->fh = newSVsv (out_fh);
        req->fd = PerlIO_fileno (IoIFP (sv_2io (out_fh)));
        req->fh2 = newSVsv (in_fh);
        req->fd2 = PerlIO_fileno (IoIFP (sv_2io (in_fh)));
        req->offset = in_offset;
        req->length = length;

        send_req (req);
}

void
aio_readahead(fh,offset,length,callback=&PL_sv_undef)
        SV *	fh
        UV	offset
        IV	length
        SV *	callback
	PROTOTYPE: $$$;$
        CODE:
{
	dREQ;

        req->type = REQ_READAHEAD;
        req->fh = newSVsv (fh);
        req->fd = PerlIO_fileno (IoIFP (sv_2io (fh)));
        req->offset = offset;
        req->length = length;

        send_req (req);
}

void
aio_stat(fh_or_path,callback=&PL_sv_undef)
        SV *		fh_or_path
        SV *		callback
        ALIAS:
           aio_stat  = REQ_STAT
           aio_lstat = REQ_LSTAT
	CODE:
{
	dREQ;

        New (0, req->statdata, 1, Stat_t);
        if (!req->statdata)
          {
            free_req (req);
            croak ("out of memory during aio_req->statdata allocation");
          }

        if (SvPOK (fh_or_path))
          {
            req->type = ix;
            req->data = newSVsv (fh_or_path);
            req->dataptr = SvPVbyte_nolen (req->data);
          }
        else
          {
            req->type = REQ_FSTAT;
            req->fh = newSVsv (fh_or_path);
            req->fd = PerlIO_fileno (IoIFP (sv_2io (fh_or_path)));
          }

        send_req (req);
}

void
aio_unlink(pathname,callback=&PL_sv_undef)
	SV * pathname
	SV * callback
        ALIAS:
           aio_unlink = REQ_UNLINK
           aio_rmdir  = REQ_RMDIR
	CODE:
{
	dREQ;
	
        req->type = ix;
	req->data = newSVsv (pathname);
	req->dataptr = SvPVbyte_nolen (req->data);
	
	send_req (req);
}

void
aio_symlink(oldpath,newpath,callback=&PL_sv_undef)
	SV * oldpath
	SV * newpath
	SV * callback
	CODE:
{
	dREQ;
	
        req->type = REQ_SYMLINK;
	req->fh = newSVsv (oldpath);
	req->data2ptr = SvPVbyte_nolen (req->fh);
	req->data = newSVsv (newpath);
	req->dataptr = SvPVbyte_nolen (req->data);
	
	send_req (req);
}

void
aio_readdir(pathname,callback=&PL_sv_undef)
	SV * pathname
	SV * callback
	CODE:
{
	dREQ;
	
        req->type = REQ_READDIR;
	req->data = newSVsv (pathname);
	req->dataptr = SvPVbyte_nolen (req->data);
	
	send_req (req);
}

void
flush()
	PROTOTYPE:
	CODE:
        while (nreqs)
          {
            poll_wait ();
            poll_cb ();
          }

void
poll()
	PROTOTYPE:
	CODE:
        if (nreqs)
          {
            poll_wait ();
            poll_cb ();
          }

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
        if (nreqs)
          poll_wait ();

int
nreqs()
	PROTOTYPE:
	CODE:
        RETVAL = nreqs;
	OUTPUT:
	RETVAL

