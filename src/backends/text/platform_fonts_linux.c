#include <dlfcn.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>

enum {
    SHELLOWO_FONT_KIND_EMOJI = 1,
    SHELLOWO_FONT_KIND_SYMBOL = 2,
    SHELLOWO_FONT_KIND_CASCADE = 3,
};

typedef struct _FcConfig FcConfig;
typedef struct _FcPattern FcPattern;
typedef struct _FcCharSet FcCharSet;
typedef unsigned char FcChar8;
typedef uint32_t FcChar32;
typedef int FcBool;
typedef int FcResult;

typedef struct _FcFontSet {
    int nfont;
    int sfont;
    FcPattern **fonts;
} FcFontSet;

struct shellowo_fc_api {
    void *handle;
    FcConfig *(*FcInitLoadConfigAndFonts)(void);
    void (*FcConfigDestroy)(FcConfig *);
    FcPattern *(*FcPatternCreate)(void);
    void (*FcPatternDestroy)(FcPattern *);
    FcBool (*FcPatternAddString)(FcPattern *, const char *, const FcChar8 *);
    FcBool (*FcPatternAddCharSet)(FcPattern *, const char *, const FcCharSet *);
    FcCharSet *(*FcCharSetCreate)(void);
    void (*FcCharSetDestroy)(FcCharSet *);
    FcBool (*FcCharSetAddChar)(FcCharSet *, FcChar32);
    FcBool (*FcConfigSubstitute)(FcConfig *, FcPattern *, int);
    void (*FcDefaultSubstitute)(FcPattern *);
    FcFontSet *(*FcFontSort)(FcConfig *, FcPattern *, FcBool, FcCharSet **, FcResult *);
    void (*FcFontSetDestroy)(FcFontSet *);
    FcResult (*FcPatternGetString)(const FcPattern *, const char *, int, FcChar8 **);
};

static int shellowo_copy_path(const char *candidate, char *out_path, int out_len) {
    if (candidate == NULL || candidate[0] == '\0' || out_path == NULL || out_len <= 1) return 0;
    size_t len = strlen(candidate);
    if (len >= (size_t)out_len) len = (size_t)out_len - 1;
    memcpy(out_path, candidate, len);
    out_path[len] = '\0';
    return (int)len;
}

static void *shellowo_fc_symbol(void *handle, const char *name) {
    return dlsym(handle, name);
}

static int shellowo_load_fontconfig(struct shellowo_fc_api *api) {
    memset(api, 0, sizeof(*api));
    api->handle = dlopen("libfontconfig.so.1", RTLD_LAZY | RTLD_LOCAL);
    if (api->handle == NULL) api->handle = dlopen("libfontconfig.so", RTLD_LAZY | RTLD_LOCAL);
    if (api->handle == NULL) return 0;

    api->FcInitLoadConfigAndFonts = (FcConfig *(*)(void))shellowo_fc_symbol(api->handle, "FcInitLoadConfigAndFonts");
    api->FcConfigDestroy = (void (*)(FcConfig *))shellowo_fc_symbol(api->handle, "FcConfigDestroy");
    api->FcPatternCreate = (FcPattern *(*)(void))shellowo_fc_symbol(api->handle, "FcPatternCreate");
    api->FcPatternDestroy = (void (*)(FcPattern *))shellowo_fc_symbol(api->handle, "FcPatternDestroy");
    api->FcPatternAddString = (FcBool (*)(FcPattern *, const char *, const FcChar8 *))shellowo_fc_symbol(api->handle, "FcPatternAddString");
    api->FcPatternAddCharSet = (FcBool (*)(FcPattern *, const char *, const FcCharSet *))shellowo_fc_symbol(api->handle, "FcPatternAddCharSet");
    api->FcCharSetCreate = (FcCharSet *(*)(void))shellowo_fc_symbol(api->handle, "FcCharSetCreate");
    api->FcCharSetDestroy = (void (*)(FcCharSet *))shellowo_fc_symbol(api->handle, "FcCharSetDestroy");
    api->FcCharSetAddChar = (FcBool (*)(FcCharSet *, FcChar32))shellowo_fc_symbol(api->handle, "FcCharSetAddChar");
    api->FcConfigSubstitute = (FcBool (*)(FcConfig *, FcPattern *, int))shellowo_fc_symbol(api->handle, "FcConfigSubstitute");
    api->FcDefaultSubstitute = (void (*)(FcPattern *))shellowo_fc_symbol(api->handle, "FcDefaultSubstitute");
    api->FcFontSort = (FcFontSet *(*)(FcConfig *, FcPattern *, FcBool, FcCharSet **, FcResult *))shellowo_fc_symbol(api->handle, "FcFontSort");
    api->FcFontSetDestroy = (void (*)(FcFontSet *))shellowo_fc_symbol(api->handle, "FcFontSetDestroy");
    api->FcPatternGetString = (FcResult (*)(const FcPattern *, const char *, int, FcChar8 **))shellowo_fc_symbol(api->handle, "FcPatternGetString");

    if (api->FcInitLoadConfigAndFonts == NULL ||
        api->FcConfigDestroy == NULL ||
        api->FcPatternCreate == NULL ||
        api->FcPatternDestroy == NULL ||
        api->FcPatternAddString == NULL ||
        api->FcPatternAddCharSet == NULL ||
        api->FcCharSetCreate == NULL ||
        api->FcCharSetDestroy == NULL ||
        api->FcCharSetAddChar == NULL ||
        api->FcConfigSubstitute == NULL ||
        api->FcDefaultSubstitute == NULL ||
        api->FcFontSort == NULL ||
        api->FcFontSetDestroy == NULL ||
        api->FcPatternGetString == NULL) {
        dlclose(api->handle);
        memset(api, 0, sizeof(*api));
        return 0;
    }

    return 1;
}

static void shellowo_unload_fontconfig(struct shellowo_fc_api *api) {
    if (api->handle != NULL) dlclose(api->handle);
    memset(api, 0, sizeof(*api));
}

static int shellowo_try_known_paths(
    const char *const *paths,
    int path_count,
    int candidate_index,
    int *path_index,
    char *out_path,
    int out_len
) {
    for (int i = 0; i < path_count; i++) {
        if (*path_index == candidate_index) return shellowo_copy_path(paths[i], out_path, out_len);
        (*path_index)++;
    }
    return 0;
}

static int shellowo_try_fontconfig_pattern(
    struct shellowo_fc_api *api,
    FcConfig *config,
    const char *family,
    uint32_t codepoint,
    int candidate_index,
    int *path_index,
    char *out_path,
    int out_len
) {
    FcPattern *pattern = api->FcPatternCreate();
    if (pattern == NULL) return 0;

    if (family != NULL) {
        api->FcPatternAddString(pattern, "family", (const FcChar8 *)family);
    }

    FcCharSet *charset = NULL;
    if (codepoint != 0) {
        charset = api->FcCharSetCreate();
        if (charset != NULL) {
            api->FcCharSetAddChar(charset, codepoint);
            api->FcPatternAddCharSet(pattern, "charset", charset);
        }
    }

    api->FcConfigSubstitute(config, pattern, 0);
    api->FcDefaultSubstitute(pattern);

    FcResult result = 0;
    FcFontSet *fonts = api->FcFontSort(config, pattern, 0, NULL, &result);
    int copied = 0;
    if (fonts != NULL) {
        for (int i = 0; i < fonts->nfont; i++) {
            FcChar8 *file = NULL;
            if (api->FcPatternGetString(fonts->fonts[i], "file", 0, &file) != 0 || file == NULL) continue;
            if (*path_index == candidate_index) {
                copied = shellowo_copy_path((const char *)file, out_path, out_len);
                break;
            }
            (*path_index)++;
        }
        api->FcFontSetDestroy(fonts);
    }

    if (charset != NULL) api->FcCharSetDestroy(charset);
    api->FcPatternDestroy(pattern);
    return copied;
}

static int shellowo_try_fontconfig_families(
    const char *const *families,
    int family_count,
    uint32_t codepoint,
    int candidate_index,
    int *path_index,
    char *out_path,
    int out_len
) {
    struct shellowo_fc_api api;
    if (!shellowo_load_fontconfig(&api)) return 0;

    FcConfig *config = api.FcInitLoadConfigAndFonts();
    int result = 0;
    if (config != NULL) {
        if (family_count == 0) {
            result = shellowo_try_fontconfig_pattern(&api, config, NULL, codepoint, candidate_index, path_index, out_path, out_len);
        } else {
            for (int i = 0; i < family_count && result == 0; i++) {
                result = shellowo_try_fontconfig_pattern(&api, config, families[i], codepoint, candidate_index, path_index, out_path, out_len);
            }
        }
        api.FcConfigDestroy(config);
    }

    shellowo_unload_fontconfig(&api);
    return result;
}

static int shellowo_try_linux_fonts(
    const char *const *known_paths,
    int known_path_count,
    const char *const *families,
    int family_count,
    uint32_t codepoint,
    int candidate_index,
    char *out_path,
    int out_len
) {
    int path_index = 0;
    int len = shellowo_try_known_paths(known_paths, known_path_count, candidate_index, &path_index, out_path, out_len);
    if (len > 0) return len;
    return shellowo_try_fontconfig_families(families, family_count, codepoint, candidate_index, &path_index, out_path, out_len);
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
        const char *known_paths[] = {
            "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf",
            "/usr/share/fonts/noto/NotoColorEmoji.ttf",
            "/usr/local/share/fonts/NotoColorEmoji.ttf",
            "/usr/share/fonts/google-noto-emoji/NotoColorEmoji.ttf",
        };
        const char *families[] = {
            "Noto Color Emoji",
            "Twemoji",
            "EmojiOne Color",
            "Twitter Color Emoji",
            "Segoe UI Emoji",
        };
        return shellowo_try_linux_fonts(known_paths, 4, families, 5, 0x1f600, candidate_index, out_path, (int)out_len);
    }

    if (kind == SHELLOWO_FONT_KIND_SYMBOL) {
        const char *known_paths[] = {
            "/usr/share/fonts/truetype/noto/NotoSansSymbols2-Regular.ttf",
            "/usr/share/fonts/truetype/noto/NotoSansSymbols-Regular.ttf",
            "/usr/share/fonts/noto/NotoSansSymbols2-Regular.ttf",
            "/usr/share/fonts/noto/NotoSansSymbols-Regular.ttf",
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        };
        const char *families[] = {
            "Noto Sans Symbols 2",
            "Noto Sans Symbols",
            "DejaVu Sans",
            "Symbola",
            "FreeSerif",
        };
        return shellowo_try_linux_fonts(known_paths, 5, families, 5, 0x2699, candidate_index, out_path, (int)out_len);
    }

    if (kind == SHELLOWO_FONT_KIND_CASCADE) {
        const char *known_paths[] = {
            "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
            "/usr/share/fonts/opentype/noto/NotoSansCJK.ttc",
            "/usr/share/fonts/truetype/noto/NotoSansDevanagari-Regular.ttf",
            "/usr/share/fonts/truetype/noto/NotoSansThai-Regular.ttf",
            "/usr/share/fonts/truetype/noto/NotoNaskhArabic-Regular.ttf",
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            "/usr/share/fonts/truetype/liberation2/LiberationSans-Regular.ttf",
        };
        const char *families[] = {
            "Noto Sans CJK SC",
            "Noto Sans CJK TC",
            "Noto Sans CJK JP",
            "Noto Sans CJK KR",
            "Noto Sans Devanagari",
            "Noto Sans Thai",
            "Noto Naskh Arabic",
            "Noto Sans Hebrew",
            "DejaVu Sans",
            "Liberation Sans",
        };
        return shellowo_try_linux_fonts(known_paths, 7, families, 10, codepoint, candidate_index, out_path, (int)out_len);
    }

    return 0;
}
