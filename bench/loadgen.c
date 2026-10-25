/* Minimal pipelining HTTP/1.1 load generator: 1 thread, epoll, non-blocking.
 * Sends up to P requests per connection without waiting, counts complete
 * responses (parsed by Content-Length), prints req/s and client CPU. */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define MAXC 4096
#define BUFSZ (1 << 20)

typedef struct {
  int fd;
  int inflight;      /* requests sent, awaiting response */
  size_t woff;       /* bytes of the batch already written */
  size_t rlen;       /* bytes in rbuf */
  char *rbuf;
} conn_t;

static char reqbuf[64 * 4096];
static size_t reqlen;

static double now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* consume as many complete responses as possible; returns count */
static long parse(conn_t *c) {
  long done = 0;
  size_t off = 0;
  while (1) {
    char *hdr_end = memmem(c->rbuf + off, c->rlen - off, "\r\n\r\n", 4);
    if (!hdr_end) break;
    size_t hlen = hdr_end - (c->rbuf + off) + 4;
    long clen = 0;
    char *cl = memmem(c->rbuf + off, hlen, "Content-Length:", 15);
    if (cl) clen = strtol(cl + 15, NULL, 10);
    if (c->rlen - off < hlen + (size_t)clen) break;
    off += hlen + clen;
    done++;
  }
  if (off) {
    memmove(c->rbuf, c->rbuf + off, c->rlen - off);
    c->rlen -= off;
  }
  c->inflight -= (int)done;
  return done;
}

int main(int argc, char **argv) {
  int port = argc > 1 ? atoi(argv[1]) : 30000;
  int nconn = argc > 2 ? atoi(argv[2]) : 64;
  int secs = argc > 3 ? atoi(argv[3]) : 5;
  int pipe = argc > 4 ? atoi(argv[4]) : 16;
  const char *path = argc > 5 ? argv[5] : "/text";

  snprintf(reqbuf, sizeof reqbuf,
           "GET %s HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n", path);
  reqlen = strlen(reqbuf);
  if (pipe > 2048) pipe = 2048;
  char *p = malloc((size_t)reqlen * pipe);
  for (int i = 0; i < pipe; i++) memcpy(p + (size_t)i * reqlen, reqbuf, reqlen);
  memcpy(reqbuf, p, (size_t)reqlen * pipe);
  reqlen *= (size_t)pipe;
  free(p);

  int ep = epoll_create1(0);
  conn_t *cs = calloc(nconn, sizeof(conn_t));
  struct sockaddr_in sa = {.sin_family = AF_INET, .sin_port = htons(port)};
  sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  for (int i = 0; i < nconn; i++) {
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    connect(fd, (struct sockaddr *)&sa, sizeof sa); /* EINPROGRESS ok */
    cs[i].fd = fd;
    cs[i].rbuf = malloc(BUFSZ);
    struct epoll_event ev = {.events = EPOLLIN | EPOLLOUT, .data.u32 = (unsigned)i};
    epoll_ctl(ep, EPOLL_CTL_ADD, fd, &ev);
  }

  long total = 0;
  double t0 = now(), tlast = t0;
  long last = 0;
  struct epoll_event evs[1024];
  while (1) {
    double t = now();
    if (t - t0 >= secs) break;
    int n = epoll_wait(ep, evs, 1024, 20);
    for (int k = 0; k < n; k++) {
      conn_t *c = &cs[evs[k].data.u32];
      if (evs[k].events & EPOLLOUT) {
        while (c->inflight < pipe) {
          ssize_t w = send(c->fd, reqbuf + c->woff, reqlen - c->woff, MSG_NOSIGNAL);
          if (w < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            if (errno == EPIPE) { c->inflight = pipe; break; }
            break;
          }
          c->woff += (size_t)w;
          if (c->woff == reqlen) { c->woff = 0; c->inflight += pipe; }
        }
      }
      if (evs[k].events & (EPOLLIN | EPOLLHUP | EPOLLERR)) {
        while (1) {
          ssize_t r = recv(c->fd, c->rbuf + c->rlen, BUFSZ - c->rlen, 0);
          if (r <= 0) break;
          c->rlen += (size_t)r;
          total += parse(c);
        }
      }
    }
    (void)last; (void)tlast;
  }
  double el = now() - t0;
  struct rusage ru;
  getrusage(RUSAGE_SELF, &ru);
  double cpu = ru.ru_utime.tv_sec + ru.ru_utime.tv_usec / 1e6 + ru.ru_stime.tv_sec +
               ru.ru_stime.tv_usec / 1e6;
  printf("rps=%.0f  responses=%ld  client_cpu=%.0f%% of a core  pipe=%d conns=%d\n",
         total / el, total, 100 * cpu / el, pipe, nconn);
  return 0;
}
