#ifndef SHELLOW_LIBVTERM_SHIM_H
#define SHELLOW_LIBVTERM_SHIM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct ShellowVTerm ShellowVTerm;

typedef struct {
    uint8_t kind;
    uint8_t r;
    uint8_t g;
    uint8_t b;
    uint8_t index;
} ShellowVTermColor;

typedef struct {
    uint32_t codepoint;
    uint8_t width;
    bool bold;
    bool italic;
    bool underline;
    bool blink;
    bool reverse;
    bool strike;
    ShellowVTermColor fg;
    ShellowVTermColor bg;
} ShellowVTermCell;

typedef struct {
    int row;
    int col;
    bool visible;
} ShellowVTermCursor;

typedef struct {
    int start_row;
    int end_row;
    int start_col;
    int end_col;
} ShellowVTermDirtyRect;

enum {
    SHELLOW_VTERM_MAX_DIRTY_RECTS = 32,
};

typedef struct {
    int start_row;
    int end_row;
    ShellowVTermDirtyRect rects[SHELLOW_VTERM_MAX_DIRTY_RECTS];
    int len;
    bool overflow;
    bool scrollback_dirty;
    bool cursor_dirty;
} ShellowVTermDirtyRows;

ShellowVTerm *shellow_vterm_new(int rows, int cols);
void shellow_vterm_free(ShellowVTerm *terminal);
size_t shellow_vterm_write(ShellowVTerm *terminal, const char *bytes, size_t len);
void shellow_vterm_resize(ShellowVTerm *terminal, int rows, int cols);
int shellow_vterm_get_cell(ShellowVTerm *terminal, int row, int col, ShellowVTermCell *out_cell);
int shellow_vterm_scrollback_rows(ShellowVTerm *terminal);
int shellow_vterm_get_scrollback_cell(ShellowVTerm *terminal, int row, int col, ShellowVTermCell *out_cell);
ShellowVTermDirtyRows shellow_vterm_dirty_rows(ShellowVTerm *terminal);
void shellow_vterm_clear_dirty(ShellowVTerm *terminal);
ShellowVTermCursor shellow_vterm_get_cursor(ShellowVTerm *terminal);
bool shellow_vterm_is_altscreen_active(ShellowVTerm *terminal);
bool shellow_vterm_is_bracketed_paste_enabled(ShellowVTerm *terminal);
int shellow_vterm_mouse_mode(ShellowVTerm *terminal);
const char *shellow_vterm_title(ShellowVTerm *terminal);
size_t shellow_vterm_mouse_move(ShellowVTerm *terminal, int row, int col, int modifiers, char *out, size_t out_len);
size_t shellow_vterm_mouse_button(ShellowVTerm *terminal, int row, int col, int button, bool pressed, int modifiers, char *out, size_t out_len);
void shellow_vterm_clear_scrollback(ShellowVTerm *terminal);

#endif
