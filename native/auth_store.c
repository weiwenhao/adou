#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

// Nature's fs module owns opening, writing and closing files. These narrow
// helpers expose only the durability/locking primitives absent from fs.
int adou_auth_try_lock(int fd) {
    struct flock lock;
    memset(&lock, 0, sizeof(lock));
    lock.l_type = F_WRLCK;
    lock.l_whence = SEEK_SET;
    if (fcntl(fd, F_SETLK, &lock) == 0) return 1;
    if (errno == EACCES || errno == EAGAIN) return 0;
    return -errno;
}

int adou_auth_unlock(int fd) {
    struct flock lock;
    memset(&lock, 0, sizeof(lock));
    lock.l_type = F_UNLCK;
    lock.l_whence = SEEK_SET;
    return fcntl(fd, F_SETLK, &lock) == 0 ? 0 : -errno;
}

int adou_auth_fsync(int fd) {
    return fsync(fd) == 0 ? 0 : -errno;
}
