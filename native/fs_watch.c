#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <sys/event.h>
#include <sys/time.h>
#elif defined(__linux__)
#include <sys/inotify.h>
#include <poll.h>
#endif

int64_t adou_fs_watch_wait(const char *path, int64_t timeout_ms) {
    if (path == NULL || timeout_ms < 0) return -EINVAL;
#if defined(__APPLE__)
    int fd = open(path, O_EVTONLY);
    if (fd < 0) return -errno;
    int queue = kqueue();
    if (queue < 0) { int error = errno; close(fd); return -error; }
    struct kevent change;
    EV_SET(&change, (uintptr_t)fd, EVFILT_VNODE,
           EV_ADD | EV_ENABLE | EV_CLEAR,
           NOTE_WRITE | NOTE_DELETE | NOTE_RENAME | NOTE_ATTRIB, 0, NULL);
    if (kevent(queue, &change, 1, NULL, 0, NULL) < 0) {
        int error = errno; close(queue); close(fd); return -error;
    }
    struct timespec timeout;
    timeout.tv_sec = (time_t)(timeout_ms / 1000);
    timeout.tv_nsec = (long)((timeout_ms % 1000) * 1000000);
    struct kevent event;
    int result = kevent(queue, NULL, 0, &event, 1, &timeout);
    int error = errno;
    close(queue); close(fd);
    if (result > 0) return 1;
    if (result == 0) return 0;
    return -error;
#elif defined(__linux__)
    int fd = inotify_init1(IN_CLOEXEC);
    if (fd < 0) return -errno;
    int watch = inotify_add_watch(fd, path, IN_MODIFY | IN_ATTRIB | IN_CLOSE_WRITE | IN_DELETE_SELF | IN_MOVE_SELF);
    if (watch < 0) { int error = errno; close(fd); return -error; }
    struct pollfd descriptor = {fd, POLLIN, 0};
    int result = poll(&descriptor, 1, (int)timeout_ms);
    int error = errno;
    char buffer[sizeof(struct inotify_event) + 256];
    if (result > 0) (void)read(fd, buffer, sizeof(buffer));
    inotify_rm_watch(fd, watch);
    close(fd);
    if (result > 0) return 1;
    if (result == 0) return 0;
    return -error;
#else
    (void)path;
    (void)timeout_ms;
    return -ENOSYS;
#endif
}
