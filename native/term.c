#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
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
    if (tcsetattr(native_fd, TCSAFLUSH, &raw) != 0) {
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
    if (tcsetattr(native_fd, TCSAFLUSH, &terminal_state.saved_termios) != 0) {
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
