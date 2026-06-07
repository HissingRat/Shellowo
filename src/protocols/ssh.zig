const std = @import("std");

pub const Error = error{
    UnsupportedAuth,
    InvalidHostKey,
    ConnectionFailed,
    AuthenticationFailed,
    ChannelOpenFailed,
    ChannelClosed,
    SftpUnavailable,
    TransferFailed,
    WouldBlock,
};

pub const Endpoint = struct {
    host: []const u8,
    port: u16 = 22,
};

pub const Auth = union(enum) {
    password: PasswordAuth,
    private_key: PrivateKeyAuth,
    agent,
};

pub const PasswordAuth = struct {
    username: []const u8,
    password: []const u8,
};

pub const PrivateKeyAuth = struct {
    username: []const u8,
    private_key_path: []const u8,
    passphrase: ?[]const u8 = null,
};

pub const HostKeyPolicy = union(enum) {
    strict,
    trust_on_first_use,
    insecure_accept_any,
};

pub const ConnectOptions = struct {
    endpoint: Endpoint,
    auth: Auth,
    host_key_policy: HostKeyPolicy = .strict,
    timeout_ms: u32 = 15_000,
};

pub const PtySize = struct {
    cols: u16,
    rows: u16,
};

pub const ShellOptions = struct {
    term: []const u8 = "xterm-256color",
    size: PtySize = .{ .cols = 100, .rows = 30 },
};

pub const SessionState = enum {
    idle,
    connecting,
    authenticating,
    connected,
    closing,
    closed,
    failed,
};

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

pub const Shell = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        write: *const fn (*anyopaque, []const u8) Error!usize,
        read: *const fn (*anyopaque, []u8) Error!usize,
        resize: *const fn (*anyopaque, PtySize) Error!void,
        close: *const fn (*anyopaque) void,
    };

    pub fn write(self: Shell, bytes: []const u8) Error!usize {
        return self.vtable.write(self.context, bytes);
    }

    pub fn read(self: Shell, buffer: []u8) Error!usize {
        return self.vtable.read(self.context, buffer);
    }

    pub fn resize(self: Shell, size: PtySize) Error!void {
        return self.vtable.resize(self.context, size);
    }

    pub fn close(self: Shell) void {
        self.vtable.close(self.context);
    }
};

pub const Sftp = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        list: *const fn (*anyopaque, std.mem.Allocator, []const u8) Error![]RemoteFileEntry,
        readFile: *const fn (*anyopaque, std.mem.Allocator, []const u8) Error![]u8,
        writeFile: *const fn (*anyopaque, []const u8, []const u8) Error!void,
        remove: *const fn (*anyopaque, []const u8) Error!void,
        mkdir: *const fn (*anyopaque, []const u8) Error!void,
        rename: *const fn (*anyopaque, []const u8, []const u8) Error!void,
        close: *const fn (*anyopaque) void,
    };

    pub fn list(self: Sftp, allocator: std.mem.Allocator, path: []const u8) Error![]RemoteFileEntry {
        return self.vtable.list(self.context, allocator, path);
    }

    pub fn readFile(self: Sftp, allocator: std.mem.Allocator, path: []const u8) Error![]u8 {
        return self.vtable.readFile(self.context, allocator, path);
    }

    pub fn writeFile(self: Sftp, path: []const u8, bytes: []const u8) Error!void {
        return self.vtable.writeFile(self.context, path, bytes);
    }

    pub fn remove(self: Sftp, path: []const u8) Error!void {
        return self.vtable.remove(self.context, path);
    }

    pub fn mkdir(self: Sftp, path: []const u8) Error!void {
        return self.vtable.mkdir(self.context, path);
    }

    pub fn rename(self: Sftp, old_path: []const u8, new_path: []const u8) Error!void {
        return self.vtable.rename(self.context, old_path, new_path);
    }

    pub fn close(self: Sftp) void {
        self.vtable.close(self.context);
    }
};

pub const Client = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        state: *const fn (*anyopaque) SessionState,
        openShell: *const fn (*anyopaque, ShellOptions) Error!Shell,
        openSftp: *const fn (*anyopaque) Error!Sftp,
        close: *const fn (*anyopaque) void,
    };

    pub fn state(self: Client) SessionState {
        return self.vtable.state(self.context);
    }

    pub fn openShell(self: Client, options: ShellOptions) Error!Shell {
        return self.vtable.openShell(self.context, options);
    }

    pub fn openSftp(self: Client) Error!Sftp {
        return self.vtable.openSftp(self.context);
    }

    pub fn close(self: Client) void {
        self.vtable.close(self.context);
    }
};

pub const Connector = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        connect: *const fn (*anyopaque, std.mem.Allocator, ConnectOptions) Error!Client,
    };

    pub fn connect(self: Connector, allocator: std.mem.Allocator, options: ConnectOptions) Error!Client {
        return self.vtable.connect(self.context, allocator, options);
    }
};

test "default shell options use xterm compatible terminal" {
    const opts = ShellOptions{};
    try std.testing.expectEqualStrings("xterm-256color", opts.term);
    try std.testing.expectEqual(@as(u16, 100), opts.size.cols);
    try std.testing.expectEqual(@as(u16, 30), opts.size.rows);
}

test "connect options keep host key policy explicit" {
    const opts = ConnectOptions{
        .endpoint = .{ .host = "example.test" },
        .auth = .{ .agent = {} },
    };

    try std.testing.expectEqualStrings("example.test", opts.endpoint.host);
    try std.testing.expectEqual(@as(u16, 22), opts.endpoint.port);
    try std.testing.expectEqual(HostKeyPolicy.strict, opts.host_key_policy);
}
