const std = @import("std");

pub const Error = error{
    InitFailed,
    ResizeFailed,
    WriteFailed,
    SnapshotFailed,
    MouseFailed,
    ClearScrollbackFailed,
};

pub const Size = struct {
    cols: u16,
    rows: u16,

    pub fn cellCount(self: Size) usize {
        return @as(usize, self.cols) * @as(usize, self.rows);
    }
};

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const Color = union(enum) {
    default,
    indexed: u8,
    rgb: Rgb,
};

pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    reverse: bool = false,
    strike: bool = false,
};

pub const Cell = struct {
    codepoint: u21 = ' ',
    width: u8 = 1,
    style: Style = .{},
};

pub const Cursor = struct {
    col: u16 = 0,
    row: u16 = 0,
    visible: bool = true,
    blink: bool = true,
    shape: CursorShape = .block,
};

pub const CursorShape = enum {
    block,
    underline,
    bar,
};

pub const MouseMode = enum {
    none,
    click,
    drag,
    move,
};

pub const MouseModifiers = struct {
    shift: bool = false,
    alt: bool = false,
    control: bool = false,
};

pub const MouseEvent = union(enum) {
    move: struct {
        row: u16,
        col: u16,
        modifiers: MouseModifiers = .{},
    },
    button: struct {
        row: u16,
        col: u16,
        button: u8,
        pressed: bool,
        modifiers: MouseModifiers = .{},
    },
};

pub const DirtyRows = struct {
    start: u16 = 0,
    end: u16 = 0,

    pub fn empty(self: DirtyRows) bool {
        return self.end <= self.start;
    }
};

pub const max_dirty_rects = 32;

pub const DirtyRect = struct {
    start_row: u16 = 0,
    end_row: u16 = 0,
    start_col: u16 = 0,
    end_col: u16 = 0,

    pub fn empty(self: DirtyRect) bool {
        return self.end_row <= self.start_row or self.end_col <= self.start_col;
    }
};

pub const DirtyRects = struct {
    items: [max_dirty_rects]DirtyRect = [_]DirtyRect{.{}} ** max_dirty_rects,
    len: usize = 0,
    overflow: bool = false,

    pub fn empty(self: DirtyRects) bool {
        return self.len == 0 and !self.overflow;
    }
};

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    generation: u64 = 0,
    size: Size,
    cells: []Cell,
    scrollback_cells: []Cell = &.{},
    scrollback_rows: usize = 0,
    dirty_rows: DirtyRows = .{},
    dirty_rects: DirtyRects = .{},
    scrollback_dirty: bool = false,
    cursor_dirty: bool = false,
    alternate_screen: bool = false,
    bracketed_paste: bool = false,
    mouse_mode: MouseMode = .none,
    cursor: Cursor,
    title: ?[]u8 = null,

    pub fn deinit(self: *Snapshot) void {
        if (self.title) |title| self.allocator.free(title);
        self.allocator.free(self.scrollback_cells);
        self.allocator.free(self.cells);
        self.* = undefined;
    }

    pub fn cellAt(self: Snapshot, row: u16, col: u16) ?Cell {
        if (row >= self.size.rows or col >= self.size.cols) return null;
        const idx = @as(usize, row) * @as(usize, self.size.cols) + @as(usize, col);
        if (idx >= self.cells.len) return null;
        return self.cells[idx];
    }

    pub fn scrollbackCellAt(self: Snapshot, row: usize, col: u16) ?Cell {
        if (row >= self.scrollback_rows or col >= self.size.cols) return null;
        const idx = row * @as(usize, self.size.cols) + @as(usize, col);
        if (idx >= self.scrollback_cells.len) return null;
        return self.scrollback_cells[idx];
    }
};

pub const Emulator = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        size: *const fn (*anyopaque) Size,
        write: *const fn (*anyopaque, []const u8) Error!usize,
        resize: *const fn (*anyopaque, Size) Error!void,
        snapshot: *const fn (*anyopaque, std.mem.Allocator) Error!Snapshot,
        mouse: *const fn (*anyopaque, std.mem.Allocator, MouseEvent) Error![]u8,
        clear_scrollback: *const fn (*anyopaque) Error!void,
        deinit: *const fn (*anyopaque) void,
    };

    pub fn size(self: Emulator) Size {
        return self.vtable.size(self.context);
    }

    pub fn write(self: Emulator, bytes: []const u8) Error!usize {
        return self.vtable.write(self.context, bytes);
    }

    pub fn resize(self: Emulator, new_size: Size) Error!void {
        return self.vtable.resize(self.context, new_size);
    }

    pub fn snapshot(self: Emulator, allocator: std.mem.Allocator) Error!Snapshot {
        return self.vtable.snapshot(self.context, allocator);
    }

    pub fn mouse(self: Emulator, allocator: std.mem.Allocator, event: MouseEvent) Error![]u8 {
        return self.vtable.mouse(self.context, allocator, event);
    }

    pub fn clearScrollback(self: Emulator) Error!void {
        return self.vtable.clear_scrollback(self.context);
    }

    pub fn deinit(self: Emulator) void {
        self.vtable.deinit(self.context);
    }
};

test "size reports stable cell count" {
    const size = Size{ .cols = 80, .rows = 24 };
    try std.testing.expectEqual(@as(usize, 1920), size.cellCount());
}

test "snapshot cell lookup bounds checks" {
    const cells = try std.testing.allocator.alloc(Cell, 4);
    defer std.testing.allocator.free(cells);
    @memset(cells, .{});

    const snapshot = Snapshot{
        .allocator = std.testing.allocator,
        .size = .{ .cols = 2, .rows = 2 },
        .cells = cells,
        .cursor = .{},
    };

    try std.testing.expect(snapshot.cellAt(1, 1) != null);
    try std.testing.expect(snapshot.cellAt(2, 0) == null);
    try std.testing.expect(snapshot.scrollbackCellAt(0, 0) == null);
}

test "snapshot cell lookup tolerates short backing slices" {
    const cells = try std.testing.allocator.alloc(Cell, 1);
    defer std.testing.allocator.free(cells);
    @memset(cells, .{});

    const snapshot = Snapshot{
        .allocator = std.testing.allocator,
        .size = .{ .cols = 2, .rows = 2 },
        .cells = cells,
        .cursor = .{},
    };

    try std.testing.expect(snapshot.cellAt(0, 0) != null);
    try std.testing.expect(snapshot.cellAt(1, 1) == null);
}
