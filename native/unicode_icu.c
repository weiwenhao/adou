#include <dlfcn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <unicode/ubrk.h>
#include <unicode/uchar.h>
#include <unicode/uscript.h>
#include <unicode/utf8.h>
#include <unicode/utext.h>
#include <unicode/unorm2.h>
#include <unicode/ustring.h>

#define STRINGIFY_INNER(value) #value
#define STRINGIFY(value) STRINGIFY_INNER(value)

typedef UBreakIterator *(*break_open_fn)(UBreakIteratorType, const char *, const UChar *, int32_t, UErrorCode *);
typedef void (*break_close_fn)(UBreakIterator *);
typedef void (*break_set_text_fn)(UBreakIterator *, UText *, UErrorCode *);
typedef int32_t (*break_position_fn)(UBreakIterator *);
typedef int32_t (*break_status_fn)(UBreakIterator *);
typedef UText *(*text_open_utf8_fn)(UText *, const char *, int64_t, UErrorCode *);
typedef UText *(*text_close_fn)(UText *);
typedef int8_t (*char_type_fn)(UChar32);
typedef UBool (*binary_property_fn)(UChar32, UProperty);
typedef int32_t (*int_property_fn)(UChar32, UProperty);
typedef const UNormalizer2 *(*normalizer_instance_fn)(UErrorCode *);
typedef int32_t (*normalize_fn)(const UNormalizer2 *, const UChar *, int32_t, UChar *, int32_t, UErrorCode *);
typedef UChar *(*str_from_utf8_fn)(UChar *, int32_t, int32_t *, const char *, int32_t, UErrorCode *);
typedef char *(*str_to_utf8_fn)(char *, int32_t, int32_t *, const UChar *, int32_t, UErrorCode *);

typedef struct {
    bool attempted;
    bool available;
    void *i18n;
    void *common;
    break_open_fn break_open;
    break_close_fn break_close;
    break_set_text_fn break_set_text;
    break_position_fn break_first;
    break_position_fn break_next;
    break_status_fn break_status;
    text_open_utf8_fn text_open_utf8;
    text_close_fn text_close;
    char_type_fn char_type;
    binary_property_fn binary_property;
    int_property_fn int_property;
    normalizer_instance_fn get_nfkc;
    normalizer_instance_fn get_nfd;
    normalize_fn normalize;
    str_from_utf8_fn str_from_utf8;
    str_to_utf8_fn str_to_utf8;
} icu_api_t;

static icu_api_t api;

static void *open_first(const char *const *names) {
    for (int index = 0; names[index] != NULL; ++index) {
        void *handle = dlopen(names[index], RTLD_LAZY | RTLD_LOCAL);
        if (handle != NULL) return handle;
    }
    return NULL;
}

static bool load_icu(void) {
    if (api.attempted) return api.available;
    api.attempted = true;
    const char *const i18n_names[] = {"/opt/homebrew/opt/icu4c/lib/libicui18n.dylib", "/usr/local/opt/icu4c/lib/libicui18n.dylib", "libicui18n.dylib", "libicui18n.so", NULL};
    const char *const common_names[] = {"/opt/homebrew/opt/icu4c/lib/libicuuc.dylib", "/usr/local/opt/icu4c/lib/libicuuc.dylib", "libicuuc.dylib", "libicuuc.so", NULL};
    api.i18n = open_first(i18n_names);
    api.common = open_first(common_names);
    if (api.i18n == NULL || api.common == NULL) return false;
    api.break_open = (break_open_fn) dlsym(api.i18n, STRINGIFY(ubrk_open));
    api.break_close = (break_close_fn) dlsym(api.i18n, STRINGIFY(ubrk_close));
    api.break_set_text = (break_set_text_fn) dlsym(api.i18n, STRINGIFY(ubrk_setUText));
    api.break_first = (break_position_fn) dlsym(api.i18n, STRINGIFY(ubrk_first));
    api.break_next = (break_position_fn) dlsym(api.i18n, STRINGIFY(ubrk_next));
    api.break_status = (break_status_fn) dlsym(api.i18n, STRINGIFY(ubrk_getRuleStatus));
    api.text_open_utf8 = (text_open_utf8_fn) dlsym(api.common, STRINGIFY(utext_openUTF8));
    api.text_close = (text_close_fn) dlsym(api.common, STRINGIFY(utext_close));
    api.char_type = (char_type_fn) dlsym(api.common, STRINGIFY(u_charType));
    api.binary_property = (binary_property_fn) dlsym(api.common, STRINGIFY(u_hasBinaryProperty));
    api.int_property = (int_property_fn) dlsym(api.common, STRINGIFY(u_getIntPropertyValue));
    api.get_nfkc = (normalizer_instance_fn) dlsym(api.common, STRINGIFY(unorm2_getNFKCInstance));
    api.get_nfd = (normalizer_instance_fn) dlsym(api.common, STRINGIFY(unorm2_getNFDInstance));
    api.normalize = (normalize_fn) dlsym(api.common, STRINGIFY(unorm2_normalize));
    api.str_from_utf8 = (str_from_utf8_fn) dlsym(api.common, STRINGIFY(u_strFromUTF8));
    api.str_to_utf8 = (str_to_utf8_fn) dlsym(api.common, STRINGIFY(u_strToUTF8));
    api.available = api.break_open != NULL && api.break_close != NULL && api.break_set_text != NULL && api.break_first != NULL && api.break_next != NULL && api.break_status != NULL && api.text_open_utf8 != NULL && api.text_close != NULL && api.char_type != NULL && api.binary_property != NULL && api.int_property != NULL && api.get_nfkc != NULL && api.get_nfd != NULL && api.normalize != NULL && api.str_from_utf8 != NULL && api.str_to_utf8 != NULL;
    return api.available;
}

bool adou_icu_available(void) {
    return load_icu();
}

static int64_t normalize_utf8(normalizer_instance_fn get_normalizer, const char *text, int64_t length, char *output, int64_t capacity) {
    if (!load_icu() || get_normalizer == NULL || text == NULL || length < 0 || length > INT32_MAX || capacity < 0 || capacity > INT32_MAX) return -1;
    UErrorCode status = U_ZERO_ERROR;
    int32_t source_length = 0;
    api.str_from_utf8(NULL, 0, &source_length, text, (int32_t) length, &status);
    if (status != U_BUFFER_OVERFLOW_ERROR && U_FAILURE(status)) return -1;
    status = U_ZERO_ERROR;
    UChar *source = malloc(((size_t) source_length + 1U) * sizeof(UChar));
    if (source == NULL) return -1;
    api.str_from_utf8(source, source_length + 1, NULL, text, (int32_t) length, &status);
    if (U_FAILURE(status)) {
        free(source);
        return -1;
    }
    const UNormalizer2 *normalizer = get_normalizer(&status);
    if (normalizer == NULL || U_FAILURE(status)) {
        free(source);
        return -1;
    }
    status = U_ZERO_ERROR;
    int32_t normalized_length = api.normalize(normalizer, source, source_length, NULL, 0, &status);
    if (status != U_BUFFER_OVERFLOW_ERROR && U_FAILURE(status)) {
        free(source);
        return -1;
    }
    status = U_ZERO_ERROR;
    UChar *normalized = malloc(((size_t) normalized_length + 1U) * sizeof(UChar));
    if (normalized == NULL) {
        free(source);
        return -1;
    }
    api.normalize(normalizer, source, source_length, normalized, normalized_length + 1, &status);
    free(source);
    if (U_FAILURE(status)) {
        free(normalized);
        return -1;
    }
    status = U_ZERO_ERROR;
    int32_t required = 0;
    api.str_to_utf8(NULL, 0, &required, normalized, normalized_length, &status);
    if (status != U_BUFFER_OVERFLOW_ERROR && U_FAILURE(status)) {
        free(normalized);
        return -1;
    }
    if (output == NULL || capacity == 0) {
        free(normalized);
        return required;
    }
    if (capacity <= required) {
        free(normalized);
        return -2;
    }
    status = U_ZERO_ERROR;
    api.str_to_utf8(output, (int32_t) capacity, &required, normalized, normalized_length, &status);
    free(normalized);
    return U_FAILURE(status) ? -1 : required;
}

int64_t adou_icu_nfkc(const char *text, int64_t length, char *output, int64_t capacity) {
    if (!load_icu()) return -1;
    return normalize_utf8(api.get_nfkc, text, length, output, capacity);
}

int64_t adou_icu_nfd(const char *text, int64_t length, char *output, int64_t capacity) {
    if (!load_icu()) return -1;
    return normalize_utf8(api.get_nfd, text, length, output, capacity);
}

static UBreakIterator *open_break_iterator(const char *text, int64_t length, UBreakIteratorType type, UText *utext) {
    if (!load_icu() || length < 0 || length > INT32_MAX) return NULL;
    UErrorCode status = U_ZERO_ERROR;
    if (api.text_open_utf8(utext, text, length, &status) == NULL || U_FAILURE(status)) return NULL;
    UBreakIterator *iterator = api.break_open(type, NULL, NULL, 0, &status);
    if (iterator == NULL || U_FAILURE(status)) {
        api.text_close(utext);
        return NULL;
    }
    api.break_set_text(iterator, utext, &status);
    if (U_FAILURE(status)) {
        api.break_close(iterator);
        api.text_close(utext);
        return NULL;
    }
    return iterator;
}

int64_t adou_icu_grapheme_breaks(const char *text, int64_t length, int64_t *boundaries, int64_t capacity) {
    if (boundaries == NULL || capacity <= 0) return -1;
    UText utext = UTEXT_INITIALIZER;
    UBreakIterator *iterator = open_break_iterator(text, length, UBRK_CHARACTER, &utext);
    if (iterator == NULL) return -1;
    int64_t count = 0;
    int32_t boundary = api.break_first(iterator);
    while (boundary != UBRK_DONE) {
        if (count >= capacity) {
            count = -2;
            break;
        }
        boundaries[count++] = boundary;
        boundary = api.break_next(iterator);
    }
    api.break_close(iterator);
    api.text_close(&utext);
    return count;
}

int64_t adou_icu_word_segments(const char *text, int64_t length, int64_t *starts, int64_t *ends, uint8_t *word_like, int64_t capacity) {
    if (starts == NULL || ends == NULL || word_like == NULL || capacity <= 0) return -1;
    UText utext = UTEXT_INITIALIZER;
    UBreakIterator *iterator = open_break_iterator(text, length, UBRK_WORD, &utext);
    if (iterator == NULL) return -1;
    int64_t count = 0;
    int32_t start = api.break_first(iterator);
    int32_t end = api.break_next(iterator);
    while (end != UBRK_DONE) {
        if (count >= capacity) {
            count = -2;
            break;
        }
        starts[count] = start;
        ends[count] = end;
        word_like[count] = api.break_status(iterator) >= UBRK_WORD_NUMBER;
        ++count;
        start = end;
        end = api.break_next(iterator);
    }
    api.break_close(iterator);
    api.text_close(&utext);
    return count;
}

static bool non_printing(UChar32 codepoint) {
    int8_t type = api.char_type(codepoint);
    return api.binary_property(codepoint, UCHAR_DEFAULT_IGNORABLE_CODE_POINT) || type == U_CONTROL_CHAR || type == U_FORMAT_CHAR || type == U_NON_SPACING_MARK || type == U_ENCLOSING_MARK || type == U_COMBINING_SPACING_MARK || type == U_SURROGATE;
}

int64_t adou_icu_grapheme_width(const char *text, int64_t length) {
    if (!load_icu() || text == NULL || length <= 0 || length > INT32_MAX) return length == 0 ? 0 : -1;
    if (length == 1 && text[0] == '\t') return 3;
    int32_t offset = 0;
    UChar32 codepoint = 0;
    bool all_non_printing = true;
    bool emoji = false;
    bool regional = false;
    int64_t width = 0;
    bool found_base = false;
    while (offset < (int32_t) length) {
        U8_NEXT(text, offset, (int32_t) length, codepoint);
        if (codepoint < 0) return -1;
        if (!non_printing(codepoint)) all_non_printing = false;
        if (codepoint == 0x200d || codepoint == 0xfe0f || codepoint == 0x20e3 || api.binary_property(codepoint, UCHAR_EMOJI_PRESENTATION)) emoji = true;
        if (codepoint >= 0x1f1e6 && codepoint <= 0x1f1ff) regional = true;
        if (!found_base && !non_printing(codepoint)) {
            int32_t east_asian = api.int_property(codepoint, UCHAR_EAST_ASIAN_WIDTH);
            width = east_asian == U_EA_WIDE || east_asian == U_EA_FULLWIDTH ? 2 : 1;
            found_base = true;
            continue;
        }
        if (found_base && ((codepoint >= 0xff00 && codepoint <= 0xffef) || codepoint == 0x0e33 || codepoint == 0x0eb3)) {
            int32_t east_asian = api.int_property(codepoint, UCHAR_EAST_ASIAN_WIDTH);
            width += codepoint == 0x0e33 || codepoint == 0x0eb3 ? 1 : (east_asian == U_EA_WIDE || east_asian == U_EA_FULLWIDTH ? 2 : 1);
        }
    }
    if (all_non_printing || !found_base) return 0;
    if (emoji || regional) return 2;
    return width;
}

int64_t adou_icu_visible_width(const char *text, int64_t length) {
    if (!load_icu() || text == NULL || length < 0 || length > INT32_MAX) return -1;
    UText utext = UTEXT_INITIALIZER;
    UBreakIterator *iterator = open_break_iterator(text, length, UBRK_CHARACTER, &utext);
    if (iterator == NULL) return -1;
    int64_t width = 0;
    int32_t start = api.break_first(iterator);
    int32_t end = api.break_next(iterator);
    while (end != UBRK_DONE) {
        int64_t segment_width = adou_icu_grapheme_width(text + start, end - start);
        if (segment_width < 0) {
            width = -1;
            break;
        }
        width += segment_width;
        start = end;
        end = api.break_next(iterator);
    }
    api.break_close(iterator);
    api.text_close(&utext);
    return width;
}

bool adou_icu_is_cjk_break(const char *text, int64_t length) {
    if (!load_icu() || text == NULL || length <= 0 || length > INT32_MAX) return false;
    int32_t offset = 0;
    UChar32 codepoint = 0;
    U8_NEXT(text, offset, (int32_t) length, codepoint);
    if (codepoint < 0) return false;
    int32_t script = api.int_property(codepoint, UCHAR_SCRIPT);
    return script == USCRIPT_HAN || script == USCRIPT_HIRAGANA || script == USCRIPT_KATAKANA || script == USCRIPT_HANGUL || script == USCRIPT_BOPOMOFO;
}
