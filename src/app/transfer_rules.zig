const std = @import("std");
const remote_file = @import("../core/remote_file.zig");

pub fn remoteEntryMatches(task_path: []const u8, task_name: []const u8, remote_path: []const u8, name: []const u8) bool {
    return std.mem.eql(u8, task_path, remote_path) and std.mem.eql(u8, task_name, name);
}

pub fn batchContainsRemoteEntry(item: remote_file.FileBatchTransferIntent, remote_path: []const u8, name: []const u8) bool {
    if (!std.mem.eql(u8, item.remote_path, remote_path)) return false;
    for (item.entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

pub fn pathsOverlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    return std.mem.eql(u8, a, b) or isAncestor(a, b) or isAncestor(b, a);
}

fn isAncestor(parent: []const u8, child: []const u8) bool {
    if (parent.len == 0 or child.len == 0) return false;
    if (std.mem.eql(u8, parent, child)) return true;
    if (std.mem.eql(u8, parent, "/")) return child.len > 1 and child[0] == '/';
    if (!std.mem.startsWith(u8, child, parent)) return false;
    return child.len > parent.len and child[parent.len] == '/';
}

test "remote paths overlap only on segment boundaries" {
    try std.testing.expect(pathsOverlap("/home", "/home/andy"));
    try std.testing.expect(!pathsOverlap("/home", "/home2"));
}
