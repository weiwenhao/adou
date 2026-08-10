#include <regex.h>
#include <string.h>

int adou_regex_match(const char *pattern, const char *text) {
    regex_t regex;
    int compile_result = regcomp(&regex, pattern, REG_EXTENDED | REG_ICASE | REG_NOSUB);
    if (compile_result != 0) {
        return -1;
    }
    int match_result = regexec(&regex, text, 0, NULL, 0);
    regfree(&regex);
    return match_result == 0 ? 1 : 0;
}
