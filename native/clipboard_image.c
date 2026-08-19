#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <sys/stat.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <dlfcn.h>
#include <string.h>

typedef void *adou_obj_t;
typedef void *adou_class_t;
typedef void *adou_sel_t;
typedef adou_class_t (*adou_get_class_fn)(const char *);
typedef adou_sel_t (*adou_sel_register_fn)(const char *);
typedef adou_obj_t (*adou_msg0_fn)(adou_obj_t, adou_sel_t);
typedef adou_obj_t (*adou_msg1_fn)(adou_obj_t, adou_sel_t, adou_obj_t);
typedef unsigned long (*adou_length_fn)(adou_obj_t, adou_sel_t);
typedef const unsigned char *(*adou_bytes_fn)(adou_obj_t, adou_sel_t);

static int write_all(const char *path, const unsigned char *data, unsigned long length) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return -errno;
    unsigned long offset = 0;
    while (offset < length) {
        ssize_t count = write(fd, data + offset, (size_t)(length - offset));
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            int saved = count == 0 ? EIO : errno;
            close(fd);
            return -saved;
        }
        offset += (unsigned long)count;
    }
    if (fchmod(fd, 0600) != 0) {
        int saved = errno;
        close(fd);
        return -saved;
    }
    if (close(fd) != 0) return -errno;
    return 1;
}

// Returns 1 for PNG, 2 for TIFF, 0 when the clipboard has no image, and a
// negative errno-style value on a dynamic-runtime or filesystem failure.
int adou_clipboard_image_write(const char *path) {
    void *objc = dlopen("/usr/lib/libobjc.A.dylib", RTLD_LAZY);
    void *appkit = dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", RTLD_LAZY);
    if (objc == NULL || appkit == NULL) {
        if (appkit) dlclose(appkit);
        if (objc) dlclose(objc);
        return -ENOSYS;
    }
    adou_get_class_fn get_class = (adou_get_class_fn)dlsym(objc, "objc_getClass");
    adou_sel_register_fn register_sel = (adou_sel_register_fn)dlsym(objc, "sel_registerName");
    adou_msg0_fn msg0 = (adou_msg0_fn)dlsym(objc, "objc_msgSend");
    adou_msg1_fn msg1 = (adou_msg1_fn)dlsym(objc, "objc_msgSend");
    if (!get_class || !register_sel || !msg0 || !msg1) {
        dlclose(appkit);
        dlclose(objc);
        return -ENOSYS;
    }

    adou_class_t pasteboard_class = get_class("NSPasteboard");
    adou_class_t string_class = get_class("NSString");
    if (!pasteboard_class || !string_class) {
        dlclose(appkit);
        dlclose(objc);
        return -ENOSYS;
    }
    adou_obj_t pasteboard = msg0(pasteboard_class, register_sel("generalPasteboard"));
    adou_sel_t string_with_utf8 = register_sel("stringWithUTF8String:");
    adou_sel_t data_for_type = register_sel("dataForType:");
    adou_obj_t png_type = msg1(string_class, string_with_utf8, (adou_obj_t)"public.png");
    adou_obj_t data = msg1(pasteboard, data_for_type, png_type);
    int kind = 1;
    if (!data) {
        adou_obj_t tiff_type = msg1(string_class, string_with_utf8, (adou_obj_t)"public.tiff");
        data = msg1(pasteboard, data_for_type, tiff_type);
        kind = 2;
    }
    if (!data) {
        dlclose(appkit);
        dlclose(objc);
        return 0;
    }

    adou_length_fn length = (adou_length_fn)msg0;
    adou_bytes_fn bytes = (adou_bytes_fn)msg0;
    unsigned long size = length(data, register_sel("length"));
    const unsigned char *content = bytes(data, register_sel("bytes"));
    int result = (!content || size == 0) ? -EIO : write_all(path, content, size);
    if (result > 0) result = kind;
    dlclose(appkit);
    dlclose(objc);
    return result;
}

#else

int adou_clipboard_image_write(const char *path) {
    (void)path;
    return 0;
}

#endif
