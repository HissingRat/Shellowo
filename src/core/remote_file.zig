const std = @import("std");

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

    pub fn isDirectory(self: RemoteFileEntry) bool {
        return self.kind == .directory;
    }
};

pub const FileLocation = enum {
    local,
    sftp,
    ftp,
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

pub const FilePanelSnapshot = struct {
    local: FilePaneSnapshot = .{ .location = .local },
    remote: FilePaneSnapshot = .{ .location = .sftp },
};

pub const FileEntryTarget = struct {
    pane: FilePaneTarget,
    path: []const u8,
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

pub const FileTransferIntent = struct {
    local_path: []const u8,
    remote_path: []const u8,
    name: []const u8,
};

pub const FileSelectIntent = struct {
    target: FileEntryTarget,
    additive: bool = false,
};

pub const FilePanelIntent = union(enum) {
    select: FileSelectIntent,
    toggle_tree: FileEntryTarget,
    refresh: FilePaneTarget,
    go_parent: FilePaneTarget,
    open: FileEntryTarget,
    create_directory: FileCreateDirectoryIntent,
    rename: FileRenameIntent,
    delete: FileEntryTarget,
    upload: FileTransferIntent,
    download: FileTransferIntent,
};

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
