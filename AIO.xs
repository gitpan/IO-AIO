#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <sched.h>

#include <pthread.h>
#include <sys/syscall.h>

typedef void *InputStream;  /* hack, but 5.6.1 is simply toooo old ;) */
typedef void *OutputStream; /* hack, but 5.6.1 is simply toooo old ;) */
typedef void *InOutStream;  /* hack, but 5.6.1 is simply toooo old ;) */

#if __ia64
# define STACKSIZE 65536
#else
# define STACKSIZE  4096
#endif

enum {
  REQ_QUIT,
  REQ_OPEN, REQ_CLOSE,
  REQ_READ, REQ_WRITE, REQ_READAHEAD,
  REQ_STAT, REQ_LSTAT, REQ_FSTAT, REQ_UNLINK,
  REQ_FSYNC, REQ_FDATASYNC,
};

typedef struct aio_cb {
  struct aio_cb *volatile next;

  int type;

  int fd;
  off_t offset;
  size_t length;
  ssize_t result;
  mode_t mode; /* open */
  int errorno;
  SV *data, *callback;
  void *dataptr;
  STRLEN dataoffset;

  Stat_t *statdata;
} aio_cb;

typedef aio_cb *aio_req;

static int started;
static int nreqs;
static int max_outstanding = 1<<30;
static int respipe [2];

static pthread_mutex_t reslock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t reqlock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  reqwait = PTHREAD_COND_INITIALIZER;

static volatile aio_req reqs, reqe; /* queue start, queue end */
static volatile aio_req ress, rese; /* queue start, queue end */

static void
poll_wait ()
{
  if (!nreqs)
    return;

  fd_set rfd;
  FD_ZERO(&rfd);
  FD_SET(respipe [0], &rfd);

  select (respipe [0] + 1, &rfd, 0, 0, 0);
}

static int
poll_cb ()
{
  dSP;
  int count = 0;
  aio_req req;
  
  {
    /* read and signals sent by the worker threads */
    char buf [32];
    while (read (respipe [0], buf, 32) > 0)
      ;
  }

  for (;;)
    {
      pthread_mutex_lock (&reslock);

      req = ress;

      if (ress)
        {
          ress = ress->next;
          if (!ress) rese = 0;
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
            SvCUR_set (req->data, req->dataoffset
                                  + req->result > 0 ? req->result : 0);

          if (req->data)
            SvREFCNT_dec (req->data);

          if (req->type == REQ_STAT || req->type == REQ_LSTAT || req->type == REQ_FSTAT)
            {
              PL_laststype   = req->type == REQ_LSTAT ? OP_LSTAT : OP_STAT;
              PL_laststatval = req->result;
              PL_statcache   = *(req->statdata);

              Safefree (req->statdata);
            }

          PUSHMARK (SP);
          XPUSHs (sv_2mortal (newSViv (req->result)));

          if (req->type == REQ_OPEN)
            {
              /* convert fd to fh */
              SV *fh;

              PUTBACK;
              call_pv ("IO::AIO::_fd2fh", G_SCALAR | G_EVAL);
              SPAGAIN;

              fh = POPs;

              PUSHMARK (SP);
              XPUSHs (fh);
            }

          if (SvOK (req->callback))
            {
              PUTBACK;
              call_sv (req->callback, G_VOID | G_EVAL);
              SPAGAIN;
            }
          
          if (req->callback)
            SvREFCNT_dec (req->callback);

          errno = errorno;
          count++;
        }

      Safefree (req);
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

  while (nreqs > max_outstanding)
    {
      poll_wait ();
      poll_cb ();
    }
}

static void
end_thread (void)
{
  aio_req req;
  New (0, req, 1, aio_cb);
  req->type = REQ_QUIT;

  send_req (req);
}

static void
read_write (int dowrite, int fd, off_t offset, size_t length,
            SV *data, STRLEN dataoffset, SV *callback)
{
  aio_req req;
  STRLEN svlen;
  char *svptr = SvPV (data, svlen);

  SvUPGRADE (data, SVt_PV);
  SvPOK_on (data);

  if (dataoffset < 0)
    dataoffset += svlen;

  if (dataoffset < 0 || dataoffset > svlen)
    croak ("data offset outside of string");

  if (dowrite)
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

  Newz (0, req, 1, aio_cb);

  if (!req)
    croak ("out of memory during aio_req allocation");

  req->type = dowrite ? REQ_WRITE : REQ_READ;
  req->fd = fd;
  req->offset = offset;
  req->length = length;
  req->data = SvREFCNT_inc (data);
  req->dataptr = (char *)svptr + dataoffset;
  req->callback = SvREFCNT_inc (callback);

  send_req (req);
}

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
          case REQ_READ:      req->result = pread64   (req->fd, req->dataptr, req->length, req->offset); break;
          case REQ_WRITE:     req->result = pwrite64  (req->fd, req->dataptr, req->length, req->offset); break;
#if SYS_readahead
          case REQ_READAHEAD: req->result = readahead (req->fd, req->offset, req->length); break;
#else
          case REQ_READAHEAD: req->result = -1; errno = ENOSYS; break;
#endif

          case REQ_STAT:      req->result = stat      (req->dataptr, req->statdata); break;
          case REQ_LSTAT:     req->result = lstat     (req->dataptr, req->statdata); break;
          case REQ_FSTAT:     req->result = fstat     (req->fd     , req->statdata); break;

          case REQ_OPEN:      req->result = open      (req->dataptr, req->fd, req->mode); break;
          case REQ_CLOSE:     req->result = close     (req->fd); break;
          case REQ_UNLINK:    req->result = unlink    (req->dataptr); break;

          case REQ_FSYNC:     req->result = fsync     (req->fd); break;
          case REQ_FDATASYNC: req->result = fdatasync (req->fd); break;

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

MODULE = IO::AIO                PACKAGE = IO::AIO

PROTOTYPES: ENABLE

BOOT:
{
        if (pipe (respipe))
          croak ("unable to initialize result pipe");

        if (fcntl (respipe [0], F_SETFL, O_NONBLOCK))
          croak ("cannot set result pipe to nonblocking mode");

        if (fcntl (respipe [1], F_SETFL, O_NONBLOCK))
          croak ("cannot set result pipe to nonblocking mode");
}

void
min_parallel(nthreads)
	int	nthreads
	PROTOTYPE: $
        CODE:
        while (nthreads > started)
          start_thread ();

void
max_parallel(nthreads)
	int	nthreads
	PROTOTYPE: $
        CODE:
{
        int cur = started;
        while (cur > nthreads)
          {          
            end_thread ();
            cur--;
          }

        while (started > nthreads)
          {
            poll_wait ();
            poll_cb ();
          }
}

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
        aio_req req;

        Newz (0, req, 1, aio_cb);

        if (!req)
          croak ("out of memory during aio_req allocation");

        req->type = REQ_OPEN;
        req->data = newSVsv (pathname);
        req->dataptr = SvPV_nolen (req->data);
        req->fd = flags;
        req->mode = mode;
        req->callback = SvREFCNT_inc (callback);

        send_req (req);
}

void
aio_close(fh,callback=&PL_sv_undef)
        InputStream	fh
        SV *		callback
	PROTOTYPE: $;$
        ALIAS:
           aio_close     = REQ_CLOSE
           aio_fsync     = REQ_FSYNC
           aio_fdatasync = REQ_FDATASYNC
	CODE:
{
        aio_req req;

        Newz (0, req, 1, aio_cb);

        if (!req)
          croak ("out of memory during aio_req allocation");

        req->type = ix;
        req->fd = PerlIO_fileno (fh);
        req->callback = SvREFCNT_inc (callback);

        send_req (req);
}

void
aio_read(fh,offset,length,data,dataoffset,callback=&PL_sv_undef)
        InputStream	fh
        UV		offset
        IV		length
        SV *		data
        IV		dataoffset
        SV *		callback
	PROTOTYPE: $$$$$;$
        CODE:
        read_write (0, PerlIO_fileno (fh), offset, length, data, dataoffset, callback);

void
aio_write(fh,offset,length,data,dataoffset,callback=&PL_sv_undef)
        OutputStream	fh
        UV		offset
        IV		length
        SV *		data
        IV		dataoffset
        SV *		callback
	PROTOTYPE: $$$$$;$
        CODE:
        read_write (1, PerlIO_fileno (fh), offset, length, data, dataoffset, callback);

void
aio_readahead(fh,offset,length,callback=&PL_sv_undef)
        InputStream	fh
        UV		offset
        IV		length
        SV *		callback
	PROTOTYPE: $$$;$
        CODE:
{
        aio_req req;

        if (length < 0)
          croak ("length must not be negative");

        Newz (0, req, 1, aio_cb);

        if (!req)
          croak ("out of memory during aio_req allocation");

        req->type = REQ_READAHEAD;
        req->fd = PerlIO_fileno (fh);
        req->offset = offset;
        req->length = length;
        req->callback = SvREFCNT_inc (callback);

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
        aio_req req;

        Newz (0, req, 1, aio_cb);

        if (!req)
          croak ("out of memory during aio_req allocation");

        New (0, req->statdata, 1, Stat_t);

        if (!req->statdata)
          croak ("out of memory during aio_req->statdata allocation");

        if (SvPOK (fh_or_path))
          {
            req->type = ix;
            req->data = newSVsv (fh_or_path);
            req->dataptr = SvPV_nolen (req->data);
          }
        else
          {
            req->type = REQ_FSTAT;
            req->fd = PerlIO_fileno (IoIFP (sv_2io (fh_or_path)));
          }

        req->callback = SvREFCNT_inc (callback);

        send_req (req);
}

void
aio_unlink(pathname,callback=&PL_sv_undef)
	SV * pathname
	SV * callback
	CODE:
{
	aio_req req;
	
	Newz (0, req, 1, aio_cb);
	
	if (!req)
	  croak ("out of memory during aio_req allocation");
	
	req->type = REQ_UNLINK;
	req->data = newSVsv (pathname);
	req->dataptr = SvPV_nolen (req->data);
	req->callback = SvREFCNT_inc (callback);
	
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

