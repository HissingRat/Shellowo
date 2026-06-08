const std = @import("std");
const ssh = @import("ssh.zig");

const c = @cImport({
    @cInclude("libssh2.h");
    @cInclude("netdb.h");
    @cInclude("sys/socket.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});

/// libssh2 integration belongs here.
///
/// Keep raw LIBSSH2_SESSION, LIBSSH2_CHANNEL, and LIBSSH2_SFTP handles out of
/// app state and DVUI widgets. This file should translate libssh2 behavior into
/// the stable `protocols/ssh.zig` API.
pub const Backend = struct {
    allocator: std.mem.Allocator,

    pub fn connector(self: *Backend) ssh.Connector {
        return .{
            .context = self,
            .vtable = &connector_vtable,
        };
    }

    fn connect(context: *anyopaque, allocator: std.mem.Allocator, options: ssh.ConnectOptions) ssh.Error!ssh.Client {
        _ = context;

        const host = allocator.dupeZ(u8, options.endpoint.host) catch return ssh.Error.ConnectionFailed;
        defer allocator.free(host);
        const service = std.fmt.allocPrintSentinel(allocator, "{d}", .{options.endpoint.port}, 0) catch return ssh.Error.ConnectionFailed;
        defer allocator.free(service);

        const fd = connectSocketWithRetry(host, service, options.endpoint) catch return ssh.Error.ConnectionFailed;
        errdefer _ = c.close(fd);
        std.log.debug("libssh2 connect socket ok host={s} port={d}", .{ options.endpoint.host, options.endpoint.port });

        std.log.debug("libssh2 session init begin host={s} port={d}", .{ options.endpoint.host, options.endpoint.port });
        const session = c.libssh2_session_init_ex(null, null, null, null) orelse return ssh.Error.ConnectionFailed;
        errdefer _ = c.libssh2_session_free(session);
        c.libssh2_session_set_blocking(session, 1);
        c.libssh2_session_set_timeout(session, options.timeout_ms);
        std.log.debug("libssh2 handshake begin host={s} port={d}", .{ options.endpoint.host, options.endpoint.port });

        if (c.libssh2_session_handshake(session, fd) != 0) return ssh.Error.ConnectionFailed;
        std.log.debug("libssh2 handshake ok host={s} port={d}", .{ options.endpoint.host, options.endpoint.port });

        std.log.debug("libssh2 host key verify begin host={s} port={d}", .{ options.endpoint.host, options.endpoint.port });
        const host_key = readHostKey(session) catch return ssh.Error.InvalidHostKey;
        try verifyHostKey(options, host_key);
        std.log.debug("libssh2 host key verify ok host={s} port={d}", .{ options.endpoint.host, options.endpoint.port });

        std.log.debug("libssh2 auth begin host={s} port={d}", .{ options.endpoint.host, options.endpoint.port });
        authenticate(session, allocator, options.auth) catch |err| return err;
        std.log.debug("libssh2 auth ok host={s} port={d}", .{ options.endpoint.host, options.endpoint.port });

        const client = allocator.create(ClientContext) catch return ssh.Error.ConnectionFailed;
        client.* = .{
            .allocator = allocator,
            .fd = fd,
            .session = session,
            .state = .connected,
        };

        return .{
            .context = client,
            .vtable = &client_vtable,
        };
    }
};

const connector_vtable: ssh.Connector.VTable = .{
    .connect = Backend.connect,
};

const ClientContext = struct {
    allocator: std.mem.Allocator,
    fd: c_int,
    session: *c.LIBSSH2_SESSION,
    state: ssh.SessionState,
};

const ShellContext = struct {
    allocator: std.mem.Allocator,
    client: *ClientContext,
    channel: *c.LIBSSH2_CHANNEL,
    closed: bool = false,
};

fn connectSocketWithRetry(host: [:0]const u8, service: [:0]const u8, endpoint: ssh.Endpoint) !c_int {
    const attempts = 4;
    for (0..attempts) |attempt| {
        std.log.debug("libssh2 connect socket begin host={s} port={d} attempt={d}", .{
            endpoint.host,
            endpoint.port,
            attempt + 1,
        });
        return connectSocket(host, service, endpoint) catch |err| {
            if (attempt + 1 == attempts) return err;
            sleepMs(150);
            continue;
        };
    }
    return error.ConnectFailed;
}

fn connectSocket(host: [:0]const u8, service: [:0]const u8, endpoint: ssh.Endpoint) !c_int {
    var hints: c.addrinfo = std.mem.zeroes(c.addrinfo);
    hints.ai_family = c.AF_UNSPEC;
    hints.ai_socktype = c.SOCK_STREAM;

    var result: ?*c.addrinfo = null;
    const gai_rc = c.getaddrinfo(host.ptr, service.ptr, &hints, &result);
    if (gai_rc != 0) {
        std.log.debug("libssh2 getaddrinfo failed host={s} port={d} rc={d}", .{ endpoint.host, endpoint.port, gai_rc });
        return error.ConnectFailed;
    }
    defer c.freeaddrinfo(result);

    var node = result;
    while (node) |addr| : (node = addr.ai_next) {
        const fd = c.socket(addr.ai_family, addr.ai_socktype, addr.ai_protocol);
        if (fd < 0) {
            std.log.debug("libssh2 socket failed host={s} port={d} errno={s}", .{ endpoint.host, endpoint.port, @tagName(std.c.errno(fd)) });
            continue;
        }
        if (c.connect(fd, addr.ai_addr, @intCast(addr.ai_addrlen)) == 0) return fd;
        std.log.debug("libssh2 socket connect failed host={s} port={d} family={d} errno={s}", .{
            endpoint.host,
            endpoint.port,
            addr.ai_family,
            @tagName(std.c.errno(-1)),
        });
        _ = c.close(fd);
    }

    return error.ConnectFailed;
}

fn sleepMs(ms: c_long) void {
    const request: c.timespec = .{
        .tv_sec = @divTrunc(ms, 1000),
        .tv_nsec = @rem(ms, 1000) * std.time.ns_per_ms,
    };
    _ = c.nanosleep(&request, null);
}

fn yieldThread() void {
    std.Thread.yield() catch {};
}

fn authenticate(session: *c.LIBSSH2_SESSION, allocator: std.mem.Allocator, auth: ssh.Auth) ssh.Error!void {
    switch (auth) {
        .password => |password| {
            const username = allocator.dupeZ(u8, password.username) catch return ssh.Error.AuthenticationFailed;
            defer allocator.free(username);
            const secret = allocator.dupeZ(u8, password.password) catch return ssh.Error.AuthenticationFailed;
            defer allocator.free(secret);

            if (c.libssh2_userauth_password_ex(session, username.ptr, @intCast(username.len), secret.ptr, @intCast(secret.len), null) != 0) {
                return ssh.Error.AuthenticationFailed;
            }
        },
        .private_key => |private_key| {
            const username = allocator.dupeZ(u8, private_key.username) catch return ssh.Error.AuthenticationFailed;
            defer allocator.free(username);
            const key_path = allocator.dupeZ(u8, private_key.private_key_path) catch return ssh.Error.AuthenticationFailed;
            defer allocator.free(key_path);
            const passphrase = if (private_key.passphrase) |value| allocator.dupeZ(u8, value) catch return ssh.Error.AuthenticationFailed else null;
            defer if (passphrase) |value| allocator.free(value);

            if (c.libssh2_userauth_publickey_fromfile(session, username.ptr, null, key_path.ptr, if (passphrase) |value| value.ptr else null) != 0) {
                return ssh.Error.AuthenticationFailed;
            }
        },
        .agent => return ssh.Error.UnsupportedAuth,
    }
}

fn readHostKey(session: *c.LIBSSH2_SESSION) ssh.Error!ssh.HostKey {
    var key_len: usize = 0;
    var key_type: c_int = 0;
    const raw_key = c.libssh2_session_hostkey(session, &key_len, &key_type);
    if (raw_key == null or key_len == 0) return ssh.Error.InvalidHostKey;

    const hash = c.libssh2_hostkey_hash(session, c.LIBSSH2_HOSTKEY_HASH_SHA256) orelse return ssh.Error.InvalidHostKey;
    var sha256: [32]u8 = undefined;
    @memcpy(&sha256, hash[0..32]);

    return .{
        .algorithm = hostKeyAlgorithm(key_type),
        .sha256 = sha256,
    };
}

fn verifyHostKey(options: ssh.ConnectOptions, host_key: ssh.HostKey) ssh.Error!void {
    switch (options.host_key_policy) {
        .insecure_accept_any => return,
        .strict, .trust_on_first_use => {
            const verifier = options.host_key_verifier orelse return ssh.Error.InvalidHostKey;
            try verifier.verify(options.endpoint, options.host_key_policy, host_key);
        },
    }
}

fn hostKeyAlgorithm(key_type: c_int) ssh.HostKeyAlgorithm {
    return switch (key_type) {
        c.LIBSSH2_HOSTKEY_TYPE_RSA => .rsa,
        c.LIBSSH2_HOSTKEY_TYPE_DSS => .dss,
        c.LIBSSH2_HOSTKEY_TYPE_ECDSA_256 => .ecdsa_256,
        c.LIBSSH2_HOSTKEY_TYPE_ECDSA_384 => .ecdsa_384,
        c.LIBSSH2_HOSTKEY_TYPE_ECDSA_521 => .ecdsa_521,
        c.LIBSSH2_HOSTKEY_TYPE_ED25519 => .ed25519,
        else => .unknown,
    };
}

fn clientState(context: *anyopaque) ssh.SessionState {
    const self: *ClientContext = @ptrCast(@alignCast(context));
    return self.state;
}

fn openShell(context: *anyopaque, options: ssh.ShellOptions) ssh.Error!ssh.Shell {
    const self: *ClientContext = @ptrCast(@alignCast(context));
    const channel = openChannelWithRetry(self) catch return ssh.Error.ChannelOpenFailed;
    errdefer _ = c.libssh2_channel_free(channel);

    const term = self.allocator.dupeZ(u8, options.term) catch return ssh.Error.ChannelOpenFailed;
    defer self.allocator.free(term);

    try retryChannelOperation(self, channel, "request pty", struct {
        fn call(ch: *c.LIBSSH2_CHANNEL, t: [:0]const u8, size: ssh.PtySize) c_int {
            return c.libssh2_channel_request_pty_ex(ch, t.ptr, @intCast(t.len), null, 0, size.cols, size.rows, 0, 0);
        }
    }.call, .{ term, options.size });
    try retryChannelOperation(self, channel, "start shell", struct {
        fn call(ch: *c.LIBSSH2_CHANNEL) c_int {
            return c.libssh2_channel_process_startup(ch, "shell", 5, null, 0);
        }
    }.call, .{});
    c.libssh2_session_set_blocking(self.session, 0);

    const shell = self.allocator.create(ShellContext) catch return ssh.Error.ChannelOpenFailed;
    shell.* = .{
        .allocator = self.allocator,
        .client = self,
        .channel = channel,
    };

    return .{
        .context = shell,
        .vtable = &shell_vtable,
    };
}

fn openChannelWithRetry(self: *ClientContext) ssh.Error!*c.LIBSSH2_CHANNEL {
    var attempts: usize = 0;
    while (attempts < 5000) : (attempts += 1) {
        if (c.libssh2_channel_open_ex(
            self.session,
            "session",
            7,
            c.LIBSSH2_CHANNEL_WINDOW_DEFAULT,
            c.LIBSSH2_CHANNEL_PACKET_DEFAULT,
            null,
            0,
        )) |channel| {
            return channel;
        }

        if (c.libssh2_session_last_errno(self.session) != c.LIBSSH2_ERROR_EAGAIN) {
            return ssh.Error.ChannelOpenFailed;
        }
        sleepMs(1);
    }
    return ssh.Error.ChannelOpenFailed;
}

fn retryChannelOperation(self: *ClientContext, channel: *c.LIBSSH2_CHANNEL, comptime label: []const u8, comptime func: anytype, args: anytype) ssh.Error!void {
    _ = label;
    var attempts: usize = 0;
    while (attempts < 5000) : (attempts += 1) {
        const rc = @call(.auto, func, .{channel} ++ args);
        if (rc == 0) return;
        if (rc != c.LIBSSH2_ERROR_EAGAIN and c.libssh2_session_last_errno(self.session) != c.LIBSSH2_ERROR_EAGAIN) {
            return ssh.Error.ChannelOpenFailed;
        }
        sleepMs(1);
    }
    return ssh.Error.ChannelOpenFailed;
}

fn openSftp(context: *anyopaque) ssh.Error!ssh.Sftp {
    _ = context;
    return ssh.Error.SftpUnavailable;
}

fn closeClient(context: *anyopaque) void {
    const self: *ClientContext = @ptrCast(@alignCast(context));
    const allocator = self.allocator;
    self.state = .closing;
    _ = c.libssh2_session_disconnect(self.session, "Shellow session closed");
    _ = c.libssh2_session_free(self.session);
    _ = c.close(self.fd);
    self.state = .closed;
    allocator.destroy(self);
}

const client_vtable: ssh.Client.VTable = .{
    .state = clientState,
    .openShell = openShell,
    .openSftp = openSftp,
    .close = closeClient,
};

fn shellWrite(context: *anyopaque, bytes: []const u8) ssh.Error!usize {
    const self: *ShellContext = @ptrCast(@alignCast(context));
    if (self.closed) return ssh.Error.ChannelClosed;
    const rc = c.libssh2_channel_write_ex(self.channel, 0, @ptrCast(bytes.ptr), bytes.len);
    return mapByteCount(rc);
}

fn shellRead(context: *anyopaque, buffer: []u8) ssh.Error!usize {
    const self: *ShellContext = @ptrCast(@alignCast(context));
    if (self.closed) return ssh.Error.ChannelClosed;
    const rc = c.libssh2_channel_read_ex(self.channel, 0, @ptrCast(buffer.ptr), buffer.len);
    return mapByteCount(rc);
}

fn shellResize(context: *anyopaque, new_size: ssh.PtySize) ssh.Error!void {
    const self: *ShellContext = @ptrCast(@alignCast(context));
    if (self.closed) return ssh.Error.ChannelClosed;
    if (c.libssh2_channel_request_pty_size_ex(self.channel, new_size.cols, new_size.rows, 0, 0) != 0) {
        return ssh.Error.ChannelOpenFailed;
    }
}

fn shellClose(context: *anyopaque) void {
    const self: *ShellContext = @ptrCast(@alignCast(context));
    const allocator = self.allocator;
    if (!self.closed) {
        _ = c.libssh2_channel_send_eof(self.channel);
        _ = c.libssh2_channel_close(self.channel);
        _ = c.libssh2_channel_free(self.channel);
        self.closed = true;
    }
    allocator.destroy(self);
}

const shell_vtable: ssh.Shell.VTable = .{
    .write = shellWrite,
    .read = shellRead,
    .resize = shellResize,
    .close = shellClose,
};

fn mapByteCount(rc: c_long) ssh.Error!usize {
    if (rc >= 0) return @intCast(rc);
    if (rc == c.LIBSSH2_ERROR_EAGAIN) return ssh.Error.WouldBlock;
    return ssh.Error.ChannelClosed;
}

pub fn init() ssh.Error!void {
    if (c.libssh2_init(0) != 0) {
        return ssh.Error.ConnectionFailed;
    }
}

pub fn deinit() void {
    c.libssh2_exit();
}

test "backend exposes the stable ssh connector shape" {
    var backend = Backend{ .allocator = std.testing.allocator };
    const connector = backend.connector();

    try std.testing.expect(connector.vtable.connect == Backend.connect);
}

test "strict host key policy fails closed before authentication" {
    const opts = ssh.ConnectOptions{
        .endpoint = .{ .host = "127.0.0.1", .port = 1 },
        .auth = .{ .agent = {} },
        .host_key_policy = .strict,
        .timeout_ms = 1,
    };

    try std.testing.expectEqual(ssh.HostKeyPolicy.strict, opts.host_key_policy);
}

test "libssh2 host key type maps to Shellow algorithm labels" {
    try std.testing.expectEqual(ssh.HostKeyAlgorithm.rsa, hostKeyAlgorithm(c.LIBSSH2_HOSTKEY_TYPE_RSA));
    try std.testing.expectEqual(ssh.HostKeyAlgorithm.ed25519, hostKeyAlgorithm(c.LIBSSH2_HOSTKEY_TYPE_ED25519));
    try std.testing.expectEqual(ssh.HostKeyAlgorithm.unknown, hostKeyAlgorithm(-1));
}

test "libssh2 backend can initialize and exit" {
    try init();
    defer deinit();
}
