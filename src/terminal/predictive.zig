const std = @import("std");
const terminal = @import("terminal.zig");

pub const max_diff_rects = terminal.max_dirty_rects;

pub const ScreenDiff = struct {
    dirty_rects: terminal.DirtyRects = .{},
    cell_mismatches: usize = 0,
    cursor_changed: bool = false,
    mode_changed: bool = false,
    size_changed: bool = false,
    scrollback_changed: bool = false,

    pub fn empty(self: ScreenDiff) bool {
        return self.cell_mismatches == 0 and
            !self.cursor_changed and
            !self.mode_changed and
            !self.size_changed and
            !self.scrollback_changed;
    }

    pub fn structural(self: ScreenDiff) bool {
        return self.size_changed or self.scrollback_changed or self.mode_changed;
    }
};

pub const DualState = struct {
    allocator: std.mem.Allocator,
    real: ?terminal.Snapshot = null,
    predicted: ?terminal.Snapshot = null,

    pub fn init(allocator: std.mem.Allocator) DualState {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DualState) void {
        if (self.real) |*real| real.deinit();
        if (self.predicted) |*predicted| predicted.deinit();
        self.* = .{ .allocator = self.allocator };
    }

    pub fn syncReal(self: *DualState, real_snapshot: terminal.Snapshot) !ScreenDiff {
        const next_real = try cloneSnapshot(self.allocator, real_snapshot);
        errdefer deinitSnapshot(&next_real);

        if (self.real) |*old_real| old_real.deinit();
        self.real = next_real;

        if (self.predicted == null) {
            self.predicted = try cloneSnapshot(self.allocator, real_snapshot);
            return .{};
        }

        const diff = diffSnapshots(real_snapshot, self.predicted.?);
        if (!diff.empty()) {
            try self.patchPredictedFromReal(diff);
        }
        return diff;
    }

    pub fn realSnapshot(self: *const DualState) ?*const terminal.Snapshot {
        return if (self.real) |*real| real else null;
    }

    pub fn predictedSnapshot(self: *const DualState) ?*const terminal.Snapshot {
        return if (self.predicted) |*predicted| predicted else null;
    }

    pub fn resetPredictedToReal(self: *DualState) !void {
        const real = self.real orelse return;
        const next_predicted = try cloneSnapshot(self.allocator, real);
        if (self.predicted) |*old_predicted| old_predicted.deinit();
        self.predicted = next_predicted;
    }

    pub fn feedLocalInput(self: *DualState, bytes: []const u8) void {
        if (self.predicted) |*predicted| {
            applyLocalInput(predicted, bytes);
        }
    }

    fn patchPredictedFromReal(self: *DualState, diff: ScreenDiff) !void {
        if (diff.structural() or diff.dirty_rects.overflow) {
            try self.resetPredictedToReal();
            return;
        }
        const real = self.real orelse return;
        const predicted = if (self.predicted) |*predicted_snapshot| predicted_snapshot else return;

        for (diff.dirty_rects.items[0..diff.dirty_rects.len]) |rect| {
            var row = rect.start_row;
            while (row < rect.end_row) : (row += 1) {
                var col = rect.start_col;
                while (col < rect.end_col) : (col += 1) {
                    const idx = @as(usize, row) * @as(usize, real.size.cols) + @as(usize, col);
                    predicted.cells[idx] = real.cells[idx];
                }
            }
        }
        predicted.cursor = real.cursor;
        predicted.generation = real.generation;
        predicted.dirty_rows = diffRows(diff.dirty_rects, real.size.rows);
        predicted.dirty_rects = diff.dirty_rects;
        predicted.cursor_dirty = diff.cursor_changed;
    }
};

pub fn cloneSnapshot(allocator: std.mem.Allocator, snapshot: terminal.Snapshot) !terminal.Snapshot {
    const cells = try allocator.dupe(terminal.Cell, snapshot.cells);
    errdefer allocator.free(cells);

    const scrollback_cells = try allocator.dupe(terminal.Cell, snapshot.scrollback_cells);
    errdefer allocator.free(scrollback_cells);

    const title = if (snapshot.title) |title_bytes| try allocator.dupe(u8, title_bytes) else null;
    errdefer if (title) |title_bytes| allocator.free(title_bytes);

    return .{
        .allocator = allocator,
        .generation = snapshot.generation,
        .size = snapshot.size,
        .cells = cells,
        .scrollback_cells = scrollback_cells,
        .scrollback_rows = snapshot.scrollback_rows,
        .dirty_rows = snapshot.dirty_rows,
        .dirty_rects = snapshot.dirty_rects,
        .scrollback_dirty = snapshot.scrollback_dirty,
        .cursor_dirty = snapshot.cursor_dirty,
        .alternate_screen = snapshot.alternate_screen,
        .bracketed_paste = snapshot.bracketed_paste,
        .mouse_mode = snapshot.mouse_mode,
        .cursor = snapshot.cursor,
        .title = title,
    };
}

pub fn diffSnapshots(real: terminal.Snapshot, predicted: terminal.Snapshot) ScreenDiff {
    var diff: ScreenDiff = .{};
    if (real.size.cols != predicted.size.cols or real.size.rows != predicted.size.rows) {
        diff.size_changed = true;
        return diff;
    }
    if (real.scrollback_rows != predicted.scrollback_rows or real.scrollback_cells.len != predicted.scrollback_cells.len) {
        diff.scrollback_changed = true;
        return diff;
    }
    diff.mode_changed = real.alternate_screen != predicted.alternate_screen or
        real.bracketed_paste != predicted.bracketed_paste or
        real.mouse_mode != predicted.mouse_mode;
    diff.cursor_changed = !std.meta.eql(real.cursor, predicted.cursor);

    for (real.scrollback_cells, predicted.scrollback_cells) |real_cell, predicted_cell| {
        if (!std.meta.eql(real_cell, predicted_cell)) {
            diff.scrollback_changed = true;
            return diff;
        }
    }

    var row: u16 = 0;
    while (row < real.size.rows) : (row += 1) {
        var col: u16 = 0;
        while (col < real.size.cols) : (col += 1) {
            const idx = @as(usize, row) * @as(usize, real.size.cols) + @as(usize, col);
            if (!std.meta.eql(real.cells[idx], predicted.cells[idx])) {
                diff.cell_mismatches += 1;
                appendDiffRect(&diff.dirty_rects, .{
                    .start_row = row,
                    .end_row = row + 1,
                    .start_col = col,
                    .end_col = col + 1,
                });
            }
        }
    }
    return diff;
}

fn applyLocalInput(snapshot: *terminal.Snapshot, bytes: []const u8) void {
    if (snapshot.alternate_screen or snapshot.bracketed_paste or snapshot.mouse_mode != .none) return;
    for (bytes) |byte| {
        switch (byte) {
            0x20...0x7e => putAscii(snapshot, byte),
            0x7f, 0x08 => backspace(snapshot),
            '\r', '\n' => return,
            else => return,
        }
    }
}

fn putAscii(snapshot: *terminal.Snapshot, byte: u8) void {
    if (snapshot.cursor.row >= snapshot.size.rows or snapshot.cursor.col >= snapshot.size.cols) return;
    const idx = @as(usize, snapshot.cursor.row) * @as(usize, snapshot.size.cols) + @as(usize, snapshot.cursor.col);
    snapshot.cells[idx] = .{ .codepoint = byte, .width = 1, .style = .{} };
    appendDiffRect(&snapshot.dirty_rects, .{
        .start_row = snapshot.cursor.row,
        .end_row = snapshot.cursor.row + 1,
        .start_col = snapshot.cursor.col,
        .end_col = snapshot.cursor.col + 1,
    });
    snapshot.dirty_rows = mergeRows(snapshot.dirty_rows, .{ .start = snapshot.cursor.row, .end = snapshot.cursor.row + 1 });
    snapshot.cursor.col += 1;
    snapshot.cursor_dirty = true;
}

fn backspace(snapshot: *terminal.Snapshot) void {
    if (snapshot.cursor.col == 0 or snapshot.cursor.row >= snapshot.size.rows) return;
    snapshot.cursor.col -= 1;
    const idx = @as(usize, snapshot.cursor.row) * @as(usize, snapshot.size.cols) + @as(usize, snapshot.cursor.col);
    snapshot.cells[idx] = .{};
    appendDiffRect(&snapshot.dirty_rects, .{
        .start_row = snapshot.cursor.row,
        .end_row = snapshot.cursor.row + 1,
        .start_col = snapshot.cursor.col,
        .end_col = snapshot.cursor.col + 1,
    });
    snapshot.dirty_rows = mergeRows(snapshot.dirty_rows, .{ .start = snapshot.cursor.row, .end = snapshot.cursor.row + 1 });
    snapshot.cursor_dirty = true;
}

fn appendDiffRect(rects: *terminal.DirtyRects, rect: terminal.DirtyRect) void {
    if (rect.empty() or rects.overflow) return;
    for (rects.items[0..rects.len]) |*existing| {
        if (rectsOverlapOrTouch(existing.*, rect)) {
            existing.* = mergeRects(existing.*, rect);
            return;
        }
    }
    if (rects.len >= rects.items.len) {
        rects.overflow = true;
        return;
    }
    rects.items[rects.len] = rect;
    rects.len += 1;
}

fn rectsOverlapOrTouch(a: terminal.DirtyRect, b: terminal.DirtyRect) bool {
    if (a.end_row < b.start_row or b.end_row < a.start_row) return false;
    if (a.end_col < b.start_col or b.end_col < a.start_col) return false;
    return true;
}

fn mergeRects(a: terminal.DirtyRect, b: terminal.DirtyRect) terminal.DirtyRect {
    return .{
        .start_row = @min(a.start_row, b.start_row),
        .end_row = @max(a.end_row, b.end_row),
        .start_col = @min(a.start_col, b.start_col),
        .end_col = @max(a.end_col, b.end_col),
    };
}

fn mergeRows(a: terminal.DirtyRows, b: terminal.DirtyRows) terminal.DirtyRows {
    if (a.empty()) return b;
    if (b.empty()) return a;
    return .{ .start = @min(a.start, b.start), .end = @max(a.end, b.end) };
}

fn diffRows(rects: terminal.DirtyRects, rows: u16) terminal.DirtyRows {
    if (rects.overflow) return .{ .start = 0, .end = rows };
    var out: terminal.DirtyRows = .{};
    for (rects.items[0..rects.len]) |rect| {
        out = mergeRows(out, .{ .start = rect.start_row, .end = rect.end_row });
    }
    return out;
}

fn deinitSnapshot(snapshot: *const terminal.Snapshot) void {
    var mutable = snapshot.*;
    mutable.deinit();
}

fn testSnapshot(allocator: std.mem.Allocator, text: []const u8) !terminal.Snapshot {
    const cells = try allocator.alloc(terminal.Cell, 8);
    errdefer allocator.free(cells);
    @memset(cells, .{});
    for (text, 0..) |byte, i| {
        if (i >= cells.len) break;
        cells[i] = .{ .codepoint = byte, .width = 1 };
    }
    return .{
        .allocator = allocator,
        .size = .{ .cols = 8, .rows = 1 },
        .cells = cells,
        .cursor = .{ .col = @intCast(@min(text.len, 8)), .row = 0 },
    };
}

test "diff snapshots reports cell and cursor changes" {
    var real = try testSnapshot(std.testing.allocator, "abc");
    defer real.deinit();
    var predicted = try testSnapshot(std.testing.allocator, "axc");
    defer predicted.deinit();

    const diff = diffSnapshots(real, predicted);
    try std.testing.expectEqual(@as(usize, 1), diff.cell_mismatches);
    try std.testing.expect(!diff.dirty_rects.empty());
    try std.testing.expect(!diff.empty());
}

test "dual state rolls prediction forward and patches from real" {
    var real = try testSnapshot(std.testing.allocator, "ab");
    defer real.deinit();

    var state = DualState.init(std.testing.allocator);
    defer state.deinit();
    _ = try state.syncReal(real);
    state.feedLocalInput("c");
    try std.testing.expectEqual(@as(u21, 'c'), state.predictedSnapshot().?.cellAt(0, 2).?.codepoint);

    var confirmed = try testSnapshot(std.testing.allocator, "abc");
    defer confirmed.deinit();
    const diff = try state.syncReal(confirmed);
    try std.testing.expect(diff.empty());
    try std.testing.expectEqual(@as(u21, 'c'), state.realSnapshot().?.cellAt(0, 2).?.codepoint);
}

test "dual state resets structural differences" {
    var real = try testSnapshot(std.testing.allocator, "ab");
    defer real.deinit();

    var state = DualState.init(std.testing.allocator);
    defer state.deinit();
    _ = try state.syncReal(real);

    var changed = try testSnapshot(std.testing.allocator, "ab");
    defer changed.deinit();
    changed.alternate_screen = true;

    const diff = try state.syncReal(changed);
    try std.testing.expect(diff.mode_changed);
    try std.testing.expect(state.predictedSnapshot().?.alternate_screen);
}
