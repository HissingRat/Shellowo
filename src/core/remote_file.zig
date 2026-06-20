const std = @import("std");

pub const max_editor_bytes: usize = 64 * 1024 * 1024;

pub const RemoteFileKind = enum {
    file,
    directory,
    symlink,
    other,

    pub fn label(self: RemoteFileKind) []const u8 {
        return switch (self) {
            .file => "file",
            .directory => "folder",
            .symlink => "link",
            .other => "other",
        };
    }
};

pub const RemoteFileEntry = struct {
    name: []const u8,
    kind: RemoteFileKind,
    size: ?u64 = null,
    permissions: ?u32 = null,
    modified_unix: ?i64 = null,
    uid: ?u64 = null,
    gid: ?u64 = null,
    full_path: []const u8 = "",
    depth: u8 = 0,
    expanded: bool = false,
    cache_stale: bool = false,

    pub fn isDirectory(self: RemoteFileEntry) bool {
        return self.kind == .directory;
    }

    pub fn isRootDirectory(self: RemoteFileEntry) bool {
        return self.isDirectory() and std.mem.eql(u8, self.full_path, "/");
    }
};

pub const FileLocation = enum {
    local,
    sftp,
};

pub const FilePaneTarget = enum {
    local,
    remote,
};

pub const FilePaneState = enum {
    unavailable,
    loading,
    ready,
    failed,
};

pub const FilePaneCapabilities = struct {
    can_refresh: bool = false,
    can_go_parent: bool = false,
    can_create_directory: bool = false,
    can_rename: bool = false,
    can_delete: bool = false,
    can_upload: bool = false,
    can_download: bool = false,
    can_edit: bool = false,
};

pub const FilePaneSnapshot = struct {
    location: FileLocation,
    path: []const u8 = "",
    state: FilePaneState = .unavailable,
    entries: []const RemoteFileEntry = &.{},
    selected_name: ?[]const u8 = null,
    error_summary: ?[]const u8 = null,
    capabilities: FilePaneCapabilities = .{},

    pub fn isBusy(self: FilePaneSnapshot) bool {
        return self.state == .loading;
    }

    pub fn isEmpty(self: FilePaneSnapshot) bool {
        return self.state == .ready and self.entries.len == 0;
    }
};

pub const FileTreeSnapshot = struct {
    path: []const u8 = "",
    state: FilePaneState = .unavailable,
    entries: []const RemoteFileEntry = &.{},
    error_summary: ?[]const u8 = null,

    pub fn isBusy(self: FileTreeSnapshot) bool {
        return self.state == .loading;
    }

    pub fn isEmpty(self: FileTreeSnapshot) bool {
        return self.state == .ready and self.entries.len == 0;
    }
};

pub const FileEditorState = enum {
    closed,
    loading,
    ready,
    failed,
};

pub const FileEditorSnapshot = struct {
    state: FileEditorState = .closed,
    path: []const u8 = "",
    name: []const u8 = "",
    content: []const u8 = "",
    error_summary: ?[]const u8 = null,
    progress_done: u64 = 0,
    progress_total: ?u64 = null,
    version: u64 = 0,

    pub fn isOpen(self: FileEditorSnapshot) bool {
        return self.state != .closed;
    }
};

pub const FilePanelSnapshot = struct {
    tree: FileTreeSnapshot = .{},
    remote: FilePaneSnapshot = .{ .location = .sftp },
    editor: FileEditorSnapshot = .{},
};

pub const FileEntryTarget = struct {
    pane: FilePaneTarget,
    path: []const u8,
    name: []const u8,
    kind: ?RemoteFileKind = null,
};

pub const FileCreateFileIntent = struct {
    pane: FilePaneTarget,
    parent_path: []const u8,
    name: []const u8,
};

pub const FileCreateDirectoryIntent = struct {
    pane: FilePaneTarget,
    parent_path: []const u8,
    name: []const u8,
};

pub const FileRenameIntent = struct {
    pane: FilePaneTarget,
    path: []const u8,
    old_name: []const u8,
    new_name: []const u8,
};

pub const FileChmodIntent = struct {
    pane: FilePaneTarget,
    path: []const u8,
    permissions: u32,
};

pub const FileEditOpenIntent = struct {
    pane: FilePaneTarget,
    path: []const u8,
    name: []const u8,
    size: ?u64 = null,
};

pub const FileEditSaveIntent = struct {
    pane: FilePaneTarget,
    path: []const u8,
    content: []const u8,
};

pub const FileTransferIntent = struct {
    local_path: []const u8,
    remote_path: []const u8,
    name: []const u8,
    transfer_id: ?u64 = null,
};

pub const FileBatchEntry = struct {
    name: []const u8,
    kind: RemoteFileKind,
    size: ?u64 = null,
};

pub const FileBatchTransferIntent = struct {
    local_path: []const u8,
    remote_path: []const u8,
    entries: []const FileBatchEntry,
    transfer_id: ?u64 = null,
};

pub const FileSelectIntent = struct {
    target: FileEntryTarget,
    additive: bool = false,
};

pub const FilePathIntent = struct {
    pane: FilePaneTarget,
    path: []const u8,
    terminal_slot_id: ?u64 = null,
};

pub const FilePanelIntent = union(enum) {
    select: FileSelectIntent,
    toggle_tree: FileEntryTarget,
    refresh: FilePaneTarget,
    go_parent: FilePaneTarget,
    go_path: FilePathIntent,
    open: FileEntryTarget,
    create_file: FileCreateFileIntent,
    create_directory: FileCreateDirectoryIntent,
    rename: FileRenameIntent,
    chmod: FileChmodIntent,
    open_edit: FileEditOpenIntent,
    save_edit: FileEditSaveIntent,
    close_edit: FilePaneTarget,
    delete: FileEntryTarget,
    upload: FileTransferIntent,
    upload_many: FileBatchTransferIntent,
    download: FileTransferIntent,
    download_many: FileBatchTransferIntent,
};

pub fn clonePanelIntent(allocator: std.mem.Allocator, intent: FilePanelIntent) !FilePanelIntent {
    return switch (intent) {
        .select => |selection| .{ .select = .{
            .target = try cloneEntryTarget(allocator, selection.target),
            .additive = selection.additive,
        } },
        .toggle_tree => |target| .{ .toggle_tree = try cloneEntryTarget(allocator, target) },
        .refresh => |pane| .{ .refresh = pane },
        .go_parent => |pane| .{ .go_parent = pane },
        .go_path => |target| .{ .go_path = .{
            .pane = target.pane,
            .path = try allocator.dupe(u8, target.path),
            .terminal_slot_id = target.terminal_slot_id,
        } },
        .open => |target| .{ .open = try cloneEntryTarget(allocator, target) },
        .create_file => |item| blk: {
            const pair = try clonePair(allocator, item.parent_path, item.name);
            break :blk .{ .create_file = .{
                .pane = item.pane,
                .parent_path = pair.first,
                .name = pair.second,
            } };
        },
        .create_directory => |item| blk: {
            const pair = try clonePair(allocator, item.parent_path, item.name);
            break :blk .{ .create_directory = .{
                .pane = item.pane,
                .parent_path = pair.first,
                .name = pair.second,
            } };
        },
        .rename => |item| .{ .rename = try cloneRenameIntent(allocator, item) },
        .chmod => |item| .{ .chmod = .{
            .pane = item.pane,
            .path = try allocator.dupe(u8, item.path),
            .permissions = item.permissions,
        } },
        .open_edit => |item| blk: {
            const pair = try clonePair(allocator, item.path, item.name);
            break :blk .{ .open_edit = .{
                .pane = item.pane,
                .path = pair.first,
                .name = pair.second,
                .size = item.size,
            } };
        },
        .save_edit => |item| blk: {
            const pair = try clonePair(allocator, item.path, item.content);
            break :blk .{ .save_edit = .{
                .pane = item.pane,
                .path = pair.first,
                .content = pair.second,
            } };
        },
        .close_edit => |pane| .{ .close_edit = pane },
        .delete => |target| .{ .delete = try cloneEntryTarget(allocator, target) },
        .upload => |item| .{ .upload = try cloneTransferIntent(allocator, item) },
        .upload_many => |item| .{ .upload_many = try cloneBatchTransferIntent(allocator, item) },
        .download => |item| .{ .download = try cloneTransferIntent(allocator, item) },
        .download_many => |item| .{ .download_many = try cloneBatchTransferIntent(allocator, item) },
    };
}

pub fn freePanelIntent(allocator: std.mem.Allocator, intent: FilePanelIntent) void {
    switch (intent) {
        .select => |selection| freeEntryTarget(allocator, selection.target),
        .toggle_tree, .open, .delete => |target| freeEntryTarget(allocator, target),
        .refresh, .go_parent, .close_edit => {},
        .go_path => |target| allocator.free(target.path),
        .create_file => |item| freePair(allocator, item.parent_path, item.name),
        .create_directory => |item| freePair(allocator, item.parent_path, item.name),
        .rename => |item| {
            allocator.free(item.path);
            allocator.free(item.old_name);
            allocator.free(item.new_name);
        },
        .chmod => |item| allocator.free(item.path),
        .open_edit => |item| freePair(allocator, item.path, item.name),
        .save_edit => |item| freePair(allocator, item.path, item.content),
        .upload, .download => |item| freeTransferIntent(allocator, item),
        .upload_many, .download_many => |item| freeBatchTransferIntent(allocator, item),
    }
}

fn cloneEntryTarget(allocator: std.mem.Allocator, target: FileEntryTarget) !FileEntryTarget {
    const path = try allocator.dupe(u8, target.path);
    errdefer allocator.free(path);
    const name = try allocator.dupe(u8, target.name);
    return .{ .pane = target.pane, .path = path, .name = name, .kind = target.kind };
}

fn cloneRenameIntent(allocator: std.mem.Allocator, item: FileRenameIntent) !FileRenameIntent {
    const path = try allocator.dupe(u8, item.path);
    errdefer allocator.free(path);
    const old_name = try allocator.dupe(u8, item.old_name);
    errdefer allocator.free(old_name);
    const new_name = try allocator.dupe(u8, item.new_name);
    return .{ .pane = item.pane, .path = path, .old_name = old_name, .new_name = new_name };
}

fn cloneTransferIntent(allocator: std.mem.Allocator, item: FileTransferIntent) !FileTransferIntent {
    const local_path = try allocator.dupe(u8, item.local_path);
    errdefer allocator.free(local_path);
    const remote_path = try allocator.dupe(u8, item.remote_path);
    errdefer allocator.free(remote_path);
    const name = try allocator.dupe(u8, item.name);
    return .{
        .local_path = local_path,
        .remote_path = remote_path,
        .name = name,
        .transfer_id = item.transfer_id,
    };
}

fn cloneBatchTransferIntent(allocator: std.mem.Allocator, item: FileBatchTransferIntent) !FileBatchTransferIntent {
    const local_path = try allocator.dupe(u8, item.local_path);
    errdefer allocator.free(local_path);
    const remote_path = try allocator.dupe(u8, item.remote_path);
    errdefer allocator.free(remote_path);
    const entries = try allocator.alloc(FileBatchEntry, item.entries.len);
    var initialized: usize = 0;
    errdefer {
        for (entries[0..initialized]) |entry| allocator.free(entry.name);
        allocator.free(entries);
    }
    for (item.entries, 0..) |entry, idx| {
        entries[idx] = .{
            .name = try allocator.dupe(u8, entry.name),
            .kind = entry.kind,
            .size = entry.size,
        };
        initialized += 1;
    }
    return .{
        .local_path = local_path,
        .remote_path = remote_path,
        .entries = entries,
        .transfer_id = item.transfer_id,
    };
}

const OwnedPair = struct {
    first: []u8,
    second: []u8,
};

fn clonePair(allocator: std.mem.Allocator, first_source: []const u8, second_source: []const u8) !OwnedPair {
    const first = try allocator.dupe(u8, first_source);
    errdefer allocator.free(first);
    const second = try allocator.dupe(u8, second_source);
    return .{ .first = first, .second = second };
}

fn freeEntryTarget(allocator: std.mem.Allocator, target: FileEntryTarget) void {
    freePair(allocator, target.path, target.name);
}

fn freeTransferIntent(allocator: std.mem.Allocator, item: FileTransferIntent) void {
    allocator.free(item.local_path);
    allocator.free(item.remote_path);
    allocator.free(item.name);
}

fn freeBatchTransferIntent(allocator: std.mem.Allocator, item: FileBatchTransferIntent) void {
    allocator.free(item.local_path);
    allocator.free(item.remote_path);
    for (item.entries) |entry| allocator.free(entry.name);
    allocator.free(item.entries);
}

fn freePair(allocator: std.mem.Allocator, first: []const u8, second: []const u8) void {
    allocator.free(first);
    allocator.free(second);
}

test "file pane snapshot reports ready empty state" {
    const pane = FilePaneSnapshot{
        .location = .sftp,
        .path = "/tmp",
        .state = .ready,
    };

    try std.testing.expect(pane.isEmpty());
    try std.testing.expect(!pane.isBusy());
}

test "file entry kind exposes directory helper" {
    const entry = RemoteFileEntry{
        .name = "home",
        .kind = .directory,
    };

    try std.testing.expect(entry.isDirectory());
    try std.testing.expectEqualStrings("folder", entry.kind.label());
}

test "file entry identifies the remote root directory" {
    const root = RemoteFileEntry{
        .name = "/",
        .kind = .directory,
        .full_path = "/",
    };
    const child = RemoteFileEntry{
        .name = "home",
        .kind = .directory,
        .full_path = "/home",
    };

    try std.testing.expect(root.isRootDirectory());
    try std.testing.expect(!child.isRootDirectory());
}

test "file panel intent clone releases partial allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testPanelIntentCloneAllocationFailure, .{});
}

fn testPanelIntentCloneAllocationFailure(allocator: std.mem.Allocator) !void {
    try cloneAndFreePanelIntent(allocator, .{ .select = .{
        .target = .{ .pane = .remote, .path = "/tmp", .name = "item" },
    } });
    try cloneAndFreePanelIntent(allocator, .{ .create_file = .{
        .pane = .remote,
        .parent_path = "/tmp",
        .name = "new.txt",
    } });
    try cloneAndFreePanelIntent(allocator, .{ .rename = .{
        .pane = .remote,
        .path = "/tmp",
        .old_name = "old.txt",
        .new_name = "new.txt",
    } });
    try cloneAndFreePanelIntent(allocator, .{ .open_edit = .{
        .pane = .remote,
        .path = "/tmp/file.txt",
        .name = "file.txt",
    } });
    try cloneAndFreePanelIntent(allocator, .{ .save_edit = .{
        .pane = .remote,
        .path = "/tmp/file.txt",
        .content = "updated",
    } });

    const entries = [_]FileBatchEntry{
        .{ .name = "one.txt", .kind = .file },
        .{ .name = "two", .kind = .directory },
    };
    const intent = FilePanelIntent{ .upload_many = .{
        .local_path = "/tmp/local",
        .remote_path = "/remote",
        .entries = &entries,
        .transfer_id = 42,
    } };
    try cloneAndFreePanelIntent(allocator, intent);
}

fn cloneAndFreePanelIntent(allocator: std.mem.Allocator, intent: FilePanelIntent) !void {
    const copied = try clonePanelIntent(allocator, intent);
    defer freePanelIntent(allocator, copied);
}
