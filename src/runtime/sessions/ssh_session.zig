const std = @import("std");
const profile = @import("../../core/profile.zig");
const ssh = @import("../../contracts/ssh.zig");
const terminal = @import("../../contracts/terminal_emulator.zig");

pub const Error = error{
    MissingCredentials,
    TerminalInitFailed,
    TerminalWriteFailed,
    SnapshotFailed,
} || ssh.Error;

pub const Options = struct {
    connector: ssh.Connector,
    terminal_factory: TerminalFactory,
    io: ?std.Io = null,
    host_key_verifier: ?ssh.HostKeyVerifier = null,
    host_key_policy: ssh.HostKeyPolicy = .strict,
    shell_size: ssh.PtySize = .{ .cols = 100, .rows = 30 },
    download_path: []const u8 = "",
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

pub fn authFromProfile(connection: profile.ConnectionProfile) Error!ssh.Auth {
    return switch (connection.auth_type) {
        .password => if (connection.password.len == 0)
            Error.MissingCredentials
        else
            .{ .password = .{ .username = connection.base.username, .password = connection.password } },
        .private_key => if (connection.private_key_path.len == 0)
            Error.MissingCredentials
        else
            .{ .private_key = .{
                .username = connection.base.username,
                .private_key_path = connection.private_key_path,
                .passphrase = if (connection.private_key_passphrase.len == 0) null else connection.private_key_passphrase,
            } },
        .agent => .{ .agent = .{ .username = connection.base.username } },
    };
}

test "private key auth from profile includes path and passphrase" {
    const item = profile.ConnectionProfile{
        .base = .{
            .id = 1,
            .name = "Key Login",
            .host = "example.test",
            .port = 22,
            .username = "dev",
        },
        .auth_type = .private_key,
        .private_key_path = "/Users/dev/.ssh/id_ed25519",
        .private_key_passphrase = "phrase",
    };

    const auth = try authFromProfile(item);
    switch (auth) {
        .private_key => |key| {
            try std.testing.expectEqualStrings("dev", key.username);
            try std.testing.expectEqualStrings("/Users/dev/.ssh/id_ed25519", key.private_key_path);
            try std.testing.expectEqualStrings("phrase", key.passphrase orelse "");
        },
        else => return error.UnexpectedAuth,
    }
}

test "agent auth from profile includes username" {
    const item = profile.ConnectionProfile{
        .base = .{
            .id = 1,
            .name = "Agent Login",
            .host = "example.test",
            .port = 22,
            .username = "dev",
        },
        .auth_type = .agent,
    };

    const auth = try authFromProfile(item);
    switch (auth) {
        .agent => |agent| try std.testing.expectEqualStrings("dev", agent.username),
        else => return error.UnexpectedAuth,
    }
}
