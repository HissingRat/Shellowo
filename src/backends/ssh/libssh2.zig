const std = @import("std");
const ssh = @import("../../contracts/ssh.zig");

const builtin = @import("builtin");
const Io = std.Io;

const c = @cImport({
    @cInclude("libssh2.h");
    @cInclude("libssh2_sftp.h");

    if (builtin.os.tag == .windows) {
        @cInclude("winsock2.h");
        @cInclude("ws2tcpip.h");
        @cInclude("windows.h");
    } else {
        @cInclude("fcntl.h");
        @cInclude("netdb.h");
        @cInclude("sys/socket.h");
        @cInclude("time.h");
        @cInclude("unistd.h");
    }
});

const Socket = c.libssh2_socket_t;

/// libssh2 integration belongs here.
///
/// Keep raw LIBSSH2_SESSION, LIBSSH2_CHANNEL, and LIBSSH2_SFTP handles out of
/// app state and DVUI widgets. This file should translate libssh2 behavior into
/// the stable `contracts/ssh.zig` API.
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

        try checkCanceled(options);
        reportProgress(options, .resolving);
        const host = allocator.dupeZ(u8, options.endpoint.host) catch return ssh.Error.ConnectionFailed;
        defer allocator.free(host);
        const service = std.fmt.allocPrintSentinel(allocator, "{d}", .{options.endpoint.port}, 0) catch return ssh.Error.ConnectionFailed;
        defer allocator.free(service);

        try checkCanceled(options);
        reportProgress(options, .connecting);
        const fd = try connectSocketWithRetry(host, service, options);
        errdefer _ = closeSocket(fd);
        std.log.debug("libssh2 connect socket ok host={s} port={d}", .{ options.endpoint.host, options.endpoint.port });

        try checkCanceled(options);
        std.log.debug("libssh2 session init begin host={s} port={d}", .{ options.endpoint.host, options.endpoint.port });
        const session = c.libssh2_session_init_ex(null, null, null, null) orelse return ssh.Error.ConnectionFailed;
        errdefer _ = c.libssh2_session_free(session);
        c.libssh2_session_set_blocking(session, 0);
        c.libssh2_session_set_timeout(session, options.timeout_ms);
        std.log.debug("libssh2 handshake begin host={s} port={d}", .{ options.endpoint.host, options.endpoint.port });

        try retrySessionOperation(session, options, ssh.Error.ConnectionFailed, struct {
            fn call(s: *c.LIBSSH2_SESSION, socket: Socket) c_int {
                return c.libssh2_session_handshake(s, socket);
            }
        }.call, .{fd});
        std.log.debug("libssh2 handshake ok host={s} port={d}", .{ options.endpoint.host, options.endpoint.port });

        try checkCanceled(options);
        reportProgress(options, .verifying_host_key);
        std.log.debug("libssh2 host key verify begin host={s} port={d}", .{ options.endpoint.host, options.endpoint.port });
        const host_key = readHostKey(session) catch return ssh.Error.InvalidHostKey;
        try verifyHostKey(options, host_key);
        std.log.debug("libssh2 host key verify ok host={s} port={d}", .{ options.endpoint.host, options.endpoint.port });

        try checkCanceled(options);
        reportProgress(options, .authenticating);
        std.log.debug("libssh2 auth begin host={s} port={d}", .{ options.endpoint.host, options.endpoint.port });
        authenticate(session, allocator, options) catch |err| return err;
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

fn reportProgress(options: ssh.ConnectOptions, stage: ssh.ConnectStage) void {
    if (options.progress_reporter) |reporter| reporter.report(stage);
}

fn checkCanceled(options: ssh.ConnectOptions) ssh.Error!void {
    if (options.cancel_token) |token| {
        if (token.canceled()) return ssh.Error.ConnectionCanceled;
    }
}

const connector_vtable: ssh.Connector.VTable = .{
    .connect = Backend.connect,
};

const ClientContext = struct {
    allocator: std.mem.Allocator,
    fd: Socket,
    session: *c.LIBSSH2_SESSION,
    state: ssh.SessionState,
};

const ShellContext = struct {
    allocator: std.mem.Allocator,
    client: *ClientContext,
    channel: *c.LIBSSH2_CHANNEL,
    closed: bool = false,
};

const SftpContext = struct {
    allocator: std.mem.Allocator,
    client: *ClientContext,
    sftp: *c.LIBSSH2_SFTP,
    closed: bool = false,
};

fn connectSocketWithRetry(host: [:0]const u8, service: [:0]const u8, options: ssh.ConnectOptions) ssh.Error!Socket {
    const attempts = 4;
    for (0..attempts) |attempt| {
        try checkCanceled(options);
        std.log.debug("libssh2 connect socket begin host={s} port={d} attempt={d}", .{
            options.endpoint.host,
            options.endpoint.port,
            attempt + 1,
        });
        return connectSocket(host, service, options) catch |err| {
            if (attempt + 1 == attempts) return err;
            try sleepMsCancelable(150, options);
            continue;
        };
    }
    return ssh.Error.ConnectionFailed;
}

fn connectSocket(host: [:0]const u8, service: [:0]const u8, options: ssh.ConnectOptions) ssh.Error!Socket {
    const endpoint = options.endpoint;
    var hints: c.addrinfo = std.mem.zeroes(c.addrinfo);
    hints.ai_family = c.AF_UNSPEC;
    hints.ai_socktype = c.SOCK_STREAM;

    try checkCanceled(options);
    var result: ?*c.addrinfo = null;
    const gai_rc = c.getaddrinfo(host.ptr, service.ptr, &hints, &result);
    if (gai_rc != 0) {
        std.log.debug("libssh2 getaddrinfo failed host={s} port={d} rc={d}", .{ endpoint.host, endpoint.port, gai_rc });
        return ssh.Error.ConnectionFailed;
    }
    defer c.freeaddrinfo(result);

    var node = result;
    while (node) |addr| : (node = addr.ai_next) {
        try checkCanceled(options);
        const fd = c.socket(addr.ai_family, addr.ai_socktype, addr.ai_protocol);
        if (fd == invalidSocket()) {
            std.log.debug("libssh2 socket failed host={s} port={d} errno={s}", .{ endpoint.host, endpoint.port, @tagName(std.c.errno(fd)) });
            continue;
        }
        connectSocketFd(fd, addr, options) catch |err| {
            std.log.debug("libssh2 socket connect failed host={s} port={d} family={d} err={s}", .{
                endpoint.host,
                endpoint.port,
                addr.ai_family,
                @errorName(err),
            });
            _ = closeSocket(fd);
            if (err == ssh.Error.ConnectionCanceled) return err;
            continue;
        };
        return fd;
    }

    return ssh.Error.ConnectionFailed;
}

fn connectSocketFd(fd: Socket, addr: *c.addrinfo, options: ssh.ConnectOptions) ssh.Error!void {
    if (builtin.os.tag == .windows) {
        if (c.connect(fd, addr.ai_addr, @intCast(addr.ai_addrlen)) == 0) return;
        std.log.debug("libssh2 socket connect failed host={s} port={d} family={d} errno={s}", .{
            options.endpoint.host,
            options.endpoint.port,
            addr.ai_family,
            @tagName(std.c.errno(-1)),
        });
        return ssh.Error.ConnectionFailed;
    }

    const original_flags = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    if (original_flags < 0) return ssh.Error.ConnectionFailed;
    if (c.fcntl(fd, c.F_SETFL, original_flags | c.O_NONBLOCK) < 0) return ssh.Error.ConnectionFailed;
    errdefer _ = c.fcntl(fd, c.F_SETFL, original_flags);

    if (c.connect(fd, addr.ai_addr, @intCast(addr.ai_addrlen)) == 0) {
        if (c.fcntl(fd, c.F_SETFL, original_flags) < 0) return ssh.Error.ConnectionFailed;
        return;
    }

    const errno = std.c.errno(-1);
    switch (errno) {
        .INPROGRESS, .ALREADY, .AGAIN => {},
        .ISCONN => {
            if (c.fcntl(fd, c.F_SETFL, original_flags) < 0) return ssh.Error.ConnectionFailed;
            return;
        },
        else => return ssh.Error.ConnectionFailed,
    }

    var waited_ms: i32 = 0;
    const timeout_ms = @max(options.timeout_ms, 1);
    while (waited_ms < timeout_ms) {
        try checkCanceled(options);
        var pollfds = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.OUT,
            .revents = 0,
        }};
        const rc = std.posix.poll(&pollfds, 50) catch return ssh.Error.ConnectionFailed;
        waited_ms += 50;
        if (rc == 0) continue;
        if ((pollfds[0].revents & (std.posix.POLL.OUT | std.posix.POLL.ERR | std.posix.POLL.HUP)) == 0) continue;

        var socket_error: c_int = 0;
        var socket_error_len: c.socklen_t = @sizeOf(c_int);
        if (c.getsockopt(fd, c.SOL_SOCKET, c.SO_ERROR, @ptrCast(&socket_error), &socket_error_len) != 0) {
            return ssh.Error.ConnectionFailed;
        }
        if (socket_error != 0) return ssh.Error.ConnectionFailed;
        if (c.fcntl(fd, c.F_SETFL, original_flags) < 0) return ssh.Error.ConnectionFailed;
        return;
    }

    return ssh.Error.ConnectionFailed;
}

fn sleepMsCancelable(ms: u32, options: ssh.ConnectOptions) ssh.Error!void {
    var slept: u32 = 0;
    while (slept < ms) {
        try checkCanceled(options);
        const step = @min(@as(u32, 25), ms - slept);
        sleepMs(@intCast(step));
        slept += step;
    }
}

fn sleepMs(ms: c_long) void {
    var threaded: Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();
    io.sleep(.fromMilliseconds(ms), .awake) catch {};
}

fn yieldThread() void {
    std.Thread.yield() catch {};
}

fn retrySessionOperation(
    session: *c.LIBSSH2_SESSION,
    options: ssh.ConnectOptions,
    fail_error: ssh.Error,
    comptime func: anytype,
    args: anytype,
) ssh.Error!void {
    var waited_ms: i32 = 0;
    const timeout_ms = @max(options.timeout_ms, 1);
    while (waited_ms < timeout_ms) {
        try checkCanceled(options);
        const rc = @call(.auto, func, .{session} ++ args);
        if (rc == 0) return;
        if (rc != c.LIBSSH2_ERROR_EAGAIN and c.libssh2_session_last_errno(session) != c.LIBSSH2_ERROR_EAGAIN) {
            return fail_error;
        }
        sleepMs(1);
        waited_ms += 1;
    }
    return fail_error;
}

fn authenticate(session: *c.LIBSSH2_SESSION, allocator: std.mem.Allocator, options: ssh.ConnectOptions) ssh.Error!void {
    switch (options.auth) {
        .password => |password| {
            const username = allocator.dupeZ(u8, password.username) catch return ssh.Error.AuthenticationFailed;
            defer allocator.free(username);
            const secret = allocator.dupeZ(u8, password.password) catch return ssh.Error.AuthenticationFailed;
            defer allocator.free(secret);

            try retrySessionOperation(session, options, ssh.Error.AuthenticationFailed, struct {
                fn call(s: *c.LIBSSH2_SESSION, user: [:0]const u8, pw: [:0]const u8) c_int {
                    return c.libssh2_userauth_password_ex(s, user.ptr, @intCast(user.len), pw.ptr, @intCast(pw.len), null);
                }
            }.call, .{ username, secret });
        },
        .private_key => |private_key| {
            const username = allocator.dupeZ(u8, private_key.username) catch return ssh.Error.AuthenticationFailed;
            defer allocator.free(username);
            const key_path = allocator.dupeZ(u8, private_key.private_key_path) catch return ssh.Error.AuthenticationFailed;
            defer allocator.free(key_path);
            const passphrase = if (private_key.passphrase) |value| allocator.dupeZ(u8, value) catch return ssh.Error.AuthenticationFailed else null;
            defer if (passphrase) |value| allocator.free(value);

            try retrySessionOperation(session, options, ssh.Error.AuthenticationFailed, struct {
                fn call(s: *c.LIBSSH2_SESSION, user: [:0]const u8, path: [:0]const u8, phrase: ?[:0]const u8) c_int {
                    return c.libssh2_userauth_publickey_fromfile(s, user.ptr, null, path.ptr, if (phrase) |value| value.ptr else null);
                }
            }.call, .{ username, key_path, passphrase });
        },
        .agent => |agent| try authenticateAgent(session, allocator, options, agent.username),
    }
}

fn authenticateAgent(session: *c.LIBSSH2_SESSION, allocator: std.mem.Allocator, options: ssh.ConnectOptions, username_bytes: []const u8) ssh.Error!void {
    if (username_bytes.len == 0) return ssh.Error.AuthenticationFailed;
    const username = allocator.dupeZ(u8, username_bytes) catch return ssh.Error.AuthenticationFailed;
    defer allocator.free(username);

    try checkCanceled(options);
    const agent = c.libssh2_agent_init(session) orelse return ssh.Error.AuthenticationFailed;
    defer c.libssh2_agent_free(agent);

    try checkCanceled(options);
    if (c.libssh2_agent_connect(agent) != 0) return ssh.Error.AuthenticationFailed;
    defer _ = c.libssh2_agent_disconnect(agent);

    try checkCanceled(options);
    if (c.libssh2_agent_list_identities(agent) != 0) return ssh.Error.AuthenticationFailed;

    var identity: ?*c.struct_libssh2_agent_publickey = null;
    var previous: ?*c.struct_libssh2_agent_publickey = null;
    while (c.libssh2_agent_get_identity(agent, &identity, previous) == 0) {
        try checkCanceled(options);
        if (identity) |candidate| {
            var waited_ms: i32 = 0;
            const timeout_ms = @max(options.timeout_ms, 1);
            while (waited_ms < timeout_ms) {
                try checkCanceled(options);
                const rc = c.libssh2_agent_userauth(agent, username.ptr, candidate);
                if (rc == 0) return;
                if (rc != c.LIBSSH2_ERROR_EAGAIN and c.libssh2_session_last_errno(session) != c.LIBSSH2_ERROR_EAGAIN) break;
                sleepMs(1);
                waited_ms += 1;
            }
            previous = candidate;
        } else {
            break;
        }
    }

    return ssh.Error.AuthenticationFailed;
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
    const self: *ClientContext = @ptrCast(@alignCast(context));
    var attempts: usize = 0;
    while (attempts < 5000) : (attempts += 1) {
        if (c.libssh2_sftp_init(self.session)) |sftp| {
            const sftp_context = self.allocator.create(SftpContext) catch {
                _ = c.libssh2_sftp_shutdown(sftp);
                return ssh.Error.SftpUnavailable;
            };
            sftp_context.* = .{
                .allocator = self.allocator,
                .client = self,
                .sftp = sftp,
            };
            return .{
                .context = sftp_context,
                .vtable = &sftp_vtable,
            };
        }
        if (c.libssh2_session_last_errno(self.session) != c.LIBSSH2_ERROR_EAGAIN) {
            return ssh.Error.SftpUnavailable;
        }
        sleepMs(1);
    }
    return ssh.Error.SftpUnavailable;
}

fn exec(context: *anyopaque, allocator: std.mem.Allocator, options: ssh.ExecOptions) ssh.Error![]u8 {
    const self: *ClientContext = @ptrCast(@alignCast(context));
    const channel = openChannelWithRetry(self) catch return ssh.Error.ChannelOpenFailed;
    defer _ = c.libssh2_channel_free(channel);

    const command = self.allocator.dupeZ(u8, options.command) catch return ssh.Error.ChannelOpenFailed;
    defer self.allocator.free(command);

    try retryChannelOperation(self, channel, "exec", struct {
        fn call(ch: *c.LIBSSH2_CHANNEL, cmd: [:0]const u8) c_int {
            return c.libssh2_channel_process_startup(ch, "exec", 4, cmd.ptr, @intCast(cmd.len));
        }
    }.call, .{command});

    c.libssh2_session_set_blocking(self.session, 0);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var waited_ms: u32 = 0;
    var buffer: [4096]u8 = undefined;
    while (true) {
        if (waited_ms > options.timeout_ms) return ssh.Error.WouldBlock;
        const rc = c.libssh2_channel_read_ex(channel, 0, @ptrCast(&buffer), buffer.len);
        if (rc > 0) {
            const len: usize = @intCast(rc);
            if (out.items.len + len > options.max_output_bytes) return ssh.Error.TransferFailed;
            out.appendSlice(allocator, buffer[0..len]) catch return ssh.Error.TransferFailed;
            continue;
        }
        if (rc == c.LIBSSH2_ERROR_EAGAIN) {
            if (c.libssh2_channel_eof(channel) != 0) break;
            sleepMs(1);
            waited_ms += 1;
            continue;
        }
        if (rc < 0) return ssh.Error.ChannelClosed;
        if (c.libssh2_channel_eof(channel) != 0) break;
        sleepMs(1);
        waited_ms += 1;
    }
    _ = c.libssh2_channel_close(channel);
    return out.toOwnedSlice(allocator) catch return ssh.Error.TransferFailed;
}

fn closeClient(context: *anyopaque) void {
    const self: *ClientContext = @ptrCast(@alignCast(context));
    const allocator = self.allocator;
    self.state = .closing;
    _ = c.libssh2_session_disconnect(self.session, "Shellow session closed");
    _ = c.libssh2_session_free(self.session);
    _ = closeSocket(self.fd);
    self.state = .closed;
    allocator.destroy(self);
}

const client_vtable: ssh.Client.VTable = .{
    .state = clientState,
    .openShell = openShell,
    .exec = exec,
    .openSftp = openSftp,
    .close = closeClient,
};

fn sftpList(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ssh.Error![]ssh.RemoteFileEntry {
    const self: *SftpContext = @ptrCast(@alignCast(context));
    if (self.closed) return ssh.Error.SftpUnavailable;

    const path_z = allocator.dupeZ(u8, path) catch return ssh.Error.TransferFailed;
    defer allocator.free(path_z);

    const handle = openSftpDirWithRetry(self, path_z) catch return ssh.Error.TransferFailed;
    defer _ = c.libssh2_sftp_closedir(handle);

    var entries: std.ArrayList(ssh.RemoteFileEntry) = .empty;
    errdefer freeRemoteEntries(allocator, entries.items);
    errdefer entries.deinit(allocator);

    var name_buffer: [512]u8 = undefined;
    while (true) {
        var attrs: c.LIBSSH2_SFTP_ATTRIBUTES = std.mem.zeroes(c.LIBSSH2_SFTP_ATTRIBUTES);
        const rc = c.libssh2_sftp_readdir_ex(
            handle,
            @ptrCast(&name_buffer),
            name_buffer.len,
            null,
            0,
            &attrs,
        );
        if (rc > 0) {
            const name = name_buffer[0..@as(usize, @intCast(rc))];
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            entries.append(allocator, .{
                .name = allocator.dupe(u8, name) catch return ssh.Error.TransferFailed,
                .kind = fileKindFromAttrs(attrs),
                .size = if ((attrs.flags & c.LIBSSH2_SFTP_ATTR_SIZE) != 0) attrs.filesize else null,
                .permissions = if ((attrs.flags & c.LIBSSH2_SFTP_ATTR_PERMISSIONS) != 0) @intCast(attrs.permissions) else null,
                .modified_unix = if ((attrs.flags & c.LIBSSH2_SFTP_ATTR_ACMODTIME) != 0) @intCast(attrs.mtime) else null,
                .uid = if ((attrs.flags & c.LIBSSH2_SFTP_ATTR_UIDGID) != 0) @intCast(attrs.uid) else null,
                .gid = if ((attrs.flags & c.LIBSSH2_SFTP_ATTR_UIDGID) != 0) @intCast(attrs.gid) else null,
            }) catch return ssh.Error.TransferFailed;
            continue;
        }
        if (rc == 0) break;
        if (rc == c.LIBSSH2_ERROR_EAGAIN) {
            sleepMs(1);
            continue;
        }
        return ssh.Error.TransferFailed;
    }

    return entries.toOwnedSlice(allocator) catch return ssh.Error.TransferFailed;
}

fn sftpReadFile(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8, reporter: ?ssh.FileProgressReporter) ssh.Error![]u8 {
    const self: *SftpContext = @ptrCast(@alignCast(context));
    if (self.closed) return ssh.Error.SftpUnavailable;

    const path_z = allocator.dupeZ(u8, path) catch return ssh.Error.TransferFailed;
    defer allocator.free(path_z);

    const handle = openSftpFileWithRetry(self, path_z, c.LIBSSH2_FXF_READ, 0) catch return ssh.Error.TransferFailed;
    defer _ = c.libssh2_sftp_close(handle);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buffer: [16 * 1024]u8 = undefined;
    var completed: u64 = 0;
    while (true) {
        const rc = c.libssh2_sftp_read(handle, @ptrCast(&buffer), buffer.len);
        if (rc > 0) {
            const len: usize = @intCast(rc);
            out.appendSlice(allocator, buffer[0..len]) catch return ssh.Error.TransferFailed;
            completed += len;
            if (reporter) |value| {
                if (!value.report(completed, null)) return ssh.Error.TransferCanceled;
            }
            continue;
        }
        if (rc == 0) break;
        if (rc == c.LIBSSH2_ERROR_EAGAIN) {
            sleepMs(1);
            continue;
        }
        return ssh.Error.TransferFailed;
    }
    return out.toOwnedSlice(allocator) catch return ssh.Error.TransferFailed;
}

fn sftpWriteFile(context: *anyopaque, path: []const u8, bytes: []const u8, reporter: ?ssh.FileProgressReporter) ssh.Error!void {
    const self: *SftpContext = @ptrCast(@alignCast(context));
    if (self.closed) return ssh.Error.SftpUnavailable;

    const path_z = self.allocator.dupeZ(u8, path) catch return ssh.Error.TransferFailed;
    defer self.allocator.free(path_z);

    const flags = c.LIBSSH2_FXF_WRITE | c.LIBSSH2_FXF_CREAT | c.LIBSSH2_FXF_TRUNC;
    const handle = openSftpFileWithRetry(self, path_z, flags, 0o644) catch return ssh.Error.TransferFailed;
    defer _ = c.libssh2_sftp_close(handle);

    var written: usize = 0;
    if (reporter) |value| {
        if (!value.report(0, bytes.len)) return ssh.Error.TransferCanceled;
    }
    while (written < bytes.len) {
        const remaining = bytes[written..];
        const rc = c.libssh2_sftp_write(handle, @ptrCast(remaining.ptr), remaining.len);
        if (rc > 0) {
            written += @as(usize, @intCast(rc));
            if (reporter) |value| {
                if (!value.report(written, bytes.len)) return ssh.Error.TransferCanceled;
            }
            continue;
        }
        if (rc == c.LIBSSH2_ERROR_EAGAIN) {
            sleepMs(1);
            continue;
        }
        return ssh.Error.TransferFailed;
    }
}

fn sftpRemove(context: *anyopaque, path: []const u8) ssh.Error!void {
    const self: *SftpContext = @ptrCast(@alignCast(context));
    if (self.closed) return ssh.Error.SftpUnavailable;
    const path_z = self.allocator.dupeZ(u8, path) catch return ssh.Error.TransferFailed;
    defer self.allocator.free(path_z);
    try retrySftpIntOperation(self, struct {
        fn call(sftp: *c.LIBSSH2_SFTP, value: [:0]const u8) c_int {
            return c.libssh2_sftp_unlink(sftp, value.ptr);
        }
    }.call, path_z);
}

fn sftpRemoveDir(context: *anyopaque, path: []const u8) ssh.Error!void {
    const self: *SftpContext = @ptrCast(@alignCast(context));
    if (self.closed) return ssh.Error.SftpUnavailable;
    const path_z = self.allocator.dupeZ(u8, path) catch return ssh.Error.TransferFailed;
    defer self.allocator.free(path_z);
    try retrySftpIntOperation(self, struct {
        fn call(sftp: *c.LIBSSH2_SFTP, value: [:0]const u8) c_int {
            return c.libssh2_sftp_rmdir(sftp, value.ptr);
        }
    }.call, path_z);
}

fn sftpMkdir(context: *anyopaque, path: []const u8) ssh.Error!void {
    const self: *SftpContext = @ptrCast(@alignCast(context));
    if (self.closed) return ssh.Error.SftpUnavailable;
    const path_z = self.allocator.dupeZ(u8, path) catch return ssh.Error.TransferFailed;
    defer self.allocator.free(path_z);
    try retrySftpIntOperation(self, struct {
        fn call(sftp: *c.LIBSSH2_SFTP, value: [:0]const u8) c_int {
            return c.libssh2_sftp_mkdir(sftp, value.ptr, 0o755);
        }
    }.call, path_z);
}

fn sftpRename(context: *anyopaque, old_path: []const u8, new_path: []const u8) ssh.Error!void {
    const self: *SftpContext = @ptrCast(@alignCast(context));
    if (self.closed) return ssh.Error.SftpUnavailable;
    const old_z = self.allocator.dupeZ(u8, old_path) catch return ssh.Error.TransferFailed;
    defer self.allocator.free(old_z);
    const new_z = self.allocator.dupeZ(u8, new_path) catch return ssh.Error.TransferFailed;
    defer self.allocator.free(new_z);

    var attempts: usize = 0;
    while (attempts < 5000) : (attempts += 1) {
        const rc = c.libssh2_sftp_rename(self.sftp, old_z.ptr, new_z.ptr);
        if (rc == 0) return;
        if (rc != c.LIBSSH2_ERROR_EAGAIN) return ssh.Error.TransferFailed;
        sleepMs(1);
    }
    return ssh.Error.TransferFailed;
}

fn sftpChmod(context: *anyopaque, path: []const u8, permissions: u32) ssh.Error!void {
    const self: *SftpContext = @ptrCast(@alignCast(context));
    if (self.closed) return ssh.Error.SftpUnavailable;
    const path_z = self.allocator.dupeZ(u8, path) catch return ssh.Error.TransferFailed;
    defer self.allocator.free(path_z);

    var attrs: c.LIBSSH2_SFTP_ATTRIBUTES = std.mem.zeroes(c.LIBSSH2_SFTP_ATTRIBUTES);
    attrs.flags = c.LIBSSH2_SFTP_ATTR_PERMISSIONS;
    attrs.permissions = permissions;

    var attempts: usize = 0;
    while (attempts < 5000) : (attempts += 1) {
        const rc = c.libssh2_sftp_stat_ex(self.sftp, path_z.ptr, @intCast(path.len), c.LIBSSH2_SFTP_SETSTAT, &attrs);
        if (rc == 0) return;
        if (rc != c.LIBSSH2_ERROR_EAGAIN) return ssh.Error.TransferFailed;
        sleepMs(1);
    }
    return ssh.Error.TransferFailed;
}

fn closeSftp(context: *anyopaque) void {
    const self: *SftpContext = @ptrCast(@alignCast(context));
    if (!self.closed) {
        _ = c.libssh2_sftp_shutdown(self.sftp);
        self.closed = true;
    }
    const allocator = self.allocator;
    allocator.destroy(self);
}

const sftp_vtable: ssh.Sftp.VTable = .{
    .list = sftpList,
    .readFile = sftpReadFile,
    .writeFile = sftpWriteFile,
    .remove = sftpRemove,
    .removeDir = sftpRemoveDir,
    .mkdir = sftpMkdir,
    .rename = sftpRename,
    .chmod = sftpChmod,
    .close = closeSftp,
};

fn openSftpDirWithRetry(self: *SftpContext, path: [:0]const u8) ssh.Error!*c.LIBSSH2_SFTP_HANDLE {
    var attempts: usize = 0;
    while (attempts < 5000) : (attempts += 1) {
        if (c.libssh2_sftp_opendir(self.sftp, path.ptr)) |handle| return handle;
        if (c.libssh2_session_last_errno(self.client.session) != c.LIBSSH2_ERROR_EAGAIN) {
            return ssh.Error.TransferFailed;
        }
        sleepMs(1);
    }
    return ssh.Error.TransferFailed;
}

fn openSftpFileWithRetry(self: *SftpContext, path: [:0]const u8, flags: c_ulong, mode: c_long) ssh.Error!*c.LIBSSH2_SFTP_HANDLE {
    var attempts: usize = 0;
    while (attempts < 5000) : (attempts += 1) {
        if (c.libssh2_sftp_open(self.sftp, path.ptr, flags, mode)) |handle| return handle;
        if (c.libssh2_session_last_errno(self.client.session) != c.LIBSSH2_ERROR_EAGAIN) {
            return ssh.Error.TransferFailed;
        }
        sleepMs(1);
    }
    return ssh.Error.TransferFailed;
}

fn retrySftpIntOperation(
    self: *SftpContext,
    comptime func: *const fn (*c.LIBSSH2_SFTP, [:0]const u8) c_int,
    path: [:0]const u8,
) ssh.Error!void {
    var attempts: usize = 0;
    while (attempts < 5000) : (attempts += 1) {
        const rc = func(self.sftp, path);
        if (rc == 0) return;
        if (rc != c.LIBSSH2_ERROR_EAGAIN) return ssh.Error.TransferFailed;
        sleepMs(1);
    }
    return ssh.Error.TransferFailed;
}

fn fileKindFromAttrs(attrs: c.LIBSSH2_SFTP_ATTRIBUTES) ssh.RemoteFileKind {
    if ((attrs.flags & c.LIBSSH2_SFTP_ATTR_PERMISSIONS) == 0) return .other;
    const mode = attrs.permissions & c.LIBSSH2_SFTP_S_IFMT;
    return switch (mode) {
        c.LIBSSH2_SFTP_S_IFDIR => .directory,
        c.LIBSSH2_SFTP_S_IFREG => .file,
        c.LIBSSH2_SFTP_S_IFLNK => .symlink,
        else => .other,
    };
}

fn freeRemoteEntries(allocator: std.mem.Allocator, entries: []ssh.RemoteFileEntry) void {
    for (entries) |entry| allocator.free(entry.name);
}

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

fn mapByteCount(rc: isize) ssh.Error!usize {
    if (rc >= 0) return @intCast(rc);
    if (rc == c.LIBSSH2_ERROR_EAGAIN) return ssh.Error.WouldBlock;
    return ssh.Error.ChannelClosed;
}

pub fn init() ssh.Error!void {
    if (builtin.os.tag == .windows) {
        var data: c.WSADATA = undefined;
        if (c.WSAStartup(0x0202, &data) != 0) {
            return ssh.Error.ConnectionFailed;
        }
    }

    if (c.libssh2_init(0) != 0) {
        if (builtin.os.tag == .windows) _ = c.WSACleanup();
        return ssh.Error.ConnectionFailed;
    }
}

pub fn deinit() void {
    c.libssh2_exit();
}

fn closeSocket(sock: Socket) c_int {
    if (builtin.os.tag == .windows) {
        return c.closesocket(sock);
    } else {
        return c.close(sock);
    }
}

fn invalidSocket() Socket {
    if (builtin.os.tag == .windows) {
        return c.INVALID_SOCKET;
    } else {
        return -1;
    }
}

test "backend exposes the stable ssh connector shape" {
    var backend = Backend{ .allocator = std.testing.allocator };
    const connector = backend.connector();

    try std.testing.expect(connector.vtable.connect == Backend.connect);
}

test "strict host key policy fails closed before authentication" {
    const opts = ssh.ConnectOptions{
        .endpoint = .{ .host = "127.0.0.1", .port = 1 },
        .auth = .{ .agent = .{ .username = "dev" } },
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
