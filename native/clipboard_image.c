#include <errno.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>

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

// Copies PNG/TIFF clipboard bytes into caller-owned Nature memory. Passing a
// null/zero buffer only queries the required size. File creation and writes
// stay in Nature's fs module so this native bridge never blocks a processor
// on file I/O.
int64_t adou_clipboard_image_read(void *buffer, int64_t capacity, int64_t *kind_out) {
    if (capacity < 0 || kind_out == NULL) return -EINVAL;
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
    int64_t kind = 1;
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
    if (!content || size == 0) {
        dlclose(appkit);
        dlclose(objc);
        return -EIO;
    }
    *kind_out = kind;
    if (buffer == NULL || capacity == 0) {
        dlclose(appkit);
        dlclose(objc);
        return (int64_t)size;
    }
    if ((uint64_t)capacity < (uint64_t)size) {
        dlclose(appkit);
        dlclose(objc);
        return -ENOSPC;
    }
    memcpy(buffer, content, size);
    dlclose(appkit);
    dlclose(objc);
    return (int64_t)size;
}

#else

int64_t adou_clipboard_image_read(void *buffer, int64_t capacity, int64_t *kind_out) {
    (void)buffer;
    (void)capacity;
    (void)kind_out;
    return 0;
}

#endif
