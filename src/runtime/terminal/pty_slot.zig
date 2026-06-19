const std = @import("std");
const ssh = @import("../../contracts/ssh.zig");
const terminal = @import("../../contracts/terminal_emulator.zig");
const terminal_slot = @import("../../core/terminal_slot.zig");
const ssh_session = @import("../sessions/ssh_session.zig");
const State = @import("../sessions/workspace_state.zig").State;

const max_pending_input_bytes = 1024 * 1024;

pub const PtySlot = struct {
    id: terminal_slot.TerminalSlotId,
    ordinal: u16,
    state_raw: std.atomic.Value(u8) = .init(@intFromEnum(State.starting)),
    close_requested: std.atomic.Value(bool) = .init(false),
    shell: ?ssh.Shell = null,
    emulator: ?terminal.Emulator = null,
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
    title_buf: [128]u8 = undefined,
    title_len: usize = 0,

    pub fn create(allocator: std.mem.Allocator, id: terminal_slot.TerminalSlotId, ordinal: u16) !*PtySlot {
        const slot = try allocator.create(PtySlot);
        slot.* = .{ .id = id, .ordinal = ordinal };
        return slot;
    }

    pub fn destroy(self: *PtySlot, allocator: std.mem.Allocator) void {
        self.closeRuntime();
        self.clearSnapshotCache();
        self.pending_input.deinit(allocator);
        self.pending_mouse.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn state(self: *const PtySlot) State {
        return @enumFromInt(self.state_raw.load(.acquire));
    }

    pub fn setState(self: *PtySlot, new_state: State) void {
        self.state_raw.store(@intFromEnum(new_state), .release);
    }

    pub fn visible(self: *const PtySlot) bool {
        return !self.close_requested.load(.acquire) and self.state() != .stopped;
    }

    pub fn requestClose(self: *PtySlot) void {
        self.close_requested.store(true, .release);
    }

    pub fn closeRuntime(self: *PtySlot) void {
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

    pub fn disconnectRuntime(self: *PtySlot, err: ssh_session.Error) void {
        if (self.state() == .stopped) return;
        self.last_error = err;
        if (self.shell) |shell| {
            shell.close();
            self.shell = null;
        }
        if (self.emulator) |emulator| {
            emulator.deinit();
            self.emulator = null;
        }
        self.setState(.failed);
    }

    pub fn queueInput(self: *PtySlot, allocator: std.mem.Allocator, bytes: []const u8) !void {
        self.lockInput();
        defer self.unlockInput();
        const remaining = max_pending_input_bytes - @min(self.pending_input.items.len, max_pending_input_bytes);
        if (bytes.len > remaining) return error.InputQueueFull;
        try self.pending_input.appendSlice(allocator, bytes);
    }

    pub fn queueMouse(self: *PtySlot, allocator: std.mem.Allocator, event: terminal.MouseEvent) !void {
        self.lockMouse();
        defer self.unlockMouse();
        try self.pending_mouse.append(allocator, event);
    }

    pub fn queueResize(self: *PtySlot, size: ssh.PtySize) void {
        self.lockResize();
        defer self.unlockResize();
        self.pending_resize = size;
    }

    pub fn retryResize(self: *PtySlot, size: ssh.PtySize) void {
        self.lockResize();
        defer self.unlockResize();
        if (self.pending_resize == null) self.pending_resize = size;
    }

    pub fn queueClearScrollback(self: *PtySlot) void {
        self.clear_scrollback_requested.store(true, .release);
    }

    pub fn copySnapshot(self: *PtySlot, allocator: std.mem.Allocator) !?terminal.Snapshot {
        self.lockSnapshot();
        defer self.unlockSnapshot();
        const cached = self.snapshot_cache orelse return null;
        const cells = try allocator.dupe(terminal.Cell, cached.cells);
        errdefer allocator.free(cells);
        const scrollback_cells = try allocator.dupe(terminal.Cell, cached.scrollback_cells);
        errdefer allocator.free(scrollback_cells);
        const title_copy = if (cached.title) |snapshot_title| try allocator.dupe(u8, snapshot_title) else null;
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
            .title = title_copy,
        };
    }

    pub fn cacheSnapshot(self: *PtySlot, allocator: std.mem.Allocator) ssh_session.Error!void {
        const emulator = self.emulator orelse return;
        var shot = emulator.snapshot(allocator) catch return ssh_session.Error.SnapshotFailed;
        errdefer shot.deinit();
        self.lockSnapshot();
        defer self.unlockSnapshot();
        if (self.snapshot_cache) |*cached| cached.deinit();
        self.snapshot_generation +%= 1;
        shot.generation = self.snapshot_generation;
        self.updateTitleCache(shot.title orelse "");
        self.snapshot_cache = shot;
    }

    pub fn clearSnapshotCache(self: *PtySlot) void {
        self.lockSnapshot();
        defer self.unlockSnapshot();
        if (self.snapshot_cache) |*cached| {
            cached.deinit();
            self.snapshot_cache = null;
        }
        self.snapshot_generation +%= 1;
    }

    pub fn snapshotGeneration(self: *PtySlot) u64 {
        self.lockSnapshot();
        defer self.unlockSnapshot();
        return self.snapshot_generation;
    }

    pub fn title(self: *PtySlot) []const u8 {
        self.lockSnapshot();
        defer self.unlockSnapshot();
        return self.title_buf[0..self.title_len];
    }

    pub fn peekInput(self: *PtySlot, buffer: []u8) usize {
        self.lockInput();
        defer self.unlockInput();
        const len = @min(buffer.len, self.pending_input.items.len);
        if (len == 0) return 0;
        @memcpy(buffer[0..len], self.pending_input.items[0..len]);
        return len;
    }

    pub fn consumeInput(self: *PtySlot, len: usize) void {
        self.lockInput();
        defer self.unlockInput();
        const consumed = @min(len, self.pending_input.items.len);
        if (consumed == 0) return;
        self.pending_input.replaceRangeAssumeCapacity(0, consumed, &.{});
    }

    pub fn drainMouse(self: *PtySlot) ?terminal.MouseEvent {
        self.lockMouse();
        defer self.unlockMouse();
        if (self.pending_mouse.items.len == 0) return null;
        return self.pending_mouse.orderedRemove(0);
    }

    pub fn drainResize(self: *PtySlot) ?ssh.PtySize {
        self.lockResize();
        defer self.unlockResize();
        const size = self.pending_resize orelse return null;
        self.pending_resize = null;
        return size;
    }

    fn updateTitleCache(self: *PtySlot, title_text: []const u8) void {
        const len = @min(self.title_buf.len, title_text.len);
        if (len > 0) @memcpy(self.title_buf[0..len], title_text[0..len]);
        self.title_len = len;
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

fn yieldThread() void {
    std.Thread.yield() catch {};
}
