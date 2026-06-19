const std = @import("std");
const terminal = @import("../../contracts/terminal_emulator.zig");

const c = @cImport({
    @cInclude("libvterm_shim.h");
});

pub const Backend = struct {
    allocator: std.mem.Allocator,

    pub fn create(self: *Backend, initial_size: terminal.Size) terminal.Error!terminal.Emulator {
        const context = self.allocator.create(Context) catch return terminal.Error.InitFailed;
        errdefer self.allocator.destroy(context);

        const vt = c.shellow_vterm_new(initial_size.rows, initial_size.cols) orelse return terminal.Error.InitFailed;
        errdefer c.shellow_vterm_free(vt);

        context.* = .{
            .allocator = self.allocator,
            .vt = vt,
            .size = initial_size,
        };

        return .{
            .context = context,
            .vtable = &emulator_vtable,
        };
    }
};

const Context = struct {
    allocator: std.mem.Allocator,
    vt: *c.ShellowVTerm,
    size: terminal.Size,
};

fn size(context: *anyopaque) terminal.Size {
    const self: *Context = @ptrCast(@alignCast(context));
    return self.size;
}

fn write(context: *anyopaque, bytes: []const u8) terminal.Error!usize {
    const self: *Context = @ptrCast(@alignCast(context));
    const written = c.shellow_vterm_write(self.vt, @ptrCast(bytes.ptr), bytes.len);
    if (written == 0 and bytes.len != 0) return terminal.Error.WriteFailed;
    return written;
}

fn resize(context: *anyopaque, new_size: terminal.Size) terminal.Error!void {
    const self: *Context = @ptrCast(@alignCast(context));
    if (new_size.cols == 0 or new_size.rows == 0) return terminal.Error.ResizeFailed;
    c.shellow_vterm_resize(self.vt, new_size.rows, new_size.cols);
    self.size = new_size;
}

fn snapshot(context: *anyopaque, allocator: std.mem.Allocator) terminal.Error!terminal.Snapshot {
    const self: *Context = @ptrCast(@alignCast(context));
    const cells = allocator.alloc(terminal.Cell, self.size.cellCount()) catch return terminal.Error.SnapshotFailed;
    errdefer allocator.free(cells);

    const alternate_screen = c.shellow_vterm_is_altscreen_active(self.vt);
    const scrollback_rows = if (alternate_screen) 0 else scrollbackRows(self.vt);
    const scrollback_cells = allocator.alloc(terminal.Cell, scrollback_rows * @as(usize, self.size.cols)) catch return terminal.Error.SnapshotFailed;
    errdefer allocator.free(scrollback_cells);

    const cursor_pos = c.shellow_vterm_get_cursor(self.vt);
    const dirty = c.shellow_vterm_dirty_rows(self.vt);
    const raw_title = std.mem.span(c.shellow_vterm_title(self.vt));
    const title = allocator.dupe(u8, raw_title) catch return terminal.Error.SnapshotFailed;
    errdefer allocator.free(title);

    for (0..scrollback_rows) |row| {
        for (0..self.size.cols) |col| {
            const idx = row * @as(usize, self.size.cols) + col;
            scrollback_cells[idx] = readScrollbackCell(self.vt, @intCast(row), @intCast(col));
        }
    }

    for (0..self.size.rows) |row| {
        for (0..self.size.cols) |col| {
            const idx = row * @as(usize, self.size.cols) + col;
            cells[idx] = readCell(self.vt, @intCast(row), @intCast(col));
        }
    }

    const snapshot_out = terminal.Snapshot{
        .allocator = allocator,
        .size = self.size,
        .cells = cells,
        .scrollback_cells = scrollback_cells,
        .scrollback_rows = scrollback_rows,
        .dirty_rows = dirtyRows(dirty, self.size.rows),
        .dirty_rects = dirtyRects(dirty, self.size.rows, self.size.cols),
        .scrollback_dirty = dirty.scrollback_dirty,
        .cursor_dirty = dirty.cursor_dirty,
        .alternate_screen = alternate_screen,
        .bracketed_paste = c.shellow_vterm_is_bracketed_paste_enabled(self.vt),
        .mouse_mode = convertMouseMode(c.shellow_vterm_mouse_mode(self.vt)),
        .cursor = .{
            .row = clampCursor(cursor_pos.row, self.size.rows),
            .col = clampCursor(cursor_pos.col, self.size.cols),
            .visible = cursor_pos.visible,
            .blink = cursor_pos.blink,
            .shape = convertCursorShape(cursor_pos.shape),
        },
        .title = title,
    };
    c.shellow_vterm_clear_dirty(self.vt);
    return snapshot_out;
}

fn convertCursorShape(shape: u8) terminal.CursorShape {
    return switch (shape) {
        c.SHELLOW_VTERM_CURSOR_UNDERLINE => .underline,
        c.SHELLOW_VTERM_CURSOR_BAR => .bar,
        else => .block,
    };
}

fn scrollbackRows(vt: *c.ShellowVTerm) usize {
    const rows = c.shellow_vterm_scrollback_rows(vt);
    if (rows <= 0) return 0;
    return std.math.cast(usize, rows) orelse 0;
}

fn deinit(context: *anyopaque) void {
    const self: *Context = @ptrCast(@alignCast(context));
    const allocator = self.allocator;
    c.shellow_vterm_free(self.vt);
    allocator.destroy(self);
}

fn mouse(context: *anyopaque, allocator: std.mem.Allocator, event: terminal.MouseEvent) terminal.Error![]u8 {
    const self: *Context = @ptrCast(@alignCast(context));
    var buffer: [128]u8 = undefined;
    const len = switch (event) {
        .move => |move| c.shellow_vterm_mouse_move(
            self.vt,
            move.row,
            move.col,
            mouseModifiers(move.modifiers),
            &buffer,
            buffer.len,
        ),
        .button => |button| c.shellow_vterm_mouse_button(
            self.vt,
            button.row,
            button.col,
            button.button,
            button.pressed,
            mouseModifiers(button.modifiers),
            &buffer,
            buffer.len,
        ),
    };
    return allocator.dupe(u8, buffer[0..len]) catch return terminal.Error.MouseFailed;
}

fn clearScrollback(context: *anyopaque) terminal.Error!void {
    const self: *Context = @ptrCast(@alignCast(context));
    c.shellow_vterm_clear_scrollback(self.vt);
}

const emulator_vtable: terminal.Emulator.VTable = .{
    .size = size,
    .write = write,
    .resize = resize,
    .snapshot = snapshot,
    .mouse = mouse,
    .clear_scrollback = clearScrollback,
    .deinit = deinit,
};

fn readCell(vt: *c.ShellowVTerm, row: c_int, col: c_int) terminal.Cell {
    var raw: c.ShellowVTermCell = undefined;
    if (c.shellow_vterm_get_cell(vt, row, col, &raw) == 0) return .{};

    return convertCell(raw);
}

fn readScrollbackCell(vt: *c.ShellowVTerm, row: c_int, col: c_int) terminal.Cell {
    var raw: c.ShellowVTermCell = undefined;
    if (c.shellow_vterm_get_scrollback_cell(vt, row, col, &raw) == 0) return .{};

    return convertCell(raw);
}

fn convertCell(raw: c.ShellowVTermCell) terminal.Cell {
    return .{
        .codepoint = firstCodepoint(raw.codepoint),
        .width = raw.width,
        .style = .{
            .fg = convertColor(raw.fg),
            .bg = convertColor(raw.bg),
            .bold = raw.bold,
            .italic = raw.italic,
            .underline = raw.underline,
            .blink = raw.blink,
            .reverse = raw.reverse,
            .strike = raw.strike,
        },
    };
}

fn firstCodepoint(raw: u32) u21 {
    if (raw == 0) return ' ';
    return std.math.cast(u21, raw) orelse ' ';
}

fn convertColor(raw: c.ShellowVTermColor) terminal.Color {
    return switch (raw.kind) {
        1 => .{ .indexed = raw.index },
        2 => .{ .rgb = .{ .r = raw.r, .g = raw.g, .b = raw.b } },
        else => .default,
    };
}

fn clampCursor(value: c_int, limit: u16) u16 {
    if (value <= 0) return 0;
    const casted: u16 = std.math.cast(u16, value) orelse return limit -| 1;
    if (casted >= limit) return limit -| 1;
    return casted;
}

fn convertMouseMode(raw: c_int) terminal.MouseMode {
    return switch (raw) {
        1 => .click,
        2 => .drag,
        3 => .move,
        else => .none,
    };
}

fn dirtyRows(raw: c.ShellowVTermDirtyRows, rows: u16) terminal.DirtyRows {
    if (raw.end_row <= raw.start_row or rows == 0) return .{};
    const start = clampDirtyRow(raw.start_row, rows);
    const end = clampDirtyRow(raw.end_row, rows);
    if (end <= start) return .{};
    return .{ .start = start, .end = end };
}

fn dirtyRects(raw: c.ShellowVTermDirtyRows, rows: u16, cols: u16) terminal.DirtyRects {
    var out: terminal.DirtyRects = .{
        .overflow = raw.overflow,
    };
    if (rows == 0 or cols == 0) return out;

    const raw_len: usize = if (raw.len <= 0) 0 else @intCast(raw.len);
    const len = @min(raw_len, out.items.len);
    for (0..len) |i| {
        const rect = raw.rects[i];
        const start_row = clampDirtyRow(rect.start_row, rows);
        const end_row = clampDirtyRow(rect.end_row, rows);
        const start_col = clampDirtyCol(rect.start_col, cols);
        const end_col = clampDirtyCol(rect.end_col, cols);
        if (end_row <= start_row or end_col <= start_col) continue;
        out.items[out.len] = .{
            .start_row = start_row,
            .end_row = end_row,
            .start_col = start_col,
            .end_col = end_col,
        };
        out.len += 1;
    }
    if (raw_len > out.items.len) out.overflow = true;
    return out;
}

fn clampDirtyRow(value: c_int, limit: u16) u16 {
    if (value <= 0) return 0;
    const casted: u16 = std.math.cast(u16, value) orelse return limit;
    return @min(casted, limit);
}

fn clampDirtyCol(value: c_int, limit: u16) u16 {
    if (value <= 0) return 0;
    const casted: u16 = std.math.cast(u16, value) orelse return limit;
    return @min(casted, limit);
}

fn mouseModifiers(modifiers: terminal.MouseModifiers) c_int {
    var out: c_int = 0;
    if (modifiers.shift) out |= 0x01;
    if (modifiers.alt) out |= 0x02;
    if (modifiers.control) out |= 0x04;
    return out;
}

test "libvterm backend writes text into a snapshot" {
    var backend = Backend{ .allocator = std.testing.allocator };
    const emulator = try backend.create(.{ .cols = 8, .rows = 2 });
    defer emulator.deinit();

    try std.testing.expectEqual(@as(usize, 5), try emulator.write("hello"));

    var shot = try emulator.snapshot(std.testing.allocator);
    defer shot.deinit();

    try std.testing.expectEqual(@as(u21, 'h'), shot.cellAt(0, 0).?.codepoint);
    try std.testing.expectEqual(@as(u21, 'o'), shot.cellAt(0, 4).?.codepoint);
}

test "libvterm backend exposes OSC title in snapshot" {
    var backend = Backend{ .allocator = std.testing.allocator };
    const emulator = try backend.create(.{ .cols = 8, .rows = 2 });
    defer emulator.deinit();

    _ = try emulator.write("\x1b]0;shellow-title\x07");

    var shot = try emulator.snapshot(std.testing.allocator);
    defer shot.deinit();

    try std.testing.expectEqualStrings("shellow-title", shot.title orelse "");
}

test "libvterm backend preserves unicode codepoints" {
    var backend = Backend{ .allocator = std.testing.allocator };
    const emulator = try backend.create(.{ .cols = 8, .rows = 2 });
    defer emulator.deinit();

    _ = try emulator.write("中文");

    var shot = try emulator.snapshot(std.testing.allocator);
    defer shot.deinit();

    try std.testing.expectEqual(@as(u21, '中'), shot.cellAt(0, 0).?.codepoint);
    try std.testing.expect(shot.cellAt(0, 0).?.width >= 1);
    try std.testing.expectEqual(@as(u21, '文'), shot.cellAt(0, 2).?.codepoint);
}

test "libvterm backend preserves ansi colors" {
    var backend = Backend{ .allocator = std.testing.allocator };
    const emulator = try backend.create(.{ .cols = 8, .rows = 2 });
    defer emulator.deinit();

    _ = try emulator.write("\x1b[31mR");

    var shot = try emulator.snapshot(std.testing.allocator);
    defer shot.deinit();

    try std.testing.expectEqual(@as(u21, 'R'), shot.cellAt(0, 0).?.codepoint);
    try std.testing.expectEqual(terminal.Color{ .indexed = 1 }, shot.cellAt(0, 0).?.style.fg);
}

test "libvterm backend captures scrollback lines" {
    var backend = Backend{ .allocator = std.testing.allocator };
    const emulator = try backend.create(.{ .cols = 8, .rows = 2 });
    defer emulator.deinit();

    _ = try emulator.write("one\r\ntwo\r\nthree\r\n");

    var shot = try emulator.snapshot(std.testing.allocator);
    defer shot.deinit();

    try std.testing.expect(shot.scrollback_rows > 0);
    try std.testing.expectEqual(@as(u21, 'o'), shot.scrollbackCellAt(0, 0).?.codepoint);
}

test "libvterm backend keeps scrollback across resize" {
    var backend = Backend{ .allocator = std.testing.allocator };
    const emulator = try backend.create(.{ .cols = 8, .rows = 2 });
    defer emulator.deinit();

    _ = try emulator.write("one\r\ntwo\r\nthree\r\n");

    var before = try emulator.snapshot(std.testing.allocator);
    const before_rows = before.scrollback_rows;
    before.deinit();

    try emulator.resize(.{ .cols = 12, .rows = 3 });

    var after = try emulator.snapshot(std.testing.allocator);
    defer after.deinit();

    try std.testing.expect(before_rows > 0);
    try std.testing.expect(after.scrollback_rows >= before_rows);
}

test "libvterm backend clears scrollback" {
    var backend = Backend{ .allocator = std.testing.allocator };
    const emulator = try backend.create(.{ .cols = 8, .rows = 2 });
    defer emulator.deinit();

    _ = try emulator.write("one\r\ntwo\r\nthree\r\n");

    var before = try emulator.snapshot(std.testing.allocator);
    try std.testing.expect(before.scrollback_rows > 0);
    before.deinit();

    try emulator.clearScrollback();

    var after = try emulator.snapshot(std.testing.allocator);
    defer after.deinit();
    try std.testing.expectEqual(@as(usize, 0), after.scrollback_rows);
}

test "libvterm backend exposes alternate screen state without primary scrollback" {
    var backend = Backend{ .allocator = std.testing.allocator };
    const emulator = try backend.create(.{ .cols = 8, .rows = 2 });
    defer emulator.deinit();

    _ = try emulator.write("one\r\ntwo\r\nthree\r\n");

    var primary = try emulator.snapshot(std.testing.allocator);
    const primary_scrollback_rows = primary.scrollback_rows;
    try std.testing.expect(!primary.alternate_screen);
    try std.testing.expect(primary_scrollback_rows > 0);
    primary.deinit();

    _ = try emulator.write("\x1b[?1049hALT");

    var alt = try emulator.snapshot(std.testing.allocator);
    defer alt.deinit();
    try std.testing.expect(alt.alternate_screen);
    try std.testing.expectEqual(@as(usize, 0), alt.scrollback_rows);

    _ = try emulator.write("\x1b[?1049l");

    var restored = try emulator.snapshot(std.testing.allocator);
    defer restored.deinit();
    try std.testing.expect(!restored.alternate_screen);
    try std.testing.expect(restored.scrollback_rows >= primary_scrollback_rows);
}

test "libvterm backend exposes remote cursor visibility shape and blink" {
    var backend = Backend{ .allocator = std.testing.allocator };
    const emulator = try backend.create(.{ .cols = 8, .rows = 2 });
    defer emulator.deinit();

    _ = try emulator.write("\x1b[?25l");
    var hidden = try emulator.snapshot(std.testing.allocator);
    try std.testing.expect(!hidden.cursor.visible);
    hidden.deinit();

    _ = try emulator.write("\x1b[?25h\x1b[3 q");
    var underline = try emulator.snapshot(std.testing.allocator);
    try std.testing.expect(underline.cursor.visible);
    try std.testing.expect(underline.cursor.blink);
    try std.testing.expectEqual(terminal.CursorShape.underline, underline.cursor.shape);
    underline.deinit();

    _ = try emulator.write("\x1b[6 q");
    var bar = try emulator.snapshot(std.testing.allocator);
    try std.testing.expect(!bar.cursor.blink);
    try std.testing.expectEqual(terminal.CursorShape.bar, bar.cursor.shape);
    bar.deinit();

    _ = try emulator.write("\x1b[2 q");
    var block = try emulator.snapshot(std.testing.allocator);
    defer block.deinit();
    try std.testing.expect(!block.cursor.blink);
    try std.testing.expectEqual(terminal.CursorShape.block, block.cursor.shape);
}

test "libvterm backend exposes bracketed paste mode" {
    var backend = Backend{ .allocator = std.testing.allocator };
    const emulator = try backend.create(.{ .cols = 8, .rows = 2 });
    defer emulator.deinit();

    var initial = try emulator.snapshot(std.testing.allocator);
    try std.testing.expect(!initial.bracketed_paste);
    initial.deinit();

    _ = try emulator.write("\x1b[?2004h");

    var enabled = try emulator.snapshot(std.testing.allocator);
    try std.testing.expect(enabled.bracketed_paste);
    enabled.deinit();

    _ = try emulator.write("\x1b[?2004l");

    var disabled = try emulator.snapshot(std.testing.allocator);
    defer disabled.deinit();
    try std.testing.expect(!disabled.bracketed_paste);
}

test "libvterm backend exposes dirty rows" {
    var backend = Backend{ .allocator = std.testing.allocator };
    const emulator = try backend.create(.{ .cols = 8, .rows = 3 });
    defer emulator.deinit();

    var initial = try emulator.snapshot(std.testing.allocator);
    initial.deinit();

    _ = try emulator.write("abc");

    var written = try emulator.snapshot(std.testing.allocator);
    try std.testing.expect(!written.dirty_rows.empty());
    try std.testing.expect(!written.dirty_rects.empty());
    try std.testing.expect(written.dirty_rows.start <= 0);
    try std.testing.expect(written.dirty_rows.end >= 1);
    try std.testing.expectEqual(@as(u16, 0), written.dirty_rects.items[0].start_row);
    try std.testing.expect(written.dirty_rects.items[0].end_col > 0);
    try std.testing.expect(!written.scrollback_dirty);
    try std.testing.expect(written.cursor_dirty);
    written.deinit();

    var clean = try emulator.snapshot(std.testing.allocator);
    defer clean.deinit();
    try std.testing.expect(clean.dirty_rows.empty());
    try std.testing.expect(clean.dirty_rects.empty());
    try std.testing.expect(!clean.scrollback_dirty);
    try std.testing.expect(!clean.cursor_dirty);
}

test "libvterm backend marks scrollback dirty" {
    var backend = Backend{ .allocator = std.testing.allocator };
    const emulator = try backend.create(.{ .cols = 8, .rows = 2 });
    defer emulator.deinit();

    var initial = try emulator.snapshot(std.testing.allocator);
    initial.deinit();

    _ = try emulator.write("one\r\ntwo\r\nthree\r\n");

    var shot = try emulator.snapshot(std.testing.allocator);
    defer shot.deinit();
    try std.testing.expect(shot.scrollback_rows > 0);
    try std.testing.expect(shot.scrollback_dirty);
}

test "libvterm backend reports SGR mouse bytes" {
    var backend = Backend{ .allocator = std.testing.allocator };
    const emulator = try backend.create(.{ .cols = 8, .rows = 2 });
    defer emulator.deinit();

    _ = try emulator.write("\x1b[?1000h\x1b[?1006h");

    var enabled = try emulator.snapshot(std.testing.allocator);
    try std.testing.expectEqual(terminal.MouseMode.click, enabled.mouse_mode);
    enabled.deinit();

    const press = try emulator.mouse(std.testing.allocator, .{ .button = .{
        .row = 1,
        .col = 2,
        .button = 1,
        .pressed = true,
    } });
    defer std.testing.allocator.free(press);
    try std.testing.expectEqualStrings("\x1b[<0;3;2M", press);

    const release = try emulator.mouse(std.testing.allocator, .{ .button = .{
        .row = 1,
        .col = 2,
        .button = 1,
        .pressed = false,
    } });
    defer std.testing.allocator.free(release);
    try std.testing.expectEqualStrings("\x1b[<0;3;2m", release);

    const middle = try emulator.mouse(std.testing.allocator, .{ .button = .{
        .row = 1,
        .col = 2,
        .button = 2,
        .pressed = true,
    } });
    defer std.testing.allocator.free(middle);
    try std.testing.expectEqualStrings("\x1b[<1;3;2M", middle);

    const right_with_modifiers = try emulator.mouse(std.testing.allocator, .{ .button = .{
        .row = 1,
        .col = 2,
        .button = 3,
        .pressed = true,
        .modifiers = .{ .shift = true, .alt = true, .control = true },
    } });
    defer std.testing.allocator.free(right_with_modifiers);
    try std.testing.expectEqualStrings("\x1b[<30;3;2M", right_with_modifiers);

    _ = try emulator.write("\x1b[?1000l");

    var disabled = try emulator.snapshot(std.testing.allocator);
    defer disabled.deinit();
    try std.testing.expectEqual(terminal.MouseMode.none, disabled.mouse_mode);
}
