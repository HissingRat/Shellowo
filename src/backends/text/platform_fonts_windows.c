#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <string.h>
#include <wchar.h>

enum {
    SHELLOWO_FONT_KIND_EMOJI = 1,
    SHELLOWO_FONT_KIND_SYMBOL = 2,
    SHELLOWO_FONT_KIND_CASCADE = 3,
};

static int shellowo_copy_path(const char *candidate, char *out_path, int out_len) {
    if (candidate == NULL || candidate[0] == '\0' || out_path == NULL || out_len <= 1) return 0;
    size_t len = strlen(candidate);
    if (len >= (size_t)out_len) len = (size_t)out_len - 1;
    memcpy(out_path, candidate, len);
    out_path[len] = '\0';
    return (int)len;
}

static int shellowo_utf16_to_utf8(const wchar_t *value, char *out_path, int out_len) {
    if (value == NULL || out_path == NULL || out_len <= 1) return 0;
    int len = WideCharToMultiByte(CP_UTF8, 0, value, -1, out_path, out_len, NULL, NULL);
    if (len <= 0) {
        out_path[0] = '\0';
        return 0;
    }
    out_path[out_len - 1] = '\0';
    return (int)strlen(out_path);
}

static int shellowo_windows_font_path(const wchar_t *file_name, char *out_path, int out_len) {
    if (file_name == NULL || out_path == NULL || out_len <= 1) return 0;

    wchar_t windows_dir[MAX_PATH];
    UINT dir_len = GetWindowsDirectoryW(windows_dir, MAX_PATH);
    if (dir_len == 0 || dir_len >= MAX_PATH) return 0;

    wchar_t path[MAX_PATH * 2];
    int written = wsprintfW(path, L"%s\\Fonts\\%s", windows_dir, file_name);
    if (written <= 0) return 0;
    return shellowo_utf16_to_utf8(path, out_path, out_len);
}

static int shellowo_copy_known_file(
    const wchar_t *const *files,
    int file_count,
    int candidate_index,
    int *path_index,
    char *out_path,
    int out_len
) {
    for (int i = 0; i < file_count; i++) {
        char candidate[MAX_PATH * 4];
        int len = shellowo_windows_font_path(files[i], candidate, sizeof(candidate));
        if (len <= 0) continue;
        if (*path_index == candidate_index) return shellowo_copy_path(candidate, out_path, out_len);
        (*path_index)++;
    }
    return 0;
}

static int shellowo_contains_ci(const wchar_t *haystack, const wchar_t *needle) {
    if (haystack == NULL || needle == NULL || needle[0] == L'\0') return 0;
    size_t needle_len = wcslen(needle);
    for (const wchar_t *cursor = haystack; *cursor != L'\0'; cursor++) {
        if (_wcsnicmp(cursor, needle, needle_len) == 0) return 1;
    }
    return 0;
}

static int shellowo_matches_terms(const wchar_t *value_name, const wchar_t *const *terms, int term_count) {
    for (int i = 0; i < term_count; i++) {
        if (shellowo_contains_ci(value_name, terms[i])) return 1;
    }
    return 0;
}

static int shellowo_registry_font_path(const wchar_t *registry_value, char *out_path, int out_len) {
    if (registry_value == NULL || registry_value[0] == L'\0') return 0;
    if (shellowo_contains_ci(registry_value, L":\\") || registry_value[0] == L'\\') {
        return shellowo_utf16_to_utf8(registry_value, out_path, out_len);
    }
    return shellowo_windows_font_path(registry_value, out_path, out_len);
}

static int shellowo_try_registry_fonts(
    const wchar_t *const *terms,
    int term_count,
    int candidate_index,
    int *path_index,
    char *out_path,
    int out_len
) {
    HKEY key = NULL;
    LONG open_result = RegOpenKeyExW(
        HKEY_LOCAL_MACHINE,
        L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts",
        0,
        KEY_READ,
        &key
    );
    if (open_result != ERROR_SUCCESS) return 0;

    int result = 0;
    for (DWORD index = 0; result == 0; index++) {
        wchar_t value_name[257];
        DWORD value_name_len = (DWORD)(sizeof(value_name) / sizeof(value_name[0])) - 1;
        wchar_t value_data[MAX_PATH * 2];
        DWORD value_data_len = sizeof(value_data);
        DWORD type = 0;

        LONG enum_result = RegEnumValueW(
            key,
            index,
            value_name,
            &value_name_len,
            NULL,
            &type,
            (LPBYTE)value_data,
            &value_data_len
        );
        if (enum_result == ERROR_NO_MORE_ITEMS) break;
        if (enum_result != ERROR_SUCCESS || type != REG_SZ) continue;

        value_name[value_name_len] = L'\0';
        value_data[(sizeof(value_data) / sizeof(value_data[0])) - 1] = L'\0';
        if (!shellowo_matches_terms(value_name, terms, term_count)) continue;

        char candidate[MAX_PATH * 4];
        int len = shellowo_registry_font_path(value_data, candidate, sizeof(candidate));
        if (len <= 0) continue;
        if (*path_index == candidate_index) {
            result = shellowo_copy_path(candidate, out_path, out_len);
            break;
        }
        (*path_index)++;
    }

    RegCloseKey(key);
    return result;
}

static int shellowo_try_windows_fonts(
    const wchar_t *const *files,
    int file_count,
    const wchar_t *const *terms,
    int term_count,
    int candidate_index,
    char *out_path,
    int out_len
) {
    int path_index = 0;
    int len = shellowo_copy_known_file(files, file_count, candidate_index, &path_index, out_path, out_len);
    if (len > 0) return len;
    return shellowo_try_registry_fonts(terms, term_count, candidate_index, &path_index, out_path, out_len);
}

int shellowo_text_font_candidate(
    int kind,
    uint32_t codepoint,
    int candidate_index,
    char *out_path,
    size_t out_len
) {
    (void)codepoint;
    if (out_path == NULL || out_len <= 1 || candidate_index < 0) return 0;
    out_path[0] = '\0';
    if (out_len > 2147483647u) out_len = 2147483647u;

    if (kind == SHELLOWO_FONT_KIND_EMOJI) {
        const wchar_t *files[] = {
            L"seguiemj.ttf",
            L"seguisym.ttf",
            L"seguihis.ttf",
        };
        const wchar_t *terms[] = {
            L"Emoji",
            L"Segoe UI Symbol",
            L"Segoe UI Historic",
            L"Noto Color Emoji",
        };
        return shellowo_try_windows_fonts(files, 3, terms, 4, candidate_index, out_path, (int)out_len);
    }

    if (kind == SHELLOWO_FONT_KIND_SYMBOL) {
        const wchar_t *files[] = {
            L"seguisym.ttf",
            L"segmdl2.ttf",
            L"SegoeIcons.ttf",
            L"symbol.ttf",
            L"seguihis.ttf",
        };
        const wchar_t *terms[] = {
            L"Symbol",
            L"Symbols",
            L"Segoe MDL2 Assets",
            L"Segoe Fluent Icons",
            L"Historic",
        };
        return shellowo_try_windows_fonts(files, 5, terms, 5, candidate_index, out_path, (int)out_len);
    }

    if (kind == SHELLOWO_FONT_KIND_CASCADE) {
        const wchar_t *files[] = {
            L"msyh.ttc",
            L"simsun.ttc",
            L"msjh.ttc",
            L"YuGothM.ttc",
            L"meiryo.ttc",
            L"malgun.ttf",
            L"Nirmala.ttf",
            L"LeelawUI.ttf",
            L"ebrima.ttf",
            L"arialuni.ttf",
            L"tahoma.ttf",
        };
        const wchar_t *terms[] = {
            L"Noto",
            L"Microsoft YaHei",
            L"SimSun",
            L"Microsoft JhengHei",
            L"Yu Gothic",
            L"Meiryo",
            L"Malgun Gothic",
            L"Nirmala UI",
            L"Leelawadee UI",
            L"Ebrima",
            L"Arial Unicode",
            L"Tifinagh",
            L"Mongolian",
        };
        return shellowo_try_windows_fonts(files, 11, terms, 13, candidate_index, out_path, (int)out_len);
    }

    return 0;
}
