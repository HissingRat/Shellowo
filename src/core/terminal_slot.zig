const std = @import("std");

pub const TerminalSlotId = u64;

pub const TerminalSlotStatus = enum {
    opening,
    active,
    closed,
    failed,

    pub fn label(self: TerminalSlotStatus) []const u8 {
        return switch (self) {
            .opening => "opening",
            .active => "active",
            .closed => "closed",
            .failed => "failed",
        };
    }
};

pub const TerminalSlotSummary = struct {
    id: TerminalSlotId,
    ordinal: u16,
    title: []const u8 = "",
    status: TerminalSlotStatus = .opening,

    pub fn fallbackLabel(self: TerminalSlotSummary, buffer: []u8) []const u8 {
        if (self.title.len > 0) return self.title;
        return std.fmt.bufPrint(buffer, "term {d}", .{self.ordinal}) catch "term";
    }
};

pub const TerminalSlotCreateIntent = struct {
    requested_cols: u16,
    requested_rows: u16,
};

test "terminal slot summary uses osc title before fallback label" {
    var buffer: [32]u8 = undefined;
    const titled = TerminalSlotSummary{ .id = 1, .ordinal = 1, .title = "vim", .status = .active };
    try std.testing.expectEqualStrings("vim", titled.fallbackLabel(&buffer));

    const untitled = TerminalSlotSummary{ .id = 2, .ordinal = 3, .status = .active };
    try std.testing.expectEqualStrings("term 3", untitled.fallbackLabel(&buffer));
}
