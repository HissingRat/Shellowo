#include "libvterm_shim.h"

#include "vterm_internal.h"
#include "vterm.h"

#include <stdlib.h>
#include <string.h>

#define SHELLOW_SCROLLBACK_MAX_ROWS 10000

typedef struct {
    int cols;
    ShellowVTermCell *cells;
} ShellowScrollbackLine;

struct ShellowVTerm {
    VTerm *vt;
    VTermScreen *screen;
    ShellowScrollbackLine *scrollback;
    int scrollback_len;
    int scrollback_cap;
    bool altscreen_active;
    int mouse_mode;
    char *title;
    size_t title_len;
    size_t title_cap;
};

static ShellowVTermColor shellow_convert_color(VTermScreen *screen, VTermColor color) {
    ShellowVTermColor out = {0};
    if (VTERM_COLOR_IS_DEFAULT_FG(&color) || VTERM_COLOR_IS_DEFAULT_BG(&color)) {
        out.kind = 0;
        return out;
    }
    if (VTERM_COLOR_IS_INDEXED(&color)) {
        out.kind = 1;
        out.index = color.indexed.idx;
        return out;
    }

    vterm_screen_convert_color_to_rgb(screen, &color);
    out.kind = 2;
    out.r = color.rgb.red;
    out.g = color.rgb.green;
    out.b = color.rgb.blue;
    return out;
}

static ShellowVTermCell shellow_convert_cell(VTermScreen *screen, const VTermScreenCell *cell) {
    ShellowVTermCell out = {0};
    out.width = cell->width < 0 ? 1 : (uint8_t)cell->width;
    out.codepoint = cell->chars[0] == 0 ? ' ' : cell->chars[0];
    out.bold = cell->attrs.bold;
    out.italic = cell->attrs.italic;
    out.underline = cell->attrs.underline != 0;
    out.blink = cell->attrs.blink;
    out.reverse = cell->attrs.reverse;
    out.strike = cell->attrs.strike;
    out.fg = shellow_convert_color(screen, cell->fg);
    out.bg = shellow_convert_color(screen, cell->bg);
    return out;
}

static void shellow_scrollback_clear(ShellowVTerm *terminal) {
    if (terminal == NULL || terminal->scrollback == NULL) return;
    for (int i = 0; i < terminal->scrollback_len; i++) {
        free(terminal->scrollback[i].cells);
        terminal->scrollback[i].cells = NULL;
        terminal->scrollback[i].cols = 0;
    }
    terminal->scrollback_len = 0;
}

static int shellow_scrollback_ensure_cap(ShellowVTerm *terminal) {
    if (terminal->scrollback_cap > terminal->scrollback_len) return 1;

    int next_cap = terminal->scrollback_cap == 0 ? 128 : terminal->scrollback_cap * 2;
    if (next_cap > SHELLOW_SCROLLBACK_MAX_ROWS) next_cap = SHELLOW_SCROLLBACK_MAX_ROWS;
    if (next_cap <= terminal->scrollback_cap) return 1;

    ShellowScrollbackLine *next = realloc(terminal->scrollback, sizeof(ShellowScrollbackLine) * (size_t)next_cap);
    if (next == NULL) return 0;

    for (int i = terminal->scrollback_cap; i < next_cap; i++) {
        next[i].cols = 0;
        next[i].cells = NULL;
    }
    terminal->scrollback = next;
    terminal->scrollback_cap = next_cap;
    return 1;
}

static int shellow_screen_sb_pushline(int cols, const VTermScreenCell *cells, void *user) {
    ShellowVTerm *terminal = user;
    if (terminal == NULL || cols <= 0) return 0;

    if (terminal->scrollback_len >= SHELLOW_SCROLLBACK_MAX_ROWS) {
        free(terminal->scrollback[0].cells);
        for (int i = 1; i < terminal->scrollback_len; i++) {
            terminal->scrollback[i - 1] = terminal->scrollback[i];
        }
        terminal->scrollback_len--;
    }

    if (!shellow_scrollback_ensure_cap(terminal)) return 0;

    ShellowVTermCell *line_cells = calloc((size_t)cols, sizeof(ShellowVTermCell));
    if (line_cells == NULL) return 0;
    for (int col = 0; col < cols; col++) {
        line_cells[col] = shellow_convert_cell(terminal->screen, &cells[col]);
    }

    terminal->scrollback[terminal->scrollback_len].cols = cols;
    terminal->scrollback[terminal->scrollback_len].cells = line_cells;
    terminal->scrollback_len++;
    return 1;
}

static int shellow_screen_settermprop(VTermProp prop, VTermValue *val, void *user) {
    ShellowVTerm *terminal = user;
    if (terminal == NULL) return 1;
    if (prop == VTERM_PROP_ALTSCREEN) {
        terminal->altscreen_active = val->boolean;
    } else if (prop == VTERM_PROP_MOUSE) {
        terminal->mouse_mode = val->number;
    } else if (prop == VTERM_PROP_TITLE) {
        if (val->string.initial) terminal->title_len = 0;
        size_t next_len = terminal->title_len + val->string.len;
        if (next_len + 1 > terminal->title_cap) {
            size_t next_cap = terminal->title_cap == 0 ? 64 : terminal->title_cap * 2;
            while (next_cap < next_len + 1) next_cap *= 2;
            char *next_title = realloc(terminal->title, next_cap);
            if (next_title == NULL) return 0;
            terminal->title = next_title;
            terminal->title_cap = next_cap;
        }
        memcpy(terminal->title + terminal->title_len, val->string.str, val->string.len);
        terminal->title_len = next_len;
        terminal->title[terminal->title_len] = '\0';
    }
    return 1;
}

static const VTermScreenCallbacks shellow_screen_callbacks = {
    .settermprop = shellow_screen_settermprop,
    .sb_pushline = shellow_screen_sb_pushline,
};

ShellowVTerm *shellow_vterm_new(int rows, int cols) {
    ShellowVTerm *terminal = calloc(1, sizeof(ShellowVTerm));
    if (terminal == NULL) return NULL;

    terminal->vt = vterm_new(rows, cols);
    if (terminal->vt == NULL) {
        free(terminal);
        return NULL;
    }

    terminal->screen = vterm_obtain_screen(terminal->vt);
    if (terminal->screen == NULL) {
        vterm_free(terminal->vt);
        free(terminal);
        return NULL;
    }

    vterm_set_utf8(terminal->vt, 1);
    vterm_screen_enable_altscreen(terminal->screen, 1);
    vterm_screen_enable_reflow(terminal->screen, true);
    vterm_screen_set_callbacks(terminal->screen, &shellow_screen_callbacks, terminal);
    vterm_screen_reset(terminal->screen, 1);
    return terminal;
}

void shellow_vterm_free(ShellowVTerm *terminal) {
    if (terminal == NULL) return;
    shellow_scrollback_clear(terminal);
    free(terminal->scrollback);
    free(terminal->title);
    vterm_free(terminal->vt);
    free(terminal);
}

size_t shellow_vterm_write(ShellowVTerm *terminal, const char *bytes, size_t len) {
    size_t written = vterm_input_write(terminal->vt, bytes, len);
    vterm_screen_flush_damage(terminal->screen);
    return written;
}

void shellow_vterm_resize(ShellowVTerm *terminal, int rows, int cols) {
    vterm_set_size(terminal->vt, rows, cols);
    vterm_screen_flush_damage(terminal->screen);
}

int shellow_vterm_get_cell(ShellowVTerm *terminal, int row, int col, ShellowVTermCell *out_cell) {
    VTermScreenCell cell;
    VTermPos pos = { .row = row, .col = col };
    if (!vterm_screen_get_cell(terminal->screen, pos, &cell)) return 0;

    *out_cell = shellow_convert_cell(terminal->screen, &cell);
    return 1;
}

int shellow_vterm_scrollback_rows(ShellowVTerm *terminal) {
    if (terminal == NULL) return 0;
    return terminal->scrollback_len;
}

int shellow_vterm_get_scrollback_cell(ShellowVTerm *terminal, int row, int col, ShellowVTermCell *out_cell) {
    if (terminal == NULL || out_cell == NULL) return 0;
    if (row < 0 || row >= terminal->scrollback_len) return 0;
    ShellowScrollbackLine *line = &terminal->scrollback[row];
    if (col < 0 || col >= line->cols) return 0;
    *out_cell = line->cells[col];
    return 1;
}

ShellowVTermCursor shellow_vterm_get_cursor(ShellowVTerm *terminal) {
    VTermPos pos;
    vterm_state_get_cursorpos(vterm_obtain_state(terminal->vt), &pos);
    return (ShellowVTermCursor){ .row = pos.row, .col = pos.col };
}

bool shellow_vterm_is_altscreen_active(ShellowVTerm *terminal) {
    if (terminal == NULL) return false;
    return terminal->altscreen_active;
}

bool shellow_vterm_is_bracketed_paste_enabled(ShellowVTerm *terminal) {
    if (terminal == NULL) return false;
    return vterm_obtain_state(terminal->vt)->mode.bracketpaste;
}

int shellow_vterm_mouse_mode(ShellowVTerm *terminal) {
    if (terminal == NULL) return VTERM_PROP_MOUSE_NONE;
    return terminal->mouse_mode;
}

const char *shellow_vterm_title(ShellowVTerm *terminal) {
    if (terminal == NULL || terminal->title == NULL) return "";
    return terminal->title;
}

size_t shellow_vterm_mouse_move(ShellowVTerm *terminal, int row, int col, int modifiers, char *out, size_t out_len) {
    if (terminal == NULL || out == NULL || out_len == 0) return 0;
    vterm_mouse_move(terminal->vt, row, col, (VTermModifier)modifiers);
    return vterm_output_read(terminal->vt, out, out_len);
}

size_t shellow_vterm_mouse_button(ShellowVTerm *terminal, int row, int col, int button, bool pressed, int modifiers, char *out, size_t out_len) {
    if (terminal == NULL || out == NULL || out_len == 0) return 0;
    vterm_mouse_move(terminal->vt, row, col, (VTermModifier)modifiers);
    vterm_mouse_button(terminal->vt, button, pressed, (VTermModifier)modifiers);
    return vterm_output_read(terminal->vt, out, out_len);
}

void shellow_vterm_clear_scrollback(ShellowVTerm *terminal) {
    shellow_scrollback_clear(terminal);
}
