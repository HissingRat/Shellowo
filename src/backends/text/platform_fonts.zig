const std = @import("std");
const builtin = @import("builtin");

pub const List = struct {
    paths: []const []const u8 = &.{},

    pub fn deinit(self: *List, allocator: std.mem.Allocator) void {
        for (self.paths) |path| allocator.free(path);
        allocator.free(self.paths);
        self.* = .{};
    }
};

const CandidateKind = enum(c_int) {
    emoji = 1,
    symbol = 2,
    cascade = 3,
};

const max_candidates_per_kind = 32;
const max_total_candidates = 48;

pub fn discoverFallbacks(allocator: std.mem.Allocator) !List {
    return switch (builtin.os.tag) {
        .macos => discoverPlatformFallbacks(allocator),
        .windows => discoverPlatformFallbacks(allocator),
        .linux => discoverPlatformFallbacks(allocator),
        else => .{},
    };
}

fn discoverPlatformFallbacks(allocator: std.mem.Allocator) !List {
    var paths = std.ArrayList([]const u8).empty;
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }

    try appendCandidates(allocator, &paths, .emoji, 0x1f600);
    try appendCandidates(allocator, &paths, .symbol, 0x2699);
    try appendCandidates(allocator, &paths, .cascade, 0x4e2d);
    try appendCandidates(allocator, &paths, .cascade, 0x1f600);
    try appendCandidates(allocator, &paths, .cascade, 0x0915);
    try appendCandidates(allocator, &paths, .cascade, 0x0633);

    return .{ .paths = try paths.toOwnedSlice(allocator) };
}

fn appendCandidates(
    allocator: std.mem.Allocator,
    paths: *std.ArrayList([]const u8),
    kind: CandidateKind,
    codepoint: u32,
) !void {
    if (paths.items.len >= max_total_candidates) return;

    var candidate_index: c_int = 0;
    while (candidate_index < max_candidates_per_kind and paths.items.len < max_total_candidates) : (candidate_index += 1) {
        var buffer: [1024]u8 = undefined;
        const len = shellowo_text_font_candidate(@intFromEnum(kind), codepoint, candidate_index, &buffer, buffer.len);
        if (len <= 0) break;

        const candidate = buffer[0..@as(usize, @intCast(len))];
        if (contains(paths.items, candidate)) continue;
        if (!pathExists(candidate)) continue;
        try paths.append(allocator, try allocator.dupe(u8, candidate));
    }
}

fn contains(paths: []const []const u8, candidate: []const u8) bool {
    for (paths) |path| {
        if (std.mem.eql(u8, path, candidate)) return true;
    }
    return false;
}

fn pathExists(path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{}) catch return false;
    return true;
}

extern fn shellowo_text_font_candidate(
    kind: c_int,
    codepoint: u32,
    candidate_index: c_int,
    out_path: [*]u8,
    out_len: usize,
) callconv(.c) c_int;

test "platform fallback discovery is safe to call" {
    var list = try discoverFallbacks(std.testing.allocator);
    defer list.deinit(std.testing.allocator);
}
