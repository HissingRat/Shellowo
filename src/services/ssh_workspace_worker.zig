const std = @import("std");
const profile = @import("../core/profile.zig");
const terminal_slot = @import("../core/terminal_slot.zig");
const ssh = @import("../protocols/ssh.zig");
const terminal = @import("../terminal/terminal.zig");
const ssh_session = @import("ssh_session.zig");

pub const State = enum(u8) {
    idle,
    starting,
    connected,
    stopping,
    stopped,
    failed,
};

const PtySlot = struct {
    id: terminal_slot.TerminalSlotId,
    ordinal: u16,
    state_raw: std.atomic.Value(u8) = .init(@intFromEnum(State.starting)),
    close_requested: std.atomic.Value(bool) = .init(false),
    shell: ?ssh.Shell = null,
    emulator: ?terminal.Emulator = null,
    snapshot_lock: std.atomic.Mutex = .unlocked,
    snapshot_cache: ?terminal.Snapshot = null,
    input_lock: std.atomic.Mutex = .unlocked,
    pending_input: std.ArrayList(u8) = .empty,
    mouse_lock: std.atomic.Mutex = .unlocked,
    pending_mouse: std.ArrayList(terminal.MouseEvent) = .empty,
    resize_lock: std.atomic.Mutex = .unlocked,
    pending_resize: ?ssh.PtySize = null,
    clear_scrollback_requested: std.atomic.Value(bool) = .init(false),
    last_error: ?ssh_session.Error = null,
    title_buf: [128]u8 = undefined,
    title_len: usize = 0,

    fn create(allocator: std.mem.Allocator, id: terminal_slot.TerminalSlotId, ordinal: u16) !*PtySlot {
        const slot = try allocator.create(PtySlot);
        slot.* = .{ .id = id, .ordinal = ordinal };
        return slot;
    }

    fn destroy(self: *PtySlot, allocator: std.mem.Allocator) void {
        self.closeRuntime();
        self.clearSnapshotCache();
        self.pending_input.deinit(allocator);
        self.pending_mouse.deinit(allocator);
        allocator.destroy(self);
    }

    fn state(self: *const PtySlot) State {
        return @enumFromInt(self.state_raw.load(.acquire));
    }

    fn setState(self: *PtySlot, new_state: State) void {
        self.state_raw.store(@intFromEnum(new_state), .release);
    }

    fn visible(self: *const PtySlot) bool {
        return !self.close_requested.load(.acquire) and self.state() != .stopped;
    }

    fn requestClose(self: *PtySlot) void {
        self.close_requested.store(true, .release);
    }

    fn closeRuntime(self: *PtySlot) void {
        if (self.state() == .stopped) return;
        self.setState(.stopping);
        if (self.shell) |shell| {
            shell.close();
            self.shell = null;
        }
        if (self.emulator) |emulator| {
            emulator.deinit();
            self.emulator = null;
        }
        self.setState(.stopped);
    }

    fn queueInput(self: *PtySlot, allocator: std.mem.Allocator, bytes: []const u8) !void {
        self.lockInput();
        defer self.unlockInput();
        try self.pending_input.appendSlice(allocator, bytes);
    }

    fn queueMouse(self: *PtySlot, allocator: std.mem.Allocator, event: terminal.MouseEvent) !void {
        self.lockMouse();
        defer self.unlockMouse();
        try self.pending_mouse.append(allocator, event);
    }

    fn queueResize(self: *PtySlot, size: ssh.PtySize) void {
        self.lockResize();
        defer self.unlockResize();
        self.pending_resize = size;
    }

    fn queueClearScrollback(self: *PtySlot) void {
        self.clear_scrollback_requested.store(true, .release);
    }

    fn copySnapshot(self: *PtySlot, allocator: std.mem.Allocator) !?terminal.Snapshot {
        self.lockSnapshot();
        defer self.unlockSnapshot();

        const cached = self.snapshot_cache orelse return null;
        const cells = try allocator.dupe(terminal.Cell, cached.cells);
        errdefer allocator.free(cells);
        const scrollback_cells = try allocator.dupe(terminal.Cell, cached.scrollback_cells);
        errdefer allocator.free(scrollback_cells);
        const cached_title_copy = if (cached.title) |snapshot_title| try allocator.dupe(u8, snapshot_title) else null;
        return .{
            .allocator = allocator,
            .size = cached.size,
            .cells = cells,
            .scrollback_cells = scrollback_cells,
            .scrollback_rows = cached.scrollback_rows,
            .alternate_screen = cached.alternate_screen,
            .bracketed_paste = cached.bracketed_paste,
            .mouse_mode = cached.mouse_mode,
            .cursor = cached.cursor,
            .title = cached_title_copy,
        };
    }

    fn cacheSnapshot(self: *PtySlot, allocator: std.mem.Allocator) ssh_session.Error!void {
        const emulator = self.emulator orelse return;
        var shot = emulator.snapshot(allocator) catch return ssh_session.Error.SnapshotFailed;
        errdefer shot.deinit();

        self.lockSnapshot();
        defer self.unlockSnapshot();

        if (self.snapshot_cache) |*cached| cached.deinit();
        self.updateTitleCache(shot.title orelse "");
        self.snapshot_cache = shot;
    }

    fn clearSnapshotCache(self: *PtySlot) void {
        self.lockSnapshot();
        defer self.unlockSnapshot();

        if (self.snapshot_cache) |*cached| {
            cached.deinit();
            self.snapshot_cache = null;
        }
    }

    fn title(self: *PtySlot) []const u8 {
        self.lockSnapshot();
        defer self.unlockSnapshot();
        return self.title_buf[0..self.title_len];
    }

    fn updateTitleCache(self: *PtySlot, title_text: []const u8) void {
        const len = @min(self.title_buf.len, title_text.len);
        if (len > 0) @memcpy(self.title_buf[0..len], title_text[0..len]);
        self.title_len = len;
    }

    fn drainInput(self: *PtySlot, buffer: []u8) usize {
        self.lockInput();
        defer self.unlockInput();

        const len = @min(buffer.len, self.pending_input.items.len);
        if (len == 0) return 0;
        @memcpy(buffer[0..len], self.pending_input.items[0..len]);
        self.pending_input.replaceRangeAssumeCapacity(0, len, &.{});
        return len;
    }

    fn drainMouse(self: *PtySlot) ?terminal.MouseEvent {
        self.lockMouse();
        defer self.unlockMouse();

        if (self.pending_mouse.items.len == 0) return null;
        return self.pending_mouse.orderedRemove(0);
    }

    fn drainResize(self: *PtySlot) ?ssh.PtySize {
        self.lockResize();
        defer self.unlockResize();

        const size = self.pending_resize orelse return null;
        self.pending_resize = null;
        return size;
    }

    fn lockSnapshot(self: *PtySlot) void {
        while (!self.snapshot_lock.tryLock()) yieldThread();
    }

    fn unlockSnapshot(self: *PtySlot) void {
        self.snapshot_lock.unlock();
    }

    fn lockInput(self: *PtySlot) void {
        while (!self.input_lock.tryLock()) yieldThread();
    }

    fn unlockInput(self: *PtySlot) void {
        self.input_lock.unlock();
    }

    fn lockMouse(self: *PtySlot) void {
        while (!self.mouse_lock.tryLock()) yieldThread();
    }

    fn unlockMouse(self: *PtySlot) void {
        self.mouse_lock.unlock();
    }

    fn lockResize(self: *PtySlot) void {
        while (!self.resize_lock.tryLock()) yieldThread();
    }

    fn unlockResize(self: *PtySlot) void {
        self.resize_lock.unlock();
    }
};

pub const SshWorkspaceWorker = struct {
    allocator: std.mem.Allocator,
    connection: profile.ConnectionProfile,
    options: ssh_session.Options,
    thread: ?std.Thread = null,
    state_raw: std.atomic.Value(u8) = .init(@intFromEnum(State.idle)),
    stop_requested: std.atomic.Value(bool) = .init(false),
    slots_lock: std.atomic.Mutex = .unlocked,
    slots: std.ArrayList(*PtySlot) = .empty,
    next_slot_id: terminal_slot.TerminalSlotId = 1,
    last_error: ?ssh_session.Error = null,

    pub fn create(allocator: std.mem.Allocator, connection: profile.ConnectionProfile, options: ssh_session.Options) !*SshWorkspaceWorker {
        const worker = try allocator.create(SshWorkspaceWorker);
        errdefer allocator.destroy(worker);

        worker.* = .{
            .allocator = allocator,
            .connection = try connection.clone(allocator),
            .options = options,
        };
        errdefer worker.connection.deinit(allocator);
        _ = try worker.createSlot();
        return worker;
    }

    pub fn destroy(self: *SshWorkspaceWorker) void {
        self.requestStop();
        self.join();
        self.lockSlots();
        for (self.slots.items) |slot| slot.destroy(self.allocator);
        self.slots.deinit(self.allocator);
        self.unlockSlots();
        self.connection.deinit(self.allocator);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn start(self: *SshWorkspaceWorker) !void {
        if (self.thread != null) return;
        self.setState(.starting);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn requestStop(self: *SshWorkspaceWorker) void {
        self.stop_requested.store(true, .release);
    }

    pub fn join(self: *SshWorkspaceWorker) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    pub fn state(self: *const SshWorkspaceWorker) State {
        return @enumFromInt(self.state_raw.load(.acquire));
    }

    pub fn createSlot(self: *SshWorkspaceWorker) !terminal_slot.TerminalSlotId {
        self.lockSlots();
        defer self.unlockSlots();

        const id = self.next_slot_id;
        self.next_slot_id += 1;
        const slot = try PtySlot.create(self.allocator, id, self.nextOrdinalLocked());
        errdefer slot.destroy(self.allocator);
        try self.slots.append(self.allocator, slot);
        return id;
    }

    pub fn closeSlot(self: *SshWorkspaceWorker, slot_id: terminal_slot.TerminalSlotId) bool {
        const slot = self.slotById(slot_id) orelse return false;
        slot.requestClose();
        return true;
    }

    pub fn visibleSlotCount(self: *SshWorkspaceWorker) usize {
        self.lockSlots();
        defer self.unlockSlots();
        var count: usize = 0;
        for (self.slots.items) |slot| {
            if (slot.visible()) count += 1;
        }
        return count;
    }

    pub fn firstVisibleSlotId(self: *SshWorkspaceWorker) ?terminal_slot.TerminalSlotId {
        self.lockSlots();
        defer self.unlockSlots();
        for (self.slots.items) |slot| {
            if (slot.visible()) return slot.id;
        }
        return null;
    }

    pub fn hasSlot(self: *SshWorkspaceWorker, slot_id: terminal_slot.TerminalSlotId) bool {
        return self.slotById(slot_id) != null;
    }

    pub fn slotSummaries(self: *SshWorkspaceWorker, buffer: []terminal_slot.TerminalSlotSummary) []terminal_slot.TerminalSlotSummary {
        if (buffer.len == 0) return buffer[0..0];

        self.lockSlots();
        defer self.unlockSlots();
        var out_len: usize = 0;
        for (self.slots.items) |slot| {
            if (!slot.visible()) continue;
            if (out_len >= buffer.len) break;
            buffer[out_len] = .{
                .id = slot.id,
                .ordinal = slot.ordinal,
                .title = slot.title(),
                .status = switch (slot.state()) {
                    .idle, .starting => .opening,
                    .connected => .active,
                    .stopping, .stopped => .closed,
                    .failed => .failed,
                },
            };
            out_len += 1;
        }
        return buffer[0..out_len];
    }

    pub fn copySnapshot(self: *SshWorkspaceWorker, allocator: std.mem.Allocator, slot_id: terminal_slot.TerminalSlotId) !?terminal.Snapshot {
        const slot = self.slotById(slot_id) orelse return null;
        return slot.copySnapshot(allocator);
    }

    pub fn queueInput(self: *SshWorkspaceWorker, slot_id: terminal_slot.TerminalSlotId, bytes: []const u8) !void {
        const slot = self.slotById(slot_id) orelse return ssh_session.Error.ChannelClosed;
        try slot.queueInput(self.allocator, bytes);
    }

    pub fn queueMouse(self: *SshWorkspaceWorker, slot_id: terminal_slot.TerminalSlotId, event: terminal.MouseEvent) !void {
        const slot = self.slotById(slot_id) orelse return ssh_session.Error.ChannelClosed;
        try slot.queueMouse(self.allocator, event);
    }

    pub fn queueResize(self: *SshWorkspaceWorker, slot_id: terminal_slot.TerminalSlotId, size: ssh.PtySize) !void {
        const slot = self.slotById(slot_id) orelse return ssh_session.Error.ChannelClosed;
        slot.queueResize(size);
    }

    pub fn queueClearScrollback(self: *SshWorkspaceWorker, slot_id: terminal_slot.TerminalSlotId) !void {
        const slot = self.slotById(slot_id) orelse return ssh_session.Error.ChannelClosed;
        slot.queueClearScrollback();
    }

    fn run(self: *SshWorkspaceWorker) void {
        const ssh_profile = self.connection.ssh;
        const endpoint = ssh.Endpoint{ .host = ssh_profile.base.host, .port = ssh_profile.base.port };
        const auth = ssh_session.authFromProfile(ssh_profile) catch |err| {
            self.fail(err);
            return;
        };

        const client = self.options.connector.connect(self.allocator, .{
            .endpoint = endpoint,
            .auth = auth,
            .host_key_policy = self.options.host_key_policy,
            .host_key_verifier = self.options.host_key_verifier,
            .timeout_ms = self.options.timeout_ms,
        }) catch |err| {
            self.fail(err);
            return;
        };
        defer client.close();

        self.setState(.connected);
        var buffer: [8192]u8 = undefined;
        var input_buffer: [4096]u8 = undefined;
        while (!self.stop_requested.load(.acquire)) {
            self.pumpSlots(client, &buffer, &input_buffer) catch |err| {
                self.fail(err);
                return;
            };
            yieldThread();
        }

        self.setState(.stopping);
        self.closeAllSlots();
        self.setState(.stopped);
    }

    fn pumpSlots(self: *SshWorkspaceWorker, client: ssh.Client, read_buffer: []u8, input_buffer: []u8) ssh_session.Error!void {
        self.lockSlots();
        defer self.unlockSlots();

        for (self.slots.items) |slot| {
            if (slot.close_requested.load(.acquire)) {
                slot.closeRuntime();
                continue;
            }
            switch (slot.state()) {
                .starting => try self.openSlot(client, slot),
                .connected => try self.pumpSlot(slot, read_buffer, input_buffer),
                else => {},
            }
        }
    }

    fn openSlot(self: *SshWorkspaceWorker, client: ssh.Client, slot: *PtySlot) ssh_session.Error!void {
        const shell = client.openShell(.{ .size = self.options.shell_size }) catch |err| {
            slot.last_error = err;
            slot.setState(.failed);
            return err;
        };
        errdefer shell.close();

        const emulator = self.options.terminal_factory.create(self.allocator, .{
            .cols = self.options.shell_size.cols,
            .rows = self.options.shell_size.rows,
        }) catch {
            slot.last_error = ssh_session.Error.TerminalInitFailed;
            slot.setState(.failed);
            return ssh_session.Error.TerminalInitFailed;
        };
        errdefer emulator.deinit();

        slot.shell = shell;
        slot.emulator = emulator;
        slot.setState(.connected);
        try slot.cacheSnapshot(self.allocator);
    }

    fn pumpSlot(self: *SshWorkspaceWorker, slot: *PtySlot, read_buffer: []u8, input_buffer: []u8) ssh_session.Error!void {
        const shell = slot.shell orelse return;
        const emulator = slot.emulator orelse return;
        var dirty = false;

        if (slot.drainResize()) |size| {
            emulator.resize(.{ .cols = size.cols, .rows = size.rows }) catch return ssh_session.Error.TerminalInitFailed;
            shell.resize(size) catch |err| switch (err) {
                ssh.Error.WouldBlock => {},
                else => {
                    slot.last_error = err;
                    slot.setState(.failed);
                    return err;
                },
            };
            dirty = true;
        }

        const input_len = slot.drainInput(input_buffer);
        if (input_len > 0) {
            _ = shell.write(input_buffer[0..input_len]) catch |err| switch (err) {
                ssh.Error.WouldBlock => {},
                else => {
                    slot.last_error = err;
                    slot.setState(.failed);
                    return err;
                },
            };
        }

        while (slot.drainMouse()) |mouse| {
            const bytes = emulator.mouse(self.allocator, mouse) catch return ssh_session.Error.TerminalWriteFailed;
            defer self.allocator.free(bytes);
            if (bytes.len == 0) continue;
            _ = shell.write(bytes) catch |err| switch (err) {
                ssh.Error.WouldBlock => break,
                else => {
                    slot.last_error = err;
                    slot.setState(.failed);
                    return err;
                },
            };
        }

        if (slot.clear_scrollback_requested.swap(false, .acq_rel)) {
            emulator.clearScrollback() catch return ssh_session.Error.TerminalWriteFailed;
            dirty = true;
        }

        const read_len = shell.read(read_buffer) catch |err| switch (err) {
            ssh.Error.WouldBlock => 0,
            else => {
                slot.last_error = err;
                slot.setState(.failed);
                return err;
            },
        };
        if (read_len > 0) {
            _ = emulator.write(read_buffer[0..read_len]) catch return ssh_session.Error.TerminalWriteFailed;
            dirty = true;
        }
        if (dirty) try slot.cacheSnapshot(self.allocator);
    }

    fn closeAllSlots(self: *SshWorkspaceWorker) void {
        self.lockSlots();
        defer self.unlockSlots();
        for (self.slots.items) |slot| slot.closeRuntime();
    }

    fn slotById(self: *SshWorkspaceWorker, slot_id: terminal_slot.TerminalSlotId) ?*PtySlot {
        self.lockSlots();
        defer self.unlockSlots();
        for (self.slots.items) |slot| {
            if (slot.id == slot_id and slot.visible()) return slot;
        }
        return null;
    }

    fn nextOrdinalLocked(self: *SshWorkspaceWorker) u16 {
        var max: u16 = 0;
        for (self.slots.items) |slot| max = @max(max, slot.ordinal);
        return max + 1;
    }

    fn setState(self: *SshWorkspaceWorker, new_state: State) void {
        self.state_raw.store(@intFromEnum(new_state), .release);
    }

    fn fail(self: *SshWorkspaceWorker, err: ssh_session.Error) void {
        self.last_error = err;
        self.setState(.failed);
    }

    fn lockSlots(self: *SshWorkspaceWorker) void {
        while (!self.slots_lock.tryLock()) yieldThread();
    }

    fn unlockSlots(self: *SshWorkspaceWorker) void {
        self.slots_lock.unlock();
    }
};

fn yieldThread() void {
    std.Thread.yield() catch {};
}

test "workspace worker owns one initial terminal slot" {
    var fake_options = ssh_session.Options{
        .connector = .{ .context = undefined, .vtable = undefined },
        .terminal_factory = .{ .context = undefined, .vtable = undefined },
        .host_key_policy = .insecure_accept_any,
    };
    _ = &fake_options;

    var draft = profile.ProfileDraft{};
    draft.reset(.ssh);
    profile.setBuffer(&draft.name, "Workspace SSH");
    profile.setBuffer(&draft.host, "example.test");
    profile.setBuffer(&draft.username, "dev");
    profile.setBuffer(&draft.password, "pw");

    const connection = try draft.toProfile(std.testing.allocator, 1);
    defer connection.deinit(std.testing.allocator);

    const worker = try SshWorkspaceWorker.create(std.testing.allocator, connection, fake_options);
    defer worker.destroy();

    try std.testing.expectEqual(@as(usize, 1), worker.visibleSlotCount());
    try std.testing.expect(worker.firstVisibleSlotId() != null);
}
