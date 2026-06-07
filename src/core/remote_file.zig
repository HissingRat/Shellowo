pub const RemoteFileKind = enum {
    file,
    directory,
    symlink,
    other,
};

pub const RemoteFileEntry = struct {
    name: []const u8,
    kind: RemoteFileKind,
    size: ?u64 = null,
    permissions: ?u32 = null,
    modified_unix: ?i64 = null,
};

