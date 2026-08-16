#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <termios.h>
#include <pthread.h>
#include <unistd.h>

typedef struct {
    bool active;
    int fd;
    struct termios saved_termios;
} terminal_state_t;

int64_t adou_term_restore_raw(int64_t fd);

static terminal_state_t terminal_state = {
    .active = false,
    .fd = -1,
};

static pthread_mutex_t terminal_write_mutex = PTHREAD_MUTEX_INITIALIZER;

// Write as much as the fd accepts right now: temporarily add O_NONBLOCK for
// the call, perform ONE write attempt (retrying EINTR in C), restore the
// original flags before returning (a leaked O_NONBLOCK would be inherited by
// editor children across exec), and report a restore failure as an error.
// Returns the bytes written (>0), 0 when the output buffer is momentarily
// full (EAGAIN/EWOULDBLOCK — the caller sleeps and yields instead of
// blocking the whole processor), or -errno for permanent failures.  The
// shared libuv fs_context is never touched: two coroutines writing to the
// same stdout cannot clobber each other's in-flight request.
int64_t adou_term_write(int64_t fd, const char *buf, int64_t length) {
    if (length < 0 || (length > 0 && buf == NULL)) {
        return -EINVAL;
    }
    int lock_result = pthread_mutex_lock(&terminal_write_mutex);
    if (lock_result != 0) {
        return -lock_result;
    }

    int64_t result = 0;
    int unlock_result = 0;
    int native_fd = (int) fd;
    int flags = fcntl(native_fd, F_GETFL, 0);
    if (flags < 0) {
        result = -errno;
        goto done;
    }
    bool was_nonblocking = (flags & O_NONBLOCK) != 0;
    if (!was_nonblocking) {
        if (fcntl(native_fd, F_SETFL, flags | O_NONBLOCK) != 0) {
            result = -errno;
            goto done;
        }
    }
    ssize_t count;
    int retries = 0;
    for (;;) {
        count = write(native_fd, buf, (size_t) length);
        if (count >= 0) {
            break;
        }
        if (errno == EINTR && retries < 16) {
            retries += 1;
            continue;
        }
        break;
    }
    if (count >= 0) {
        result = (int) count;
    } else if (errno == EAGAIN || errno == EWOULDBLOCK) {
        result = 0;
    } else {
        result = -errno;
    }
    if (!was_nonblocking) {
        if (fcntl(native_fd, F_SETFL, flags) != 0) {
            result = -errno;
        }
    }

done:
    unlock_result = pthread_mutex_unlock(&terminal_write_mutex);
    if (unlock_result != 0 && result == 0) {
        result = -unlock_result;
    }
    return result;
}

// Read one chunk without blocking the Nature processor.  The fixed -1/-2
// sentinels keep EINTR and EAGAIN distinguishable from errno text and from
// platform-specific errno values; other failures are encoded below -1000000.
int64_t adou_term_read(int64_t fd, char *buf, int64_t length) {
    if (length < 0 || (length > 0 && buf == NULL)) {
        return -1000000 - EINVAL;
    }
    int native_fd = (int) fd;
    int flags = fcntl(native_fd, F_GETFL, 0);
    if (flags < 0) {
        return -1000000 - errno;
    }
    bool was_nonblocking = (flags & O_NONBLOCK) != 0;
    if (!was_nonblocking && fcntl(native_fd, F_SETFL, flags | O_NONBLOCK) != 0) {
        return -1000000 - errno;
    }

    ssize_t count = read(native_fd, buf, (size_t) length);
    int64_t result;
    if (count >= 0) {
        result = count;
    } else if (errno == EINTR) {
        result = -2;
    } else if (errno == EAGAIN || errno == EWOULDBLOCK) {
        result = -1;
    } else {
        result = -1000000 - errno;
    }

    if (!was_nonblocking && fcntl(native_fd, F_SETFL, flags) != 0) {
        return -1000000 - errno;
    }
    return result;
}

static void make_raw(struct termios *settings) {
    settings->c_iflag &= (tcflag_t) ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
    settings->c_oflag &= (tcflag_t) ~OPOST;
    settings->c_cflag |= CS8;
    settings->c_lflag &= (tcflag_t) ~(ECHO | ICANON | IEXTEN | ISIG);
    settings->c_cc[VMIN] = 1;
    settings->c_cc[VTIME] = 0;
}

int64_t adou_term_is_tty(int64_t fd) {
    return isatty((int) fd) == 1;
}

int64_t adou_term_enter_raw(int64_t fd) {
    int native_fd = (int) fd;
    if (terminal_state.active) {
        if (terminal_state.fd == native_fd) return 0;
        adou_term_restore_raw(terminal_state.fd);
    }

    if (tcgetattr(native_fd, &terminal_state.saved_termios) != 0) {
        return -errno;
    }

    struct termios raw = terminal_state.saved_termios;
    make_raw(&raw);
    // TCSAFLUSH can wait for pending output to drain, which blocks forever
    // when a slow pane or PTY master stops reading. Discard input explicitly
    // instead, so queued TUI bytes cannot be replayed at either boundary.
    if (tcflush(native_fd, TCIFLUSH) != 0) {
        return -errno;
    }
    if (tcsetattr(native_fd, TCSANOW, &raw) != 0) {
        return -errno;
    }
    if (tcflush(native_fd, TCIFLUSH) != 0) {
        return -errno;
    }

    terminal_state.active = true;
    terminal_state.fd = native_fd;
    return 0;
}

int64_t adou_term_restore_raw(int64_t fd) {
    int native_fd = (int) fd;
    if (!terminal_state.active || terminal_state.fd != native_fd) return 0;

    int result = 0;
    // Flush input without waiting for output so bytes intended for the TUI
    // cannot be consumed by the shell after raw mode is restored.
    if (tcflush(native_fd, TCIFLUSH) != 0) {
        result = -errno;
    }
    if (tcsetattr(native_fd, TCSANOW, &terminal_state.saved_termios) != 0) {
        if (result == 0) {
            result = -errno;
        }
    }
    if (tcflush(native_fd, TCIFLUSH) != 0 && result == 0) {
        result = -errno;
    }

    terminal_state.active = false;
    terminal_state.fd = -1;
    return result;
}

int64_t adou_term_size(int64_t fd, int64_t *rows, int64_t *columns) {
    struct winsize size = {0};
    if (ioctl((int) fd, TIOCGWINSZ, &size) != 0) {
        return -errno;
    }

    if (rows != NULL) *rows = size.ws_row > 0 ? size.ws_row : 24;
    if (columns != NULL) *columns = size.ws_col > 0 ? size.ws_col : 80;
    return 0;
}
