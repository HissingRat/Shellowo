const std = @import("std");

const known_hosts_store = @import("../src/security/known_hosts.zig");
const libssh2_backend = @import("../src/backends/ssh/libssh2.zig");
const profile = @import("../src/core/profile.zig");
const ssh_session = @import("../src/runtime/sessions/ssh_session.zig");
const ssh_workspace_worker = @import("../src/runtime/sessions/ssh_workspace_worker.zig");
const libvterm_backend = @import("../src/backends/terminal/libvterm.zig");
const terminal = @import("../src/contracts/terminal_emulator.zig");

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

    try libssh2_backend.init();
    defer libssh2_backend.deinit();

    var known_hosts = known_hosts_store.KnownHosts.init(allocator);
    defer known_hosts.deinit();
    known_hosts.trust_missing = true;

    var ssh_backend = libssh2_backend.Backend{ .allocator = allocator };
    var term_backend = libvterm_backend.Backend{ .allocator = allocator };

    var draft = profile.ProfileDraft{};
    draft.reset();
    profile.setBuffer(&draft.name, "Worker Probe");
    profile.setBuffer(&draft.host, argv[1]);
    draft.port = try std.fmt.parseInt(u16, argv[2], 10);
    profile.setBuffer(&draft.username, argv[3]);
    profile.setBuffer(&draft.password, argv[4]);

    const connection = try draft.toProfile(allocator, 1);
    defer connection.deinit(allocator);

    const worker = try ssh_workspace_worker.SshWorkspaceWorker.create(allocator, connection, .{
        .connector = ssh_backend.connector(),
        .terminal_factory = terminalFactory(&term_backend),
        .host_key_verifier = known_hosts.verifier(),
        .host_key_policy = .trust_on_first_use,
    });
    defer worker.destroy();

    try worker.start();
    try waitConnected(worker);
    const slot_id: u64 = 1;
    try worker.queueInput(slot_id, "printf shellow_worker_probe_ok; uname -s; exit\n");

    var attempts: usize = 0;
    while (attempts < 500) : (attempts += 1) {
        if (worker.state() == .failed) return worker.last_error orelse error.WorkerFailed;

        var snapshot = try worker.copySnapshot(allocator, slot_id);
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

fn waitConnected(worker: *ssh_workspace_worker.SshWorkspaceWorker) !void {
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
    var threaded: Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();
    io.sleep(.fromMilliseconds(ms), .awake) catch {};
}

// fn sleepMs(ms: c_long) void {
//     const request: std.c.timespec = .{
//         .sec = @divTrunc(ms, 1000),
//         .nsec = @rem(ms, 1000) * std.time.ns_per_ms,
//     };
//     _ = std.c.nanosleep(&request, null);
// }
