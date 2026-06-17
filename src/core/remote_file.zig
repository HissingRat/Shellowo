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

    pub fn isDirectory(self: RemoteFileEntry) bool {
        return self.kind == .directory;
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
