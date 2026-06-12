const std = @import("std");

const known_hosts_store = @import("security/known_hosts.zig");
const libssh2_backend = @import("protocols/libssh2_backend.zig");
const ssh = @import("protocols/ssh.zig");

const Io = std.Io;

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    const argv = try init.args.toSlice(allocator);
    defer allocator.free(argv);

    if (argv.len != 5) {
        std.debug.print("usage: {s} host port username password\n", .{argv[0]});
        return error.InvalidArguments;
    }

    const host = argv[1];
    const port = try std.fmt.parseInt(u16, argv[2], 10);
    const username = argv[3];
    const password = argv[4];

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
    var threaded: Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();
    io.sleep(.fromMilliseconds(ms), .awake) catch {};
}
