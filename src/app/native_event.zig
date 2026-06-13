const std = @import("std");

pub const NativeEvent = union(enum) {
    file_drop: FileDrop,
};

pub const Point = struct {
    x: f32 = -1,
    y: f32 = -1,
};

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn contains(self: Rect, p: Point) bool {
        return p.x >= self.x and p.y >= self.y and p.x < self.x + self.w and p.y < self.y + self.h;
    }
};

pub const FileDrop = struct {
    path: []const u8,
    x: f32,
    y: f32,
};

pub fn deinitEvent(allocator: std.mem.Allocator, event: NativeEvent) void {
    switch (event) {
        .file_drop => |drop| allocator.free(drop.path),
    }
}
