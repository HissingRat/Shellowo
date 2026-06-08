const std = @import("std");

const known_hosts_store = @import("security/known_hosts.zig");
const libssh2_backend = @import("protocols/libssh2_backend.zig");
const profile = @import("core/profile.zig");
const ssh_session = @import("services/ssh_session.zig");
const ssh_session_worker = @import("services/ssh_session_worker.zig");
const libvterm_backend = @import("terminal/libvterm_backend.zig");
const terminal = @import("terminal/terminal.zig");

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

    try libssh2_backend.init();
    defer libssh2_backend.deinit();

    var known_hosts = known_hosts_store.KnownHosts.init(allocator);
    defer known_hosts.deinit();
    known_hosts.trust_missing = true;

    var ssh_backend = libssh2_backend.Backend{ .allocator = allocator };
    var term_backend = libvterm_backend.Backend{ .allocator = allocator };

    var draft = profile.ProfileDraft{};
    draft.reset(.ssh);
    profile.setBuffer(&draft.name, "Worker Probe");
    profile.setBuffer(&draft.host, args[1]);
    draft.port = try std.fmt.parseInt(u16, args[2], 10);
    profile.setBuffer(&draft.username, args[3]);
    profile.setBuffer(&draft.password, args[4]);

    const connection = try draft.toProfile(allocator, 1);
    defer connection.deinit(allocator);

    const worker = try ssh_session_worker.SshSessionWorker.create(allocator, connection, .{
        .connector = ssh_backend.connector(),
        .terminal_factory = terminalFactory(&term_backend),
        .host_key_verifier = known_hosts.verifier(),
        .host_key_policy = .trust_on_first_use,
    });
    defer worker.destroy();

    try worker.start();
    try waitConnected(worker);
    try worker.queueInput("printf shellow_worker_probe_ok; uname -s; exit\n");

    var attempts: usize = 0;
    while (attempts < 500) : (attempts += 1) {
        if (worker.state() == .failed) return worker.last_error orelse error.WorkerFailed;

        var snapshot = try worker.copySnapshot(allocator);
        defer if (snapshot) |*shot| shot.deinit();

        if (snapshot) |shot| {
            var text_buf: [4096]u8 = undefined;
            const text = flattenSnapshot(shot, &text_buf);
            if (std.mem.indexOf(u8, text, "shellow_worker_probe_ok") != null) {
                std.debug.print("{s}\n", .{text});
                return;
            }
        }
        sleepMs(20);
    }

    return error.ProbeTimedOut;
}

fn waitConnected(worker: *ssh_session_worker.SshSessionWorker) !void {
    var attempts: usize = 0;
    while (attempts < 500) : (attempts += 1) {
        switch (worker.state()) {
            .connected => return,
            .failed => return worker.last_error orelse error.WorkerFailed,
            else => sleepMs(20),
        }
    }
    return error.ProbeTimedOut;
}

fn terminalFactory(backend: *libvterm_backend.Backend) ssh_session.TerminalFactory {
    return .{
        .context = backend,
        .vtable = &terminal_factory_vtable,
    };
}

fn createTerminal(context: *anyopaque, allocator: std.mem.Allocator, size: terminal.Size) terminal.Error!terminal.Emulator {
    _ = allocator;
    const backend: *libvterm_backend.Backend = @ptrCast(@alignCast(context));
    return backend.create(size);
}

const terminal_factory_vtable: ssh_session.TerminalFactory.VTable = .{
    .create = createTerminal,
};

fn flattenSnapshot(snapshot: terminal.Snapshot, buffer: []u8) []const u8 {
    var len: usize = 0;
    for (0..snapshot.size.rows) |row| {
        for (0..snapshot.size.cols) |col| {
            if (len >= buffer.len) return buffer[0..len];
            const cell = snapshot.cellAt(@intCast(row), @intCast(col)) orelse continue;
            const cp = cell.codepoint;
            buffer[len] = if (cp >= 0x20 and cp <= 0x7e) @intCast(cp) else ' ';
            len += 1;
        }
        if (len >= buffer.len) return buffer[0..len];
        buffer[len] = '\n';
        len += 1;
    }
    return buffer[0..len];
}

fn sleepMs(ms: c_long) void {
    const request: std.c.timespec = .{
        .sec = @divTrunc(ms, 1000),
        .nsec = @rem(ms, 1000) * std.time.ns_per_ms,
    };
    _ = std.c.nanosleep(&request, null);
}
