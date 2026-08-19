#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

int adou_auth_lock(const char *path) {
    int fd = open(path, O_CREAT | O_RDWR, 0600);
    if (fd < 0) return -errno;
    if (fchmod(fd, 0600) != 0) {
        int saved = errno;
        close(fd);
        return -saved;
    }

    struct flock lock;
    memset(&lock, 0, sizeof(lock));
    lock.l_type = F_WRLCK;
    lock.l_whence = SEEK_SET;
    while (fcntl(fd, F_SETLKW, &lock) != 0) {
        if (errno == EINTR) continue;
        int saved = errno;
        close(fd);
        return -saved;
    }
    return fd;
}

int adou_auth_unlock(int fd) {
    struct flock lock;
    memset(&lock, 0, sizeof(lock));
    lock.l_type = F_UNLCK;
    lock.l_whence = SEEK_SET;
    int result = fcntl(fd, F_SETLK, &lock);
    int saved = result == 0 ? 0 : errno;
    if (close(fd) != 0 && saved == 0) saved = errno;
    return saved == 0 ? 0 : -saved;
}

static int fsync_parent(const char *path) {
    char *copy = strdup(path);
    if (copy == NULL) return ENOMEM;
    char *slash = strrchr(copy, '/');
    if (slash == NULL) {
        free(copy);
        return 0;
    }
    if (slash == copy) slash[1] = '\0';
    else *slash = '\0';

    int fd = open(copy, O_RDONLY);
    int result = 0;
    if (fd < 0) result = errno;
    else {
        if (fsync(fd) != 0) result = errno;
        close(fd);
    }
    free(copy);
    return result;
}

int adou_auth_atomic_write(const char *path, const void *data, int length) {
    if (length < 0) return -EINVAL;
    size_t capacity = strlen(path) + 64;
    char *temporary = malloc(capacity);
    if (temporary == NULL) return -ENOMEM;

    int fd = -1;
    for (unsigned attempt = 0; attempt < 100; ++attempt) {
        snprintf(temporary, capacity, "%s.tmp.%ld.%u", path, (long)getpid(), attempt);
        fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (fd >= 0 || errno != EEXIST) break;
    }
    if (fd < 0) {
        int saved = errno;
        free(temporary);
        return -saved;
    }

    int result = 0;
    const unsigned char *cursor = data;
    int remaining = length;
    while (remaining > 0) {
        ssize_t written = write(fd, cursor, (size_t)remaining);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) {
            result = written == 0 ? EIO : errno;
            break;
        }
        cursor += written;
        remaining -= (int)written;
    }
    if (result == 0 && fsync(fd) != 0) result = errno;
    if (close(fd) != 0 && result == 0) result = errno;
    if (result == 0 && rename(temporary, path) != 0) result = errno;
    if (result == 0) result = fsync_parent(path);
    if (result != 0) unlink(temporary);
    free(temporary);
    return result == 0 ? 0 : -result;
}
