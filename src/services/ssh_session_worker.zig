const std = @import("std");
const profile = @import("../core/profile.zig");
const ssh = @import("../protocols/ssh.zig");
const terminal = @import("../terminal/terminal.zig");
const ssh_session = @import("ssh_session.zig");

const max_pending_input_bytes = 1024 * 1024;

pub const State = enum(u8) {
    idle,
    starting,
    resolving,
    connecting,
    verifying_host_key,
    authenticating,
    opening_shell,
    connected,
    stopping,
    stopped,
    failed,
};

pub const SshSessionWorker = struct {
    allocator: std.mem.Allocator,
    connection: profile.ConnectionProfile,
    options: ssh_session.Options,
    thread: ?std.Thread = null,
    state_raw: std.atomic.Value(u8) = .init(@intFromEnum(State.idle)),
    stop_requested: std.atomic.Value(bool) = .init(false),
    snapshot_lock: std.atomic.Mutex = .unlocked,
    snapshot_cache: ?terminal.Snapshot = null,
    snapshot_generation: u64 = 0,
    input_lock: std.atomic.Mutex = .unlocked,
    pending_input: std.ArrayList(u8) = .empty,
    mouse_lock: std.atomic.Mutex = .unlocked,
    pending_mouse: std.ArrayList(terminal.MouseEvent) = .empty,
    resize_lock: std.atomic.Mutex = .unlocked,
    pending_resize: ?ssh.PtySize = null,
    clear_scrollback_requested: std.atomic.Value(bool) = .init(false),
    last_error: ?ssh_session.Error = null,

    pub fn create(
        allocator: std.mem.Allocator,
        connection: profile.ConnectionProfile,
        options: ssh_session.Options,
    ) !*SshSessionWorker {
        const worker = try allocator.create(SshSessionWorker);
        errdefer allocator.destroy(worker);

        worker.* = .{
            .allocator = allocator,
            .connection = try connection.clone(allocator),
            .options = options,
        };
        return worker;
    }

    pub fn destroy(self: *SshSessionWorker) void {
        self.requestStop();
        self.join();
        self.clearSnapshotCache();
        self.pending_input.deinit(self.allocator);
        self.pending_mouse.deinit(self.allocator);
        self.connection.deinit(self.allocator);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn start(self: *SshSessionWorker) !void {
        if (self.thread != null) return;
        self.setState(.starting);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn requestStop(self: *SshSessionWorker) void {
        self.stop_requested.store(true, .release);
    }

    pub fn join(self: *SshSessionWorker) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    pub fn state(self: *const SshSessionWorker) State {
        return @enumFromInt(self.state_raw.load(.acquire));
    }

    pub fn queueInput(self: *SshSessionWorker, bytes: []const u8) !void {
        self.lockInput();
        defer self.unlockInput();
        const remaining = max_pending_input_bytes - @min(self.pending_input.items.len, max_pending_input_bytes);
        if (bytes.len > remaining) return error.InputQueueFull;
        try self.pending_input.appendSlice(self.allocator, bytes);
    }

    pub fn queueMouse(self: *SshSessionWorker, event: terminal.MouseEvent) !void {
        self.lockMouse();
        defer self.unlockMouse();
        try self.pending_mouse.append(self.allocator, event);
    }

    pub fn queueResize(self: *SshSessionWorker, size: ssh.PtySize) void {
        self.lockResize();
        defer self.unlockResize();
        self.pending_resize = size;
    }

    pub fn queueClearScrollback(self: *SshSessionWorker) void {
        self.clear_scrollback_requested.store(true, .release);
    }

    pub fn copySnapshot(self: *SshSessionWorker, allocator: std.mem.Allocator) !?terminal.Snapshot {
        self.lockSnapshot();
        defer self.unlockSnapshot();

        const cached = self.snapshot_cache orelse return null;
        const cells = try allocator.dupe(terminal.Cell, cached.cells);
        errdefer allocator.free(cells);
        const scrollback_cells = try allocator.dupe(terminal.Cell, cached.scrollback_cells);
        errdefer allocator.free(scrollback_cells);
        const title = if (cached.title) |title| try allocator.dupe(u8, title) else null;
        return .{
            .allocator = allocator,
            .generation = cached.generation,
            .size = cached.size,
            .cells = cells,
            .scrollback_cells = scrollback_cells,
            .scrollback_rows = cached.scrollback_rows,
            .alternate_screen = cached.alternate_screen,
            .bracketed_paste = cached.bracketed_paste,
            .mouse_mode = cached.mouse_mode,
            .cursor = cached.cursor,
            .title = title,
        };
    }

    fn run(self: *SshSessionWorker) void {
        var session = ssh_session.SshSession.init(self.allocator);
        defer session.deinit();

        self.setState(.resolving);
        session.open(self.connection, self.options) catch |err| {
            self.last_error = session.last_error orelse err;
            self.setState(.failed);
            return;
        };
        self.setState(.connected);
        self.cacheSnapshot(&session) catch {};

        var buffer: [8192]u8 = undefined;
        var input_buffer: [4096]u8 = undefined;
        while (!self.stop_requested.load(.acquire)) {
            var active = false;
            if (self.drainResize()) |size| {
                active = true;
                session.resize(size) catch |err| switch (err) {
                    ssh.Error.WouldBlock => {},
                    else => {
                        self.last_error = err;
                        self.setState(.failed);
                        return;
                    },
                };
            }

            active = (self.writePendingInput(&session, &input_buffer) catch |err| {
                self.last_error = err;
                self.setState(.failed);
                return;
            }) or active;

            while (self.drainMouse()) |mouse| {
                active = true;
                const bytes = session.encodeMouse(self.allocator, mouse) catch |err| {
                    self.last_error = err;
                    self.setState(.failed);
                    return;
                };
                defer self.allocator.free(bytes);
                if (bytes.len == 0) continue;
                self.queueInput(bytes) catch {
                    self.last_error = ssh_session.Error.ConnectionFailed;
                    self.setState(.failed);
                    return;
                };
                active = (self.writePendingInput(&session, &input_buffer) catch |err| {
                    self.last_error = err;
                    self.setState(.failed);
                    return;
                }) or active;
            }

            if (self.clear_scrollback_requested.swap(false, .acq_rel)) {
                active = true;
                session.clearScrollback() catch |err| {
                    self.last_error = err;
                    self.setState(.failed);
                    return;
                };
            }

            const read_len = session.pumpReadOnce(&buffer) catch |err| switch (err) {
                ssh.Error.WouldBlock => {
                    if (!active) yieldThread();
                    continue;
                },
                else => {
                    self.last_error = err;
                    self.setState(.failed);
                    return;
                },
            };
            if (read_len > 0 or session.dirty) {
                active = true;
                self.cacheSnapshot(&session) catch {};
                session.dirty = false;
            }
            if (!active) yieldThread();
        }

        self.setState(.stopping);
        self.setState(.stopped);
    }

    fn setState(self: *SshSessionWorker, new_state: State) void {
        self.state_raw.store(@intFromEnum(new_state), .release);
    }

    fn cacheSnapshot(self: *SshSessionWorker, session: *ssh_session.SshSession) !void {
        var shot = try session.snapshot(self.allocator);
        errdefer shot.deinit();

        self.lockSnapshot();
        defer self.unlockSnapshot();

        if (self.snapshot_cache) |*cached| {
            cached.deinit();
        }
        self.snapshot_generation +%= 1;
        shot.generation = self.snapshot_generation;
        self.snapshot_cache = shot;
    }

    fn clearSnapshotCache(self: *SshSessionWorker) void {
        self.lockSnapshot();
        defer self.unlockSnapshot();

        if (self.snapshot_cache) |*cached| {
            cached.deinit();
            self.snapshot_cache = null;
        }
        self.snapshot_generation +%= 1;
    }

    fn lockSnapshot(self: *SshSessionWorker) void {
        while (!self.snapshot_lock.tryLock()) {
            yieldThread();
        }
    }

    fn unlockSnapshot(self: *SshSessionWorker) void {
        self.snapshot_lock.unlock();
    }

    fn writePendingInput(self: *SshSessionWorker, session: *ssh_session.SshSession, buffer: []u8) ssh_session.Error!bool {
        const input_len = self.peekInput(buffer);
        if (input_len == 0) return false;
        const written = session.writeInput(buffer[0..input_len]) catch |err| switch (err) {
            ssh.Error.WouldBlock => return true,
            else => return err,
        };
        if (written > 0) self.consumeInput(written);
        return true;
    }

    fn peekInput(self: *SshSessionWorker, buffer: []u8) usize {
        self.lockInput();
        defer self.unlockInput();

        const len = @min(buffer.len, self.pending_input.items.len);
        if (len == 0) return 0;
        @memcpy(buffer[0..len], self.pending_input.items[0..len]);
        return len;
    }

    fn consumeInput(self: *SshSessionWorker, len: usize) void {
        self.lockInput();
        defer self.unlockInput();

        const consumed = @min(len, self.pending_input.items.len);
        if (consumed == 0) return;
        self.pending_input.replaceRangeAssumeCapacity(0, consumed, &.{});
    }

    fn drainMouse(self: *SshSessionWorker) ?terminal.MouseEvent {
        self.lockMouse();
        defer self.unlockMouse();

        if (self.pending_mouse.items.len == 0) return null;
        return self.pending_mouse.orderedRemove(0);
    }

    fn drainResize(self: *SshSessionWorker) ?ssh.PtySize {
        self.lockResize();
        defer self.unlockResize();

        const size = self.pending_resize orelse return null;
        self.pending_resize = null;
        return size;
    }

    fn lockInput(self: *SshSessionWorker) void {
        while (!self.input_lock.tryLock()) {
            yieldThread();
        }
    }

    fn unlockInput(self: *SshSessionWorker) void {
        self.input_lock.unlock();
    }

    fn lockMouse(self: *SshSessionWorker) void {
        while (!self.mouse_lock.tryLock()) {
            yieldThread();
        }
    }

    fn unlockMouse(self: *SshSessionWorker) void {
        self.mouse_lock.unlock();
    }

    fn lockResize(self: *SshSessionWorker) void {
        while (!self.resize_lock.tryLock()) {
            yieldThread();
        }
    }

    fn unlockResize(self: *SshSessionWorker) void {
        self.resize_lock.unlock();
    }
};

fn yieldThread() void {
    std.Thread.yield() catch {};
}

test "worker owns a cloned connection profile" {
    var fake_options = ssh_session.Options{
        .connector = .{ .context = undefined, .vtable = undefined },
        .terminal_factory = .{ .context = undefined, .vtable = undefined },
        .host_key_policy = .insecure_accept_any,
    };
    _ = &fake_options;

    var draft = profile.ProfileDraft{};
    draft.reset();
    profile.setBuffer(&draft.name, "Worker SSH");
    profile.setBuffer(&draft.host, "example.test");
    profile.setBuffer(&draft.username, "dev");
    profile.setBuffer(&draft.password, "pw");

    const connection = try draft.toProfile(std.testing.allocator, 1);
    defer connection.deinit(std.testing.allocator);

    const worker = try SshSessionWorker.create(std.testing.allocator, connection, fake_options);
    defer worker.destroy();

    try std.testing.expectEqual(State.idle, worker.state());
    try std.testing.expect(worker.connection.base.host.ptr != connection.base.host.ptr);
}

test "session worker input queue only consumes bytes after confirmed write" {
    var fake_options = ssh_session.Options{
        .connector = .{ .context = undefined, .vtable = undefined },
        .terminal_factory = .{ .context = undefined, .vtable = undefined },
        .host_key_policy = .insecure_accept_any,
    };
    _ = &fake_options;

    var draft = profile.ProfileDraft{};
    draft.reset();
    profile.setBuffer(&draft.name, "Worker SSH");
    profile.setBuffer(&draft.host, "example.test");
    profile.setBuffer(&draft.username, "dev");
    profile.setBuffer(&draft.password, "pw");

    const connection = try draft.toProfile(std.testing.allocator, 1);
    defer connection.deinit(std.testing.allocator);

    const worker = try SshSessionWorker.create(std.testing.allocator, connection, fake_options);
    defer worker.destroy();

    try worker.queueInput("abcdef");

    var buffer: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), worker.peekInput(&buffer));
    try std.testing.expectEqualStrings("abcd", buffer[0..4]);

    try std.testing.expectEqual(@as(usize, 4), worker.peekInput(&buffer));
    try std.testing.expectEqualStrings("abcd", buffer[0..4]);

    worker.consumeInput(2);
    try std.testing.expectEqual(@as(usize, 4), worker.peekInput(&buffer));
    try std.testing.expectEqualStrings("cdef", buffer[0..4]);

    worker.consumeInput(32);
    try std.testing.expectEqual(@as(usize, 0), worker.peekInput(&buffer));
}
