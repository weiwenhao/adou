// Thin wrappers around QuickJS API entry points that are defined as static
// inline in quickjs.h and therefore have no exported symbol to #linkid
// against.  Everything else is called directly from src/agent/quickjs_ffi.n.
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#include "quickjs.h"

JSValue adou_js_new_int32(JSContext *ctx, int32_t value) {
    return JS_NewInt32(ctx, value);
}

bool adou_js_is_exception(JSValueConst value) {
    return JS_IsException(value);
}

JSValue adou_js_new_string(JSContext *ctx, const char *str) {
    return JS_NewString(ctx, str);
}

const char *adou_js_to_c_string_len(JSContext *ctx, size_t *plen, JSValueConst value) {
    return JS_ToCStringLen(ctx, plen, value);
}
