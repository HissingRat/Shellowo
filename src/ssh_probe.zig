const std = @import("std");

const known_hosts_store = @import("security/known_hosts.zig");
const libssh2_backend = @import("protocols/libssh2_backend.zig");
const ssh = @import("protocols/ssh.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var arg_it = std.process.Args.Iterator.init(init.args);
    var args: [5][]const u8 = undefined;
    var arg_count: usize = 0;
    while (arg_it.next()) |arg| {
        if (arg_count < args.len) args[arg_count] = arg;
        arg_count += 1;
    }

    if (arg_count != 5) {
        std.debug.print("usage: {s} host port username password\n", .{args[0]});
        return error.InvalidArguments;
    }

    const host = args[1];
    const port = try std.fmt.parseInt(u16, args[2], 10);
    const username = args[3];
    const password = args[4];

    try libssh2_backend.init();
    defer libssh2_backend.deinit();

    var known_hosts = known_hosts_store.KnownHosts.init(allocator);
    defer known_hosts.deinit();
    known_hosts.trust_missing = true;

    var backend = libssh2_backend.Backend{ .allocator = allocator };
    const client = try backend.connector().connect(allocator, .{
        .endpoint = .{ .host = host, .port = port },
        .auth = .{ .password = .{ .username = username, .password = password } },
        .host_key_policy = .trust_on_first_use,
        .host_key_verifier = known_hosts.verifier(),
        .timeout_ms = 10_000,
    });
    defer client.close();

    const shell = try client.openShell(.{
        .size = .{ .cols = 100, .rows = 30 },
    });
    defer shell.close();

    var buffer: [8192]u8 = undefined;
    var collected: [16384]u8 = undefined;
    var collected_len: usize = 0;
    var sent_command = false;
    var attempts: usize = 0;
    while (attempts < 500) : (attempts += 1) {
        if (!sent_command and attempts >= 10) {
            _ = try shell.write("printf shellow_probe_ok; uname -s; exit\n");
            sent_command = true;
        }

        const len = shell.read(&buffer) catch |err| switch (err) {
            ssh.Error.WouldBlock => {
                sleepMs(20);
                continue;
            },
            else => return err,
        };
        if (len == 0) {
            sleepMs(20);
            continue;
        }

        const copy_len = @min(collected.len - collected_len, len);
        @memcpy(collected[collected_len .. collected_len + copy_len], buffer[0..copy_len]);
        collected_len += copy_len;

        if (std.mem.indexOf(u8, collected[0..collected_len], "shellow_probe_ok") != null) {
            std.debug.print("{s}\n", .{collected[0..collected_len]});
            return;
        }
        if (collected_len == collected.len) break;
    }

    std.debug.print("{s}\n", .{collected[0..collected_len]});
    return error.ProbeTimedOut;
}

fn sleepMs(ms: c_long) void {
    const request: std.c.timespec = .{
        .sec = @divTrunc(ms, 1000),
        .nsec = @rem(ms, 1000) * std.time.ns_per_ms,
    };
    _ = std.c.nanosleep(&request, null);
}
