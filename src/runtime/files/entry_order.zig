const std = @import("std");
const remote_file = @import("../../core/remote_file.zig");

pub fn lessThan(context: void, a: remote_file.RemoteFileEntry, b: remote_file.RemoteFileEntry) bool {
    _ = context;
    if (isParent(a)) return !isParent(b);
    if (isParent(b)) return false;
    const a_rank = kindRank(a.kind);
    const b_rank = kindRank(b.kind);
    if (a_rank != b_rank) return a_rank < b_rank;
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

pub fn isParent(entry: remote_file.RemoteFileEntry) bool {
    return entry.kind == .directory and std.mem.eql(u8, entry.name, "..");
}

pub fn containsParent(entries: []const remote_file.RemoteFileEntry) bool {
    for (entries) |entry| {
        if (isParent(entry)) return true;
    }
    return false;
}

pub fn directoryExists(entries: []const remote_file.RemoteFileEntry, name: []const u8) bool {
    for (entries) |entry| {
        if (entry.isDirectory() and std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

fn kindRank(kind: remote_file.RemoteFileKind) u8 {
    return switch (kind) {
        .directory => 0,
        .symlink => 1,
        .file => 2,
        .other => 3,
    };
}
