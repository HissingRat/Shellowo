const std = @import("std");
const profile = @import("../core/profile.zig");
const ssh = @import("../protocols/ssh.zig");
const terminal = @import("../terminal/terminal.zig");

pub const Error = error{
    UnsupportedProfile,
    MissingCredentials,
    TerminalInitFailed,
    TerminalWriteFailed,
    SnapshotFailed,
} || ssh.Error;

pub const State = enum {
    idle,
    connecting,
    verifying_host_key,
    authenticating,
    opening_shell,
    connected,
    closing,
    closed,
    failed,
};

pub const Options = struct {
    connector: ssh.Connector,
    terminal_factory: TerminalFactory,
    host_key_verifier: ?ssh.HostKeyVerifier = null,
    host_key_policy: ssh.HostKeyPolicy = .strict,
    shell_size: ssh.PtySize = .{ .cols = 100, .rows = 30 },
    timeout_ms: u32 = 15_000,
};

pub const TerminalFactory = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        create: *const fn (*anyopaque, std.mem.Allocator, terminal.Size) terminal.Error!terminal.Emulator,
    };

    pub fn create(self: TerminalFactory, allocator: std.mem.Allocator, size: terminal.Size) terminal.Error!terminal.Emulator {
        return self.vtable.create(self.context, allocator, size);
    }
};

pub const SshSession = struct {
    allocator: std.mem.Allocator,
    state: State = .idle,
    client: ?ssh.Client = null,
    shell: ?ssh.Shell = null,
    emulator: ?terminal.Emulator = null,
    last_error: ?Error = null,
    dirty: bool = false,

    pub fn init(allocator: std.mem.Allocator) SshSession {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SshSession) void {
        self.close();
    }

    pub fn open(self: *SshSession, connection: profile.ConnectionProfile, options: Options) Error!void {
        if (connection != .ssh) return Error.UnsupportedProfile;
        const ssh_profile = connection.ssh;

        const auth = try authFromProfile(ssh_profile);
        const endpoint = ssh.Endpoint{
            .host = ssh_profile.base.host,
            .port = ssh_profile.base.port,
        };

        self.state = .connecting;
        std.log.debug("ssh session connecting host={s} port={d} user={s}", .{
            endpoint.host,
            endpoint.port,
            ssh_profile.base.username,
        });

        const client = options.connector.connect(self.allocator, .{
            .endpoint = endpoint,
            .auth = auth,
            .host_key_policy = options.host_key_policy,
            .host_key_verifier = options.host_key_verifier,
            .timeout_ms = options.timeout_ms,
        }) catch |err| {
            std.log.debug("ssh session connect failed host={s} port={d} err={s}", .{
                endpoint.host,
                endpoint.port,
                @errorName(err),
            });
            self.fail(err);
            return err;
        };
        errdefer client.close();

        self.state = .opening_shell;
        std.log.debug("ssh session opening shell host={s} port={d}", .{ endpoint.host, endpoint.port });
        const shell = client.openShell(.{
            .size = options.shell_size,
        }) catch |err| {
            std.log.debug("ssh session open shell failed host={s} port={d} err={s}", .{
                endpoint.host,
                endpoint.port,
                @errorName(err),
            });
            self.fail(err);
            return err;
        };
        errdefer shell.close();

        std.log.debug("ssh session creating terminal host={s} port={d}", .{ endpoint.host, endpoint.port });
        const emulator = options.terminal_factory.create(self.allocator, .{
            .cols = options.shell_size.cols,
            .rows = options.shell_size.rows,
        }) catch {
            std.log.debug("ssh session terminal init failed host={s} port={d}", .{ endpoint.host, endpoint.port });
            self.fail(Error.TerminalInitFailed);
            return Error.TerminalInitFailed;
        };
        errdefer emulator.deinit();

        self.client = client;
        self.shell = shell;
        self.emulator = emulator;
        self.state = .connected;
        self.last_error = null;
        self.dirty = true;
        std.log.debug("ssh session connected host={s} port={d}", .{ endpoint.host, endpoint.port });
    }

    pub fn pumpReadOnce(self: *SshSession, buffer: []u8) Error!usize {
        const shell = self.shell orelse return Error.ChannelClosed;
        const emulator = self.emulator orelse return Error.TerminalInitFailed;
        const read_len = shell.read(buffer) catch |err| {
            self.fail(err);
            return err;
        };
        if (read_len == 0) return 0;
        _ = emulator.write(buffer[0..read_len]) catch {
            self.fail(Error.TerminalWriteFailed);
            return Error.TerminalWriteFailed;
        };
        self.dirty = true;
        return read_len;
    }

    pub fn writeInput(self: *SshSession, bytes: []const u8) Error!usize {
        const shell = self.shell orelse return Error.ChannelClosed;
        return shell.write(bytes) catch |err| {
            self.fail(err);
            return err;
        };
    }

    pub fn writeMouse(self: *SshSession, allocator: std.mem.Allocator, event: terminal.MouseEvent) Error!usize {
        const shell = self.shell orelse return Error.ChannelClosed;
        const emulator = self.emulator orelse return Error.TerminalInitFailed;
        const bytes = emulator.mouse(allocator, event) catch return Error.TerminalWriteFailed;
        defer allocator.free(bytes);
        if (bytes.len == 0) return 0;
        return shell.write(bytes) catch |err| {
            self.fail(err);
            return err;
        };
    }

    pub fn clearScrollback(self: *SshSession) Error!void {
        const emulator = self.emulator orelse return Error.TerminalInitFailed;
        emulator.clearScrollback() catch return Error.TerminalWriteFailed;
        self.dirty = true;
    }

    pub fn resize(self: *SshSession, size: ssh.PtySize) Error!void {
        const shell = self.shell orelse return Error.ChannelClosed;
        const emulator = self.emulator orelse return Error.TerminalInitFailed;
        emulator.resize(.{ .cols = size.cols, .rows = size.rows }) catch return Error.TerminalInitFailed;
        try shell.resize(size);
        self.dirty = true;
    }

    pub fn snapshot(self: *SshSession, allocator: std.mem.Allocator) Error!terminal.Snapshot {
        const emulator = self.emulator orelse return Error.TerminalInitFailed;
        return emulator.snapshot(allocator) catch return Error.SnapshotFailed;
    }

    pub fn close(self: *SshSession) void {
        if (self.state == .closed) return;
        self.state = .closing;
        if (self.shell) |shell| {
            shell.close();
            self.shell = null;
        }
        if (self.client) |client| {
            client.close();
            self.client = null;
        }
        if (self.emulator) |emulator| {
            emulator.deinit();
            self.emulator = null;
        }
        self.state = .closed;
    }

    fn fail(self: *SshSession, err: Error) void {
        self.last_error = err;
        self.state = .failed;
    }
};

pub fn authFromProfile(connection: profile.SshProfile) Error!ssh.Auth {
    return switch (connection.auth_type) {
        .password => if (connection.password.len == 0)
            Error.MissingCredentials
        else
            .{ .password = .{ .username = connection.base.username, .password = connection.password } },
        .private_key => if (connection.private_key_path.len == 0)
            Error.MissingCredentials
        else
            .{ .private_key = .{ .username = connection.base.username, .private_key_path = connection.private_key_path } },
        .agent => .agent,
    };
}

test "session opens shell and pumps bytes into terminal emulator" {
    var fake = FakeRuntime.init(std.testing.allocator, "hello");
    defer fake.deinit();

    var session = SshSession.init(std.testing.allocator);
    defer session.deinit();

    const connection = try fakeProfile(std.testing.allocator);
    defer connection.deinit(std.testing.allocator);

    try session.open(connection, .{
        .connector = fake.connector(),
        .terminal_factory = fake.terminalFactory(),
        .host_key_policy = .insecure_accept_any,
    });

    var buffer: [16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 5), try session.pumpReadOnce(&buffer));

    var shot = try session.snapshot(std.testing.allocator);
    defer shot.deinit();

    try std.testing.expectEqual(State.connected, session.state);
    try std.testing.expectEqual(@as(u21, 'h'), shot.cellAt(0, 0).?.codepoint);
    try std.testing.expectEqual(@as(u21, 'o'), shot.cellAt(0, 4).?.codepoint);
}

test "session resize updates emulator and shell together" {
    var fake = FakeRuntime.init(std.testing.allocator, "");
    defer fake.deinit();

    var session = SshSession.init(std.testing.allocator);
    defer session.deinit();

    const connection = try fakeProfile(std.testing.allocator);
    defer connection.deinit(std.testing.allocator);

    try session.open(connection, .{
        .connector = fake.connector(),
        .terminal_factory = fake.terminalFactory(),
        .host_key_policy = .insecure_accept_any,
    });
    try session.resize(.{ .cols = 120, .rows = 40 });

    try std.testing.expectEqual(@as(u16, 120), fake.shell_context.size.cols);
    try std.testing.expectEqual(@as(u16, 40), fake.shell_context.size.rows);
    try std.testing.expectEqual(@as(u16, 120), fake.term_context.size.cols);
    try std.testing.expectEqual(@as(u16, 40), fake.term_context.size.rows);
}

fn fakeProfile(allocator: std.mem.Allocator) !profile.ConnectionProfile {
    return .{ .ssh = .{
        .base = .{
            .id = 1,
            .name = try allocator.dupe(u8, "Test SSH"),
            .host = try allocator.dupe(u8, "example.test"),
            .port = 22,
            .username = try allocator.dupe(u8, "dev"),
            .group = try allocator.dupe(u8, "Default"),
        },
        .auth_type = .password,
        .password = try allocator.dupe(u8, "pw"),
        .private_key_path = try allocator.dupe(u8, ""),
    } };
}

const FakeRuntime = struct {
    allocator: std.mem.Allocator,
    read_bytes: []const u8,
    read_offset: usize = 0,
    shell_context: FakeShellContext = .{},
    term_context: FakeTerminalContext = .{},

    fn init(allocator: std.mem.Allocator, read_bytes: []const u8) FakeRuntime {
        return .{
            .allocator = allocator,
            .read_bytes = read_bytes,
        };
    }

    fn deinit(self: *FakeRuntime) void {
        self.term_context.deinit(self.allocator);
    }

    fn connector(self: *FakeRuntime) ssh.Connector {
        return .{ .context = self, .vtable = &fake_connector_vtable };
    }

    fn terminalFactory(self: *FakeRuntime) TerminalFactory {
        return .{ .context = self, .vtable = &fake_terminal_factory_vtable };
    }
};

const FakeShellContext = struct {
    size: ssh.PtySize = .{ .cols = 100, .rows = 30 },
    closed: bool = false,
};

const FakeTerminalContext = struct {
    size: terminal.Size = .{ .cols = 100, .rows = 30 },
    cells: std.ArrayList(terminal.Cell) = .empty,

    fn deinit(self: *FakeTerminalContext, allocator: std.mem.Allocator) void {
        self.cells.deinit(allocator);
    }
};

fn fakeConnect(context: *anyopaque, allocator: std.mem.Allocator, options: ssh.ConnectOptions) ssh.Error!ssh.Client {
    _ = allocator;
    _ = options;
    const fake: *FakeRuntime = @ptrCast(@alignCast(context));
    return .{ .context = fake, .vtable = &fake_client_vtable };
}

const fake_connector_vtable: ssh.Connector.VTable = .{ .connect = fakeConnect };

fn fakeClientState(context: *anyopaque) ssh.SessionState {
    _ = context;
    return .connected;
}

fn fakeOpenShell(context: *anyopaque, options: ssh.ShellOptions) ssh.Error!ssh.Shell {
    const fake: *FakeRuntime = @ptrCast(@alignCast(context));
    fake.shell_context.size = options.size;
    return .{ .context = fake, .vtable = &fake_shell_vtable };
}

fn fakeOpenSftp(context: *anyopaque) ssh.Error!ssh.Sftp {
    _ = context;
    return ssh.Error.SftpUnavailable;
}

fn fakeExec(context: *anyopaque, allocator: std.mem.Allocator, options: ssh.ExecOptions) ssh.Error![]u8 {
    _ = context;
    _ = options;
    return allocator.dupe(u8, "") catch return ssh.Error.TransferFailed;
}

fn fakeCloseClient(context: *anyopaque) void {
    _ = context;
}

const fake_client_vtable: ssh.Client.VTable = .{
    .state = fakeClientState,
    .openShell = fakeOpenShell,
    .exec = fakeExec,
    .openSftp = fakeOpenSftp,
    .close = fakeCloseClient,
};

fn fakeShellWrite(context: *anyopaque, bytes: []const u8) ssh.Error!usize {
    _ = context;
    return bytes.len;
}

fn fakeShellRead(context: *anyopaque, buffer: []u8) ssh.Error!usize {
    const fake: *FakeRuntime = @ptrCast(@alignCast(context));
    const remaining = fake.read_bytes[fake.read_offset..];
    if (remaining.len == 0) return 0;
    const len = @min(buffer.len, remaining.len);
    @memcpy(buffer[0..len], remaining[0..len]);
    fake.read_offset += len;
    return len;
}

fn fakeShellResize(context: *anyopaque, size: ssh.PtySize) ssh.Error!void {
    const fake: *FakeRuntime = @ptrCast(@alignCast(context));
    fake.shell_context.size = size;
}

fn fakeShellClose(context: *anyopaque) void {
    const fake: *FakeRuntime = @ptrCast(@alignCast(context));
    fake.shell_context.closed = true;
}

const fake_shell_vtable: ssh.Shell.VTable = .{
    .write = fakeShellWrite,
    .read = fakeShellRead,
    .resize = fakeShellResize,
    .close = fakeShellClose,
};

fn fakeCreateTerminal(context: *anyopaque, allocator: std.mem.Allocator, size: terminal.Size) terminal.Error!terminal.Emulator {
    const fake: *FakeRuntime = @ptrCast(@alignCast(context));
    fake.term_context.size = size;
    fake.term_context.cells.clearRetainingCapacity();
    const count = size.cellCount();
    fake.term_context.cells.ensureTotalCapacity(allocator, count) catch return terminal.Error.InitFailed;
    fake.term_context.cells.expandToCapacity();
    fake.term_context.cells.items.len = count;
    @memset(fake.term_context.cells.items, .{});
    return .{ .context = fake, .vtable = &fake_terminal_vtable };
}

const fake_terminal_factory_vtable: TerminalFactory.VTable = .{ .create = fakeCreateTerminal };

fn fakeTerminalSize(context: *anyopaque) terminal.Size {
    const fake: *FakeRuntime = @ptrCast(@alignCast(context));
    return fake.term_context.size;
}

fn fakeTerminalWrite(context: *anyopaque, bytes: []const u8) terminal.Error!usize {
    const fake: *FakeRuntime = @ptrCast(@alignCast(context));
    for (bytes, 0..) |byte, idx| {
        if (idx >= fake.term_context.cells.items.len) break;
        fake.term_context.cells.items[idx].codepoint = std.math.cast(u21, byte) orelse ' ';
    }
    return bytes.len;
}

fn fakeTerminalResize(context: *anyopaque, size: terminal.Size) terminal.Error!void {
    const fake: *FakeRuntime = @ptrCast(@alignCast(context));
    fake.term_context.size = size;
}

fn fakeTerminalSnapshot(context: *anyopaque, allocator: std.mem.Allocator) terminal.Error!terminal.Snapshot {
    const fake: *FakeRuntime = @ptrCast(@alignCast(context));
    const cells = allocator.dupe(terminal.Cell, fake.term_context.cells.items) catch return terminal.Error.SnapshotFailed;
    return .{
        .allocator = allocator,
        .size = fake.term_context.size,
        .cells = cells,
        .cursor = .{},
    };
}

fn fakeTerminalMouse(context: *anyopaque, allocator: std.mem.Allocator, event: terminal.MouseEvent) terminal.Error![]u8 {
    _ = context;
    _ = event;
    return allocator.dupe(u8, "") catch return terminal.Error.MouseFailed;
}

fn fakeTerminalClearScrollback(context: *anyopaque) terminal.Error!void {
    _ = context;
}

fn fakeTerminalDeinit(context: *anyopaque) void {
    _ = context;
}

const fake_terminal_vtable: terminal.Emulator.VTable = .{
    .size = fakeTerminalSize,
    .write = fakeTerminalWrite,
    .resize = fakeTerminalResize,
    .snapshot = fakeTerminalSnapshot,
    .mouse = fakeTerminalMouse,
    .clear_scrollback = fakeTerminalClearScrollback,
    .deinit = fakeTerminalDeinit,
};
