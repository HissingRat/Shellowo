#include <CoreFoundation/CoreFoundation.h>
#include <CoreText/CoreText.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

enum {
    SHELLOWO_FONT_KIND_EMOJI = 1,
    SHELLOWO_FONT_KIND_SYMBOL = 2,
    SHELLOWO_FONT_KIND_CASCADE = 3,
};

static int shellowo_copy_path(const char *candidate, char *out_path, int out_len) {
    if (candidate == NULL || out_path == NULL || out_len <= 1) return 0;
    size_t len = strlen(candidate);
    if (len >= (size_t)out_len) len = (size_t)out_len - 1;
    memcpy(out_path, candidate, len);
    out_path[len] = '\0';
    return (int)len;
}

static int shellowo_copy_font_url_path(CFTypeRef value, char *out_path, int out_len) {
    if (value == NULL || out_path == NULL || out_len <= 1) return 0;
    CFURLRef url = NULL;
    if (CFGetTypeID(value) == CTFontDescriptorGetTypeID()) {
        url = (CFURLRef)CTFontDescriptorCopyAttribute((CTFontDescriptorRef)value, kCTFontURLAttribute);
    } else if (CFGetTypeID(value) == CTFontGetTypeID()) {
        url = (CFURLRef)CTFontCopyAttribute((CTFontRef)value, kCTFontURLAttribute);
    } else if (CFGetTypeID(value) == CFURLGetTypeID()) {
        url = (CFURLRef)CFRetain(value);
    }

    if (url == NULL) return 0;
    bool ok = CFURLGetFileSystemRepresentation(url, true, (UInt8 *)out_path, out_len);
    out_path[out_len - 1] = '\0';
    int len = ok ? (int)strlen(out_path) : 0;
    CFRelease(url);
    return len;
}

static int shellowo_try_font_attribute(
    CFStringRef attribute,
    CFStringRef value,
    int candidate_index,
    int *path_index,
    char *out_path,
    int out_len
) {
    const void *keys[] = { attribute };
    const void *values[] = { value };
    CFDictionaryRef attributes = CFDictionaryCreate(
        kCFAllocatorDefault,
        keys,
        values,
        1,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    if (attributes == NULL) return 0;

    CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes(attributes);
    CFRelease(attributes);
    if (descriptor == NULL) return 0;

    CFArrayRef matches = CTFontDescriptorCreateMatchingFontDescriptors(descriptor, NULL);
    CFRelease(descriptor);
    if (matches == NULL) return 0;

    int result = 0;
    CFIndex count = CFArrayGetCount(matches);
    for (CFIndex i = 0; i < count; i++) {
        char candidate_path[1024];
        int len = shellowo_copy_font_url_path(CFArrayGetValueAtIndex(matches, i), candidate_path, sizeof(candidate_path));
        if (len <= 0) continue;
        if (*path_index == candidate_index) {
            result = shellowo_copy_path(candidate_path, out_path, out_len);
            break;
        }
        (*path_index)++;
    }

    CFRelease(matches);
    return result;
}

static int shellowo_try_named_fonts(
    const CFStringRef *names,
    int name_count,
    int candidate_index,
    char *out_path,
    int out_len
) {
    int path_index = 0;
    for (int i = 0; i < name_count; i++) {
        int len = shellowo_try_font_attribute(kCTFontNameAttribute, names[i], candidate_index, &path_index, out_path, out_len);
        if (len > 0) return len;
        len = shellowo_try_font_attribute(kCTFontFamilyNameAttribute, names[i], candidate_index, &path_index, out_path, out_len);
        if (len > 0) return len;
    }
    return 0;
}

static int shellowo_try_cascade(
    uint32_t codepoint,
    int candidate_index,
    char *out_path,
    int out_len
) {
    (void)codepoint;
    CTFontRef base_font = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 16.0, NULL);
    if (base_font == NULL) return 0;

    const void *language_values[] = {
        CFSTR("en"),
        CFSTR("zh-Hans"),
        CFSTR("zh-Hant"),
        CFSTR("ja"),
        CFSTR("ko"),
        CFSTR("ar"),
        CFSTR("he"),
        CFSTR("hi"),
        CFSTR("th"),
    };
    CFArrayRef languages = CFArrayCreate(kCFAllocatorDefault, language_values, 9, &kCFTypeArrayCallBacks);
    if (languages == NULL) {
        CFRelease(base_font);
        return 0;
    }

    CFArrayRef cascade = CTFontCopyDefaultCascadeListForLanguages(base_font, languages);
    int result = 0;
    int path_index = 0;
    if (cascade != NULL) {
        CFIndex count = CFArrayGetCount(cascade);
        for (CFIndex i = 0; i < count; i++) {
            char candidate_path[1024];
            int len = shellowo_copy_font_url_path(CFArrayGetValueAtIndex(cascade, i), candidate_path, sizeof(candidate_path));
            if (len <= 0) continue;
            if (path_index == candidate_index) {
                result = shellowo_copy_path(candidate_path, out_path, out_len);
                break;
            }
            path_index++;
        }
        CFRelease(cascade);
    }

    if (result == 0) {
        CFArrayRef urls = CTFontManagerCopyAvailableFontURLs();
        CFIndex url_count = urls == NULL ? 0 : CFArrayGetCount(urls);
        for (CFIndex i = 0; i < url_count; i++) {
            char candidate_path[1024];
            int len = shellowo_copy_font_url_path(CFArrayGetValueAtIndex(urls, i), candidate_path, sizeof(candidate_path));
            if (len <= 0) continue;
            if (path_index == candidate_index) {
                result = shellowo_copy_path(candidate_path, out_path, out_len);
                break;
            }
            path_index++;
        }
        if (urls != NULL) CFRelease(urls);
    }

    CFRelease(languages);
    CFRelease(base_font);
    return result;
}

int shellowo_text_font_candidate(
    int kind,
    uint32_t codepoint,
    int candidate_index,
    char *out_path,
    size_t out_len
) {
    if (out_path == NULL || out_len <= 1 || candidate_index < 0) return 0;
    out_path[0] = '\0';
    if (out_len > 2147483647u) out_len = 2147483647u;

    if (kind == SHELLOWO_FONT_KIND_EMOJI) {
        const CFStringRef names[] = {
            CFSTR("AppleColorEmoji"),
            CFSTR("Apple Color Emoji"),
            CFSTR("Noto Color Emoji"),
            CFSTR("Segoe UI Emoji"),
        };
        return shellowo_try_named_fonts(names, 4, candidate_index, out_path, (int)out_len);
    }

    if (kind == SHELLOWO_FONT_KIND_SYMBOL) {
        const CFStringRef names[] = {
            CFSTR("AppleSymbols"),
            CFSTR("Apple Symbols"),
            CFSTR("SF Symbols"),
            CFSTR("Noto Sans Symbols"),
            CFSTR("Noto Sans Symbols 2"),
            CFSTR("Segoe UI Symbol"),
        };
        return shellowo_try_named_fonts(names, 6, candidate_index, out_path, (int)out_len);
    }

    if (kind == SHELLOWO_FONT_KIND_CASCADE) {
        return shellowo_try_cascade(codepoint, candidate_index, out_path, (int)out_len);
    }

    return 0;
}
