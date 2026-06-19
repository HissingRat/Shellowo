const std = @import("std");

pub fn parent(path: []const u8) []const u8 {
    if (path.len <= 1) return "/";
    const trimmed = trimRightSlash(path);
    const idx = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return "/";
    if (idx == 0) return "/";
    return trimmed[0..idx];
}

pub fn baseName(path: []const u8) []const u8 {
    const trimmed = trimRightSlash(path);
    const idx = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return trimmed;
    return trimmed[idx + 1 ..];
}

pub fn join(allocator: std.mem.Allocator, base: []const u8, name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, name, "..")) return allocator.dupe(u8, parent(base));
    if (std.mem.eql(u8, base, "/")) return std.fmt.allocPrint(allocator, "/{s}", .{name});
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ trimRightSlash(base), name });
}

pub fn depth(path: []const u8) usize {
    if (path.len <= 1) return 0;
    var result: usize = 0;
    var in_segment = false;
    for (path) |ch| {
        if (ch == '/') {
            in_segment = false;
        } else if (!in_segment) {
            in_segment = true;
            result += 1;
        }
    }
    return result;
}

pub fn validDirectory(path: []const u8) bool {
    return path.len > 0 and path[0] == '/' and std.mem.indexOfScalar(u8, path, 0) == null;
}

pub fn shellCdCommand(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "cd -- '");
    for (path) |ch| {
        if (ch == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, ch);
        }
    }
    try out.appendSlice(allocator, "'\r");
    return out.toOwnedSlice(allocator);
}

pub fn isDescendant(parent_path: []const u8, child: []const u8) bool {
    if (std.mem.eql(u8, parent_path, child)) return false;
    if (std.mem.eql(u8, parent_path, "/")) return child.len > 1 and child[0] == '/';
    if (!std.mem.startsWith(u8, child, parent_path)) return false;
    return child.len > parent_path.len and child[parent_path.len] == '/';
}

pub fn trimRightSlash(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    return path[0..end];
}

test "remote path helpers preserve root semantics" {
    try std.testing.expectEqualStrings("/", parent("/home"));
    try std.testing.expectEqualStrings("/home", parent("/home/andy/"));
    try std.testing.expectEqualStrings("andy", baseName("/home/andy/"));
    try std.testing.expectEqual(@as(usize, 2), depth("/home/andy"));
    try std.testing.expect(isDescendant("/home", "/home/andy"));
    try std.testing.expect(!isDescendant("/home", "/home2"));
}
