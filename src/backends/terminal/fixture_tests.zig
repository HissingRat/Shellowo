const std = @import("std");
const terminal = @import("../../contracts/terminal_emulator.zig");
const libvterm = @import("libvterm.zig");

const ExpectedCell = struct {
    row: u16,
    col: u16,
    codepoint: u21,
    width: ?u8 = null,
    fg: ?terminal.Color = null,
};

const Fixture = struct {
    name: []const u8,
    initial_size: terminal.Size,
    chunks: []const []const u8,
    resize_to: ?terminal.Size = null,
    cells: []const ExpectedCell = &.{},
    cursor: ?terminal.Cursor = null,
    alternate_screen: ?bool = null,
    bracketed_paste: ?bool = null,
    minimum_scrollback_rows: usize = 0,
};

const fixtures = [_]Fixture{
    .{
        .name = "split ansi sequence",
        .initial_size = .{ .cols = 8, .rows = 2 },
        .chunks = &.{ "\x1b[3", "1mR" },
        .cells = &.{.{ .row = 0, .col = 0, .codepoint = 'R', .fg = .{ .indexed = 1 } }},
    },
    .{
        .name = "utf8 wide cells",
        .initial_size = .{ .cols = 8, .rows = 2 },
        .chunks = &.{"中文"},
        .cells = &.{
            .{ .row = 0, .col = 0, .codepoint = '中', .width = 2 },
            .{ .row = 0, .col = 2, .codepoint = '文', .width = 2 },
        },
    },
    .{
        .name = "cursor visibility and position",
        .initial_size = .{ .cols = 8, .rows = 3 },
        .chunks = &.{ "\x1b[2;4H", "\x1b[?25h" },
        .cursor = .{ .row = 1, .col = 3, .visible = true },
    },
    .{
        .name = "alternate screen",
        .initial_size = .{ .cols = 8, .rows = 2 },
        .chunks = &.{ "\x1b[?1049h", "ALT" },
        .cells = &.{.{ .row = 0, .col = 0, .codepoint = 'A' }},
        .alternate_screen = true,
    },
    .{
        .name = "bracketed paste mode",
        .initial_size = .{ .cols = 8, .rows = 2 },
        .chunks = &.{"\x1b[?2004h"},
        .bracketed_paste = true,
    },
    .{
        .name = "scrollback and resize",
        .initial_size = .{ .cols = 8, .rows = 2 },
        .chunks = &.{"one\r\ntwo\r\nthree\r\n"},
        .resize_to = .{ .cols = 12, .rows = 3 },
        .minimum_scrollback_rows = 1,
    },
};

test "terminal fixtures" {
    for (fixtures) |fixture| {
        var backend = libvterm.Backend{ .allocator = std.testing.allocator };
        const emulator = try backend.create(fixture.initial_size);
        defer emulator.deinit();

        for (fixture.chunks) |chunk| {
            try std.testing.expectEqual(chunk.len, try emulator.write(chunk));
        }
        if (fixture.resize_to) |size| try emulator.resize(size);

        var snapshot = try emulator.snapshot(std.testing.allocator);
        defer snapshot.deinit();
        for (fixture.cells) |expected| {
            const cell = snapshot.cellAt(expected.row, expected.col) orelse {
                std.debug.print("fixture '{s}' missing cell {d},{d}\n", .{ fixture.name, expected.row, expected.col });
                return error.TestExpectedEqual;
            };
            try std.testing.expectEqual(expected.codepoint, cell.codepoint);
            if (expected.width) |width| try std.testing.expectEqual(width, cell.width);
            if (expected.fg) |fg| try std.testing.expectEqual(fg, cell.style.fg);
        }
        if (fixture.cursor) |cursor| {
            try std.testing.expectEqual(cursor.row, snapshot.cursor.row);
            try std.testing.expectEqual(cursor.col, snapshot.cursor.col);
            try std.testing.expectEqual(cursor.visible, snapshot.cursor.visible);
        }
        if (fixture.alternate_screen) |expected| try std.testing.expectEqual(expected, snapshot.alternate_screen);
        if (fixture.bracketed_paste) |expected| try std.testing.expectEqual(expected, snapshot.bracketed_paste);
        try std.testing.expect(snapshot.scrollback_rows >= fixture.minimum_scrollback_rows);
    }
}
