#include <poll.h>
#include <errno.h>

// Non-blocking readiness probe for a stdin descriptor.  This is the fix for
// Adou's startup hang under `/bin/sh` command substitution: the previous
// read loop blocked until EOF on an open-but-empty FIFO (e.g. the shell
// launcher's own stdin pipe), so `out=$(adou ...)` never returned.
//
// Returns:
//   1 - readable (POLLIN), or the peer closed/errored (POLLHUP/POLLERR):
//       a follow-up read() returns data or 0 for EOF.
//   0 - no data right now and the peer is still open: do not block on read.
//   -1 - poll failed (fd invalid etc).
int adou_stdin_peek(int fd) {
    struct pollfd pfd;
    pfd.fd = fd;
    pfd.events = POLLIN;
    pfd.revents = 0;
    int r = poll(&pfd, 1, 0);
    if (r < 0) {
        return -1;
    }
    if (r == 0) {
        return 0;
    }
    if (pfd.revents & POLLNVAL) {
        return -1;
    }
    return 1;
}
