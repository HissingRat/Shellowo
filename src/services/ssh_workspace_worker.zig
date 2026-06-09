const std = @import("std");
const profile = @import("../core/profile.zig");
const remote_file = @import("../core/remote_file.zig");
const status_panel = @import("../core/status_panel.zig");
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

const monitor_interval_ms = 500;
const monitor_exec_timeout_ms = 1_000;
const monitor_script = @embedFile("shellowo-ssh-status-script");
const max_file_entries = 256;
const max_file_tree_nodes = 512;
const max_file_path = 512;
const max_file_error = 96;
const max_file_selection = 256;

const FileTreeNode = struct {
    path: []const u8,
    name: []const u8,
    depth: u8,
    expanded: bool = false,
    loaded: bool = false,
};

const FileDirectoryCache = struct {
    path: []const u8,
    entries: std.ArrayList(remote_file.RemoteFileEntry) = .empty,
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
    file_thread: ?std.Thread = null,
    state_raw: std.atomic.Value(u8) = .init(@intFromEnum(State.idle)),
    stop_requested: std.atomic.Value(bool) = .init(false),
    slots_lock: std.atomic.Mutex = .unlocked,
    slots: std.ArrayList(*PtySlot) = .empty,
    next_slot_id: terminal_slot.TerminalSlotId = 1,
    monitor_lock: std.atomic.Mutex = .unlocked,
    monitor_snapshot: status_panel.StatusPanelSnapshot = .{},
    monitor_elapsed_ms: u32 = monitor_interval_ms,
    file_lock: std.atomic.Mutex = .unlocked,
    file_state: remote_file.FilePaneState = .loading,
    file_path: [max_file_path]u8 = undefined,
    file_path_len: usize = 1,
    file_entries: std.ArrayList(remote_file.RemoteFileEntry) = .empty,
    file_tree_nodes: std.ArrayList(FileTreeNode) = .empty,
    file_dir_caches: std.ArrayList(FileDirectoryCache) = .empty,
    file_error: [max_file_error]u8 = undefined,
    file_error_len: usize = 0,
    file_selected_name: [max_file_selection]u8 = undefined,
    file_selected_name_len: usize = 0,
    file_tree_load_path: [max_file_path]u8 = undefined,
    file_tree_load_path_len: usize = 0,
    file_tree_load_requested: std.atomic.Value(bool) = .init(false),
    file_refresh_requested: std.atomic.Value(bool) = .init(true),
    pending_file_intents: std.ArrayList(remote_file.FilePanelIntent) = .empty,
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
        worker.file_path[0] = '/';
        try worker.initFileTree();
        errdefer {
            worker.clearFileTreeLocked();
            worker.file_tree_nodes.deinit(allocator);
        }
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
        self.lockFile();
        self.clearFileEntriesLocked();
        self.file_entries.deinit(self.allocator);
        self.clearFileTreeLocked();
        self.file_tree_nodes.deinit(self.allocator);
        self.clearFileDirCachesLocked();
        self.file_dir_caches.deinit(self.allocator);
        self.clearPendingFileIntentsLocked();
        self.pending_file_intents.deinit(self.allocator);
        self.unlockFile();
        self.connection.deinit(self.allocator);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn start(self: *SshWorkspaceWorker) !void {
        if (self.thread != null) return;
        self.setState(.starting);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        self.file_thread = std.Thread.spawn(.{}, runFiles, .{self}) catch |err| {
            self.requestStop();
            self.join();
            return err;
        };
    }

    pub fn requestStop(self: *SshWorkspaceWorker) void {
        self.stop_requested.store(true, .release);
    }

    pub fn join(self: *SshWorkspaceWorker) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        if (self.file_thread) |thread| {
            thread.join();
            self.file_thread = null;
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

    pub fn statusPanelSnapshot(self: *SshWorkspaceWorker) status_panel.StatusPanelSnapshot {
        self.lockMonitor();
        defer self.unlockMonitor();
        var snapshot = self.monitor_snapshot;
        const base = self.connection.base();
        if (base.host.len > 0) snapshot.monitor.setIp(base.host);
        return snapshot;
    }

    pub fn filePanelSnapshot(self: *SshWorkspaceWorker, buffer: []remote_file.RemoteFileEntry) remote_file.FilePaneSnapshot {
        self.lockFile();
        defer self.unlockFile();

        const count = @min(buffer.len, self.file_entries.items.len);
        if (count > 0) @memcpy(buffer[0..count], self.file_entries.items[0..count]);
        return .{
            .location = .sftp,
            .path = self.filePathLocked(),
            .state = self.file_state,
            .entries = buffer[0..count],
            .selected_name = self.fileSelectedNameLocked(),
            .error_summary = self.fileErrorLocked(),
            .capabilities = self.fileCapabilitiesLocked(),
        };
    }

    pub fn fileTreeSnapshot(self: *SshWorkspaceWorker, buffer: []remote_file.RemoteFileEntry) remote_file.FilePaneSnapshot {
        self.lockFile();
        defer self.unlockFile();

        const count = self.copyVisibleTreeLocked(buffer);
        return .{
            .location = .sftp,
            .path = self.filePathLocked(),
            .state = if (count > 0) .ready else self.file_state,
            .entries = buffer[0..count],
            .selected_name = null,
            .error_summary = self.fileErrorLocked(),
            .capabilities = self.fileCapabilitiesLocked(),
        };
    }

    pub fn queueFileIntent(self: *SshWorkspaceWorker, intent: remote_file.FilePanelIntent) !void {
        const owned = try self.cloneFileIntent(intent);
        errdefer self.freeFileIntent(owned);
        self.lockFile();
        defer self.unlockFile();
        try self.pending_file_intents.append(self.allocator, owned);
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
            self.pumpMonitor(client);
            sleepMs(1);
        }

        self.setState(.stopping);
        self.closeAllSlots();
        self.setState(.stopped);
    }

    fn runFiles(self: *SshWorkspaceWorker) void {
        const ssh_profile = self.connection.ssh;
        if (!ssh_profile.sftp_enabled) {
            self.storeFileError("SFTP disabled for this profile");
            return;
        }

        const endpoint = ssh.Endpoint{ .host = ssh_profile.base.host, .port = ssh_profile.base.port };
        const auth = ssh_session.authFromProfile(ssh_profile) catch |err| {
            self.storeFileError(@errorName(err));
            return;
        };
        const client = self.options.connector.connect(self.allocator, .{
            .endpoint = endpoint,
            .auth = auth,
            .host_key_policy = self.options.host_key_policy,
            .host_key_verifier = self.options.host_key_verifier,
            .timeout_ms = self.options.timeout_ms,
        }) catch |err| {
            self.storeFileError(@errorName(err));
            return;
        };
        defer client.close();

        const sftp = client.openSftp() catch |err| {
            self.storeFileError(@errorName(err));
            return;
        };
        defer sftp.close();

        self.requestFileRefresh();
        while (!self.stop_requested.load(.acquire)) {
            self.pumpFiles(sftp);
            sleepMs(1);
        }
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

    fn pumpMonitor(self: *SshWorkspaceWorker, client: ssh.Client) void {
        if (self.monitor_elapsed_ms < monitor_interval_ms) {
            self.monitor_elapsed_ms += 1;
            return;
        }
        self.monitor_elapsed_ms = 0;

        const previous_network = blk: {
            self.lockMonitor();
            defer self.unlockMonitor();
            break :blk self.monitor_snapshot.monitor.network;
        };

        const output = client.exec(self.allocator, .{
            .command = monitor_script,
            .timeout_ms = monitor_exec_timeout_ms,
            .max_output_bytes = 32 * 1024,
        }) catch |err| {
            self.storeMonitorError(@errorName(err));
            return;
        };
        defer self.allocator.free(output);

        const parsed = status_panel.parseMonitorJson(output, previous_network) catch |err| {
            self.storeMonitorError(@errorName(err));
            return;
        };

        self.lockMonitor();
        self.monitor_snapshot = .{ .monitor = parsed };
        self.unlockMonitor();
    }

    fn pumpFiles(self: *SshWorkspaceWorker, sftp: ssh.Sftp) void {
        self.drainFileIntents();
        if (self.file_tree_load_requested.swap(false, .acq_rel)) {
            const tree_path = blk: {
                self.lockFile();
                defer self.unlockFile();
                break :blk self.allocator.dupe(u8, self.fileTreeLoadPathLocked()) catch {
                    self.storeFileError("OutOfMemory");
                    return;
                };
            };
            defer self.allocator.free(tree_path);

            const tree_entries = sftp.list(self.allocator, tree_path) catch return;
            self.storeTreeEntries(tree_path, tree_entries);
        }
        if (!self.file_refresh_requested.swap(false, .acq_rel)) return;

        const path = blk: {
            self.lockFile();
            defer self.unlockFile();
            self.file_state = .loading;
            break :blk self.allocator.dupe(u8, self.filePathLocked()) catch {
                self.storeFileError("OutOfMemory");
                return;
            };
        };
        defer self.allocator.free(path);

        const entries = sftp.list(self.allocator, path) catch |err| {
            self.storeFileError(@errorName(err));
            return;
        };
        self.storeFileEntries(entries);
    }

    fn drainFileIntents(self: *SshWorkspaceWorker) void {
        self.lockFile();
        defer self.unlockFile();

        for (self.pending_file_intents.items) |intent| {
            switch (intent) {
                .refresh => self.file_refresh_requested.store(true, .release),
                .select => |selection| if (selection.target.pane == .remote) {
                    self.setFileSelectedNameLocked(selection.target.name);
                },
                .toggle_tree => |target| if (target.pane == .remote) {
                    self.toggleTreeNodeLocked(target.path);
                    self.setFilePathLocked(target.path);
                    self.clearFileSelectionLocked();
                    if (!self.applyCachedFileEntriesLocked(target.path)) {
                        self.file_tree_load_requested.store(false, .release);
                        self.file_refresh_requested.store(true, .release);
                    }
                },
                .go_parent => |pane| if (pane == .remote) {
                    const parent = parentPath(self.filePathLocked());
                    self.setFilePathLocked(parent);
                    self.clearFileSelectionLocked();
                    if (!self.applyCachedFileEntriesLocked(parent)) {
                        self.file_refresh_requested.store(true, .release);
                    }
                },
                .open => |target| if (target.pane == .remote) {
                    const joined = if (target.name.len == 0)
                        self.allocator.dupe(u8, target.path) catch null
                    else
                        joinRemotePath(self.allocator, target.path, target.name) catch null;
                    if (joined) |path| {
                        defer self.allocator.free(path);
                        self.setFilePathLocked(path);
                        self.clearFileSelectionLocked();
                        if (!self.applyCachedFileEntriesLocked(path)) {
                            self.file_refresh_requested.store(true, .release);
                        }
                    }
                },
                else => {},
            }
            self.freeFileIntent(intent);
        }
        self.pending_file_intents.clearRetainingCapacity();
    }

    fn storeTreeEntries(self: *SshWorkspaceWorker, path: []const u8, entries: []remote_file.RemoteFileEntry) void {
        self.lockFile();
        defer self.unlockFile();
        self.updateTreeFromEntriesLocked(path, entries) catch {};
        self.upsertFileDirCacheLocked(path, entries) catch {};
        self.freeRemoteEntries(entries);
    }

    fn storeFileEntries(self: *SshWorkspaceWorker, entries: []remote_file.RemoteFileEntry) void {
        self.lockFile();
        defer self.unlockFile();
        self.clearFileEntriesLocked();
        if (!std.mem.eql(u8, self.filePathLocked(), "/")) {
            self.appendFileEntryLocked(.{ .name = "..", .kind = .directory }) catch {
                self.freeRemoteEntries(entries);
                self.storeFileErrorLocked("OutOfMemory");
                return;
            };
        }
        for (entries[0..@min(entries.len, max_file_entries)]) |entry| {
            self.appendFileEntryLocked(entry) catch {
                self.freeRemoteEntries(entries);
                self.storeFileErrorLocked("OutOfMemory");
                return;
            };
        }
        std.mem.sort(remote_file.RemoteFileEntry, self.file_entries.items, {}, fileEntryLessThan);
        self.updateTreeFromEntriesLocked(self.filePathLocked(), self.file_entries.items) catch {
            self.freeRemoteEntries(entries);
            self.storeFileErrorLocked("OutOfMemory");
            return;
        };
        self.upsertFileDirCacheLocked(self.filePathLocked(), self.file_entries.items) catch {
            self.freeRemoteEntries(entries);
            self.storeFileErrorLocked("OutOfMemory");
            return;
        };
        self.freeRemoteEntries(entries);
        self.file_state = .ready;
        self.file_error_len = 0;
        if (!self.selectionStillExistsLocked()) self.clearFileSelectionLocked();
    }

    fn appendFileEntryLocked(self: *SshWorkspaceWorker, entry: remote_file.RemoteFileEntry) !void {
        try self.appendEntryCopyLocked(&self.file_entries, entry);
    }

    fn appendEntryCopyLocked(self: *SshWorkspaceWorker, list: *std.ArrayList(remote_file.RemoteFileEntry), entry: remote_file.RemoteFileEntry) !void {
        const copied_name = try self.allocator.dupe(u8, entry.name);
        errdefer self.allocator.free(copied_name);
        const copied_full_path = if (entry.full_path.len > 0) try self.allocator.dupe(u8, entry.full_path) else "";
        errdefer if (copied_full_path.len > 0) self.allocator.free(copied_full_path);
        try list.append(self.allocator, .{
            .name = copied_name,
            .kind = entry.kind,
            .size = entry.size,
            .permissions = entry.permissions,
            .modified_unix = entry.modified_unix,
            .uid = entry.uid,
            .gid = entry.gid,
            .full_path = copied_full_path,
            .depth = entry.depth,
            .expanded = entry.expanded,
        });
    }

    fn upsertFileDirCacheLocked(self: *SshWorkspaceWorker, path: []const u8, entries: []const remote_file.RemoteFileEntry) !void {
        const idx = self.findFileDirCacheIndexLocked(path) orelse blk: {
            const copied_path = try self.allocator.dupe(u8, path);
            errdefer self.allocator.free(copied_path);
            try self.file_dir_caches.append(self.allocator, .{ .path = copied_path });
            break :blk self.file_dir_caches.items.len - 1;
        };

        var cache = &self.file_dir_caches.items[idx];
        self.clearEntryListLocked(&cache.entries);
        if (!std.mem.eql(u8, path, "/") and !entriesContainParent(entries)) {
            try self.appendEntryCopyLocked(&cache.entries, .{ .name = "..", .kind = .directory });
        }
        for (entries[0..@min(entries.len, max_file_entries)]) |entry| {
            try self.appendEntryCopyLocked(&cache.entries, entry);
        }
        std.mem.sort(remote_file.RemoteFileEntry, cache.entries.items, {}, fileEntryLessThan);
    }

    fn applyCachedFileEntriesLocked(self: *SshWorkspaceWorker, path: []const u8) bool {
        const idx = self.findFileDirCacheIndexLocked(path) orelse return false;
        self.clearFileEntriesLocked();
        for (self.file_dir_caches.items[idx].entries.items) |entry| {
            self.appendFileEntryLocked(entry) catch {
                self.clearFileEntriesLocked();
                return false;
            };
        }
        self.file_state = .ready;
        self.file_error_len = 0;
        return true;
    }

    fn findFileDirCacheIndexLocked(self: *const SshWorkspaceWorker, path: []const u8) ?usize {
        for (self.file_dir_caches.items, 0..) |cache, idx| {
            if (std.mem.eql(u8, cache.path, path)) return idx;
        }
        return null;
    }

    fn initFileTree(self: *SshWorkspaceWorker) !void {
        try self.appendTreeNodeLocked("/", "/", 0, true, false);
    }

    fn copyVisibleTreeLocked(self: *const SshWorkspaceWorker, buffer: []remote_file.RemoteFileEntry) usize {
        var out_len: usize = 0;
        var collapsed_depth: ?u8 = null;
        for (self.file_tree_nodes.items) |node| {
            if (collapsed_depth) |depth| {
                if (node.depth > depth) continue;
                collapsed_depth = null;
            }
            if (out_len >= buffer.len) break;
            buffer[out_len] = .{
                .name = node.name,
                .kind = .directory,
                .full_path = node.path,
                .depth = node.depth,
                .expanded = node.expanded,
            };
            out_len += 1;
            if (!node.expanded) collapsed_depth = node.depth;
        }
        return out_len;
    }

    fn toggleTreeNodeLocked(self: *SshWorkspaceWorker, path: []const u8) void {
        const idx = self.findTreeNodeIndexLocked(path) orelse return;
        if (self.file_tree_nodes.items[idx].expanded) {
            self.file_tree_nodes.items[idx].expanded = false;
            return;
        }

        self.file_tree_nodes.items[idx].expanded = true;
        if (!self.file_tree_nodes.items[idx].loaded) {
            self.setFileTreeLoadPathLocked(path);
            self.file_tree_load_requested.store(true, .release);
        }
    }

    fn updateTreeFromEntriesLocked(self: *SshWorkspaceWorker, path: []const u8, entries: []const remote_file.RemoteFileEntry) !void {
        try self.ensureTreePathLocked(path);
        const node_idx = self.findTreeNodeIndexLocked(path) orelse return;
        self.file_tree_nodes.items[node_idx].expanded = true;
        self.file_tree_nodes.items[node_idx].loaded = true;

        const depth: u8 = @intCast(pathDepth(path) + 1);
        var insert_idx = node_idx + 1;
        for (entries) |entry| {
            if (!entry.isDirectory() or std.mem.eql(u8, entry.name, "..")) continue;
            if (self.file_tree_nodes.items.len >= max_file_tree_nodes) break;
            const child_path = try joinRemotePath(self.allocator, path, entry.name);
            defer self.allocator.free(child_path);
            if (self.findTreeNodeIndexLocked(child_path)) |existing_idx| {
                if (existing_idx >= insert_idx) insert_idx = self.subtreeEndIndexLocked(existing_idx);
            } else {
                try self.insertTreeNodeLocked(insert_idx, child_path, entry.name, depth, false, false);
                insert_idx += 1;
            }
        }
        self.removeStaleDirectTreeChildrenLocked(path, depth, entries);
    }

    fn ensureTreePathLocked(self: *SshWorkspaceWorker, path: []const u8) !void {
        if (self.file_tree_nodes.items.len == 0) try self.initFileTree();
        if (path.len <= 1) return;

        var depth: u8 = 1;
        var i: usize = 1;
        while (i < path.len) {
            while (i < path.len and path[i] == '/') i += 1;
            if (i >= path.len) break;
            const name_start = i;
            while (i < path.len and path[i] != '/') i += 1;
            const full_path = path[0..i];
            if (self.findTreeNodeIndexLocked(full_path)) |idx| {
                self.file_tree_nodes.items[idx].expanded = true;
            } else if (self.file_tree_nodes.items.len < max_file_tree_nodes) {
                try self.appendTreeNodeLocked(full_path, path[name_start..i], depth, true, false);
            }
            depth += 1;
        }
    }

    fn appendTreeNodeLocked(self: *SshWorkspaceWorker, path: []const u8, name: []const u8, depth: u8, expanded: bool, loaded: bool) !void {
        try self.insertTreeNodeLocked(self.file_tree_nodes.items.len, path, name, depth, expanded, loaded);
    }

    fn insertTreeNodeLocked(self: *SshWorkspaceWorker, idx: usize, path: []const u8, name: []const u8, depth: u8, expanded: bool, loaded: bool) !void {
        const copied_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(copied_path);
        const copied_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(copied_name);
        try self.file_tree_nodes.insert(self.allocator, idx, .{
            .path = copied_path,
            .name = copied_name,
            .depth = depth,
            .expanded = expanded,
            .loaded = loaded,
        });
    }

    fn findTreeNodeIndexLocked(self: *const SshWorkspaceWorker, path: []const u8) ?usize {
        for (self.file_tree_nodes.items, 0..) |node, idx| {
            if (std.mem.eql(u8, node.path, path)) return idx;
        }
        return null;
    }

    fn removeTreeDescendantsLocked(self: *SshWorkspaceWorker, path: []const u8) void {
        var idx: usize = 0;
        while (idx < self.file_tree_nodes.items.len) {
            const node = self.file_tree_nodes.items[idx];
            if (!treePathIsDescendant(path, node.path)) {
                idx += 1;
                continue;
            }
            self.allocator.free(node.path);
            self.allocator.free(node.name);
            _ = self.file_tree_nodes.orderedRemove(idx);
        }
    }

    fn removeStaleDirectTreeChildrenLocked(self: *SshWorkspaceWorker, path: []const u8, child_depth: u8, entries: []const remote_file.RemoteFileEntry) void {
        var idx: usize = 0;
        while (idx < self.file_tree_nodes.items.len) {
            const node = self.file_tree_nodes.items[idx];
            if (node.depth != child_depth or !treePathIsDescendant(path, node.path) or directoryEntryExists(entries, node.name)) {
                idx += 1;
                continue;
            }
            self.removeTreeSubtreeAtIndexLocked(idx);
        }
    }

    fn removeTreeSubtreeAtIndexLocked(self: *SshWorkspaceWorker, idx: usize) void {
        if (idx >= self.file_tree_nodes.items.len) return;
        const depth = self.file_tree_nodes.items[idx].depth;
        var end = idx + 1;
        while (end < self.file_tree_nodes.items.len and self.file_tree_nodes.items[end].depth > depth) : (end += 1) {}
        var remaining = end - idx;
        while (remaining > 0) : (remaining -= 1) {
            const node = self.file_tree_nodes.orderedRemove(idx);
            self.allocator.free(node.path);
            self.allocator.free(node.name);
        }
    }

    fn subtreeEndIndexLocked(self: *const SshWorkspaceWorker, idx: usize) usize {
        if (idx >= self.file_tree_nodes.items.len) return idx;
        const depth = self.file_tree_nodes.items[idx].depth;
        var end = idx + 1;
        while (end < self.file_tree_nodes.items.len and self.file_tree_nodes.items[end].depth > depth) : (end += 1) {}
        return end;
    }

    fn storeFileError(self: *SshWorkspaceWorker, message: []const u8) void {
        self.lockFile();
        defer self.unlockFile();
        self.storeFileErrorLocked(message);
    }

    fn requestFileRefresh(self: *SshWorkspaceWorker) void {
        self.file_refresh_requested.store(true, .release);
    }

    fn storeMonitorError(self: *SshWorkspaceWorker, message: []const u8) void {
        self.lockMonitor();
        defer self.unlockMonitor();

        if (self.monitor_snapshot.monitor.state == .ready) {
            self.monitor_snapshot.monitor.state = .stale;
        } else {
            self.monitor_snapshot.monitor.state = .failed;
        }
        const len = @min(self.monitor_snapshot.monitor.error_summary.len, message.len);
        if (len > 0) @memcpy(self.monitor_snapshot.monitor.error_summary[0..len], message[0..len]);
        self.monitor_snapshot.monitor.error_len = len;
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

    fn lockMonitor(self: *SshWorkspaceWorker) void {
        while (!self.monitor_lock.tryLock()) yieldThread();
    }

    fn unlockMonitor(self: *SshWorkspaceWorker) void {
        self.monitor_lock.unlock();
    }

    fn lockFile(self: *SshWorkspaceWorker) void {
        while (!self.file_lock.tryLock()) yieldThread();
    }

    fn unlockFile(self: *SshWorkspaceWorker) void {
        self.file_lock.unlock();
    }

    fn filePathLocked(self: *const SshWorkspaceWorker) []const u8 {
        return self.file_path[0..self.file_path_len];
    }

    fn fileTreeLoadPathLocked(self: *const SshWorkspaceWorker) []const u8 {
        return self.file_tree_load_path[0..self.file_tree_load_path_len];
    }

    fn fileErrorLocked(self: *const SshWorkspaceWorker) ?[]const u8 {
        return if (self.file_error_len == 0) null else self.file_error[0..self.file_error_len];
    }

    fn fileSelectedNameLocked(self: *const SshWorkspaceWorker) ?[]const u8 {
        return if (self.file_selected_name_len == 0) null else self.file_selected_name[0..self.file_selected_name_len];
    }

    fn fileCapabilitiesLocked(self: *const SshWorkspaceWorker) remote_file.FilePaneCapabilities {
        const ready_or_loading = self.file_state == .ready or self.file_state == .loading;
        return .{
            .can_refresh = ready_or_loading or self.file_state == .failed,
            .can_go_parent = ready_or_loading and !std.mem.eql(u8, self.filePathLocked(), "/"),
            .can_create_directory = self.file_state == .ready,
            .can_rename = self.file_state == .ready,
            .can_delete = self.file_state == .ready,
            .can_upload = self.file_state == .ready,
            .can_download = self.file_state == .ready,
        };
    }

    fn setFilePathLocked(self: *SshWorkspaceWorker, path: []const u8) void {
        const value = if (path.len == 0) "/" else path;
        const len = @min(self.file_path.len, value.len);
        std.mem.copyForwards(u8, self.file_path[0..len], value[0..len]);
        self.file_path_len = len;
    }

    fn setFileTreeLoadPathLocked(self: *SshWorkspaceWorker, path: []const u8) void {
        const value = if (path.len == 0) "/" else path;
        const len = @min(self.file_tree_load_path.len, value.len);
        std.mem.copyForwards(u8, self.file_tree_load_path[0..len], value[0..len]);
        self.file_tree_load_path_len = len;
    }

    fn setFileSelectedNameLocked(self: *SshWorkspaceWorker, name: []const u8) void {
        const len = @min(self.file_selected_name.len, name.len);
        if (len > 0) @memcpy(self.file_selected_name[0..len], name[0..len]);
        self.file_selected_name_len = len;
    }

    fn clearFileSelectionLocked(self: *SshWorkspaceWorker) void {
        self.file_selected_name_len = 0;
    }

    fn selectionStillExistsLocked(self: *const SshWorkspaceWorker) bool {
        const selected = self.fileSelectedNameLocked() orelse return true;
        for (self.file_entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, selected)) return true;
        }
        return false;
    }

    fn storeFileErrorLocked(self: *SshWorkspaceWorker, message: []const u8) void {
        self.file_state = .failed;
        self.clearFileEntriesLocked();
        self.clearFileSelectionLocked();
        const len = @min(self.file_error.len, message.len);
        if (len > 0) @memcpy(self.file_error[0..len], message[0..len]);
        self.file_error_len = len;
    }

    fn clearFileEntriesLocked(self: *SshWorkspaceWorker) void {
        self.clearEntryListLocked(&self.file_entries);
    }

    fn clearEntryListLocked(self: *SshWorkspaceWorker, list: *std.ArrayList(remote_file.RemoteFileEntry)) void {
        for (list.items) |entry| {
            self.allocator.free(entry.name);
            if (entry.full_path.len > 0) self.allocator.free(entry.full_path);
        }
        list.clearRetainingCapacity();
    }

    fn clearFileTreeLocked(self: *SshWorkspaceWorker) void {
        for (self.file_tree_nodes.items) |node| {
            self.allocator.free(node.path);
            self.allocator.free(node.name);
        }
        self.file_tree_nodes.clearRetainingCapacity();
    }

    fn clearFileDirCachesLocked(self: *SshWorkspaceWorker) void {
        for (self.file_dir_caches.items) |*cache| {
            self.allocator.free(cache.path);
            self.clearEntryListLocked(&cache.entries);
            cache.entries.deinit(self.allocator);
        }
        self.file_dir_caches.clearRetainingCapacity();
    }

    fn clearPendingFileIntentsLocked(self: *SshWorkspaceWorker) void {
        for (self.pending_file_intents.items) |intent| self.freeFileIntent(intent);
        self.pending_file_intents.clearRetainingCapacity();
    }

    fn cloneFileIntent(self: *SshWorkspaceWorker, intent: remote_file.FilePanelIntent) !remote_file.FilePanelIntent {
        return switch (intent) {
            .select => |selection| .{ .select = .{
                .target = try self.cloneEntryTarget(selection.target),
                .additive = selection.additive,
            } },
            .toggle_tree => |target| .{ .toggle_tree = try self.cloneEntryTarget(target) },
            .refresh => |pane| .{ .refresh = pane },
            .go_parent => |pane| .{ .go_parent = pane },
            .open => |target| .{ .open = try self.cloneEntryTarget(target) },
            .create_directory => |mkdir| .{ .create_directory = .{
                .pane = mkdir.pane,
                .parent_path = try self.allocator.dupe(u8, mkdir.parent_path),
                .name = try self.allocator.dupe(u8, mkdir.name),
            } },
            .rename => |rename| .{ .rename = .{
                .pane = rename.pane,
                .path = try self.allocator.dupe(u8, rename.path),
                .old_name = try self.allocator.dupe(u8, rename.old_name),
                .new_name = try self.allocator.dupe(u8, rename.new_name),
            } },
            .delete => |target| .{ .delete = try self.cloneEntryTarget(target) },
            .upload => |transfer| .{ .upload = try self.cloneTransferIntent(transfer) },
            .download => |transfer| .{ .download = try self.cloneTransferIntent(transfer) },
        };
    }

    fn cloneEntryTarget(self: *SshWorkspaceWorker, target: remote_file.FileEntryTarget) !remote_file.FileEntryTarget {
        const path = try self.allocator.dupe(u8, target.path);
        errdefer self.allocator.free(path);
        const name = try self.allocator.dupe(u8, target.name);
        return .{ .pane = target.pane, .path = path, .name = name };
    }

    fn cloneTransferIntent(self: *SshWorkspaceWorker, transfer: remote_file.FileTransferIntent) !remote_file.FileTransferIntent {
        const local_path = try self.allocator.dupe(u8, transfer.local_path);
        errdefer self.allocator.free(local_path);
        const remote_path = try self.allocator.dupe(u8, transfer.remote_path);
        errdefer self.allocator.free(remote_path);
        const name = try self.allocator.dupe(u8, transfer.name);
        return .{ .local_path = local_path, .remote_path = remote_path, .name = name };
    }

    fn freeFileIntent(self: *SshWorkspaceWorker, intent: remote_file.FilePanelIntent) void {
        switch (intent) {
            .select => |selection| self.freeEntryTarget(selection.target),
            .toggle_tree => |target| self.freeEntryTarget(target),
            .refresh, .go_parent => {},
            .open => |target| self.freeEntryTarget(target),
            .create_directory => |mkdir| {
                self.allocator.free(mkdir.parent_path);
                self.allocator.free(mkdir.name);
            },
            .rename => |rename| {
                self.allocator.free(rename.path);
                self.allocator.free(rename.old_name);
                self.allocator.free(rename.new_name);
            },
            .delete => |target| self.freeEntryTarget(target),
            .upload => |transfer| self.freeTransferIntent(transfer),
            .download => |transfer| self.freeTransferIntent(transfer),
        }
    }

    fn freeEntryTarget(self: *SshWorkspaceWorker, target: remote_file.FileEntryTarget) void {
        self.allocator.free(target.path);
        self.allocator.free(target.name);
    }

    fn freeTransferIntent(self: *SshWorkspaceWorker, transfer: remote_file.FileTransferIntent) void {
        self.allocator.free(transfer.local_path);
        self.allocator.free(transfer.remote_path);
        self.allocator.free(transfer.name);
    }

    fn freeRemoteEntries(self: *SshWorkspaceWorker, entries: []remote_file.RemoteFileEntry) void {
        for (entries) |entry| self.allocator.free(entry.name);
        self.allocator.free(entries);
    }
};

fn parentPath(path: []const u8) []const u8 {
    if (path.len <= 1) return "/";
    const trimmed = trimRightSlash(path);
    const idx = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return "/";
    if (idx == 0) return "/";
    return trimmed[0..idx];
}

fn joinRemotePath(allocator: std.mem.Allocator, base: []const u8, name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, name, "..")) return allocator.dupe(u8, parentPath(base));
    if (std.mem.eql(u8, base, "/")) return std.fmt.allocPrint(allocator, "/{s}", .{name});
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ trimRightSlash(base), name });
}

fn pathDepth(path: []const u8) usize {
    if (path.len <= 1) return 0;
    var depth: usize = 0;
    var in_segment = false;
    for (path) |ch| {
        if (ch == '/') {
            in_segment = false;
        } else if (!in_segment) {
            in_segment = true;
            depth += 1;
        }
    }
    return depth;
}

fn treePathIsDescendant(parent: []const u8, child: []const u8) bool {
    if (std.mem.eql(u8, parent, child)) return false;
    if (std.mem.eql(u8, parent, "/")) return child.len > 1 and child[0] == '/';
    if (!std.mem.startsWith(u8, child, parent)) return false;
    return child.len > parent.len and child[parent.len] == '/';
}

fn trimRightSlash(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    return path[0..end];
}

fn fileEntryLessThan(context: void, a: remote_file.RemoteFileEntry, b: remote_file.RemoteFileEntry) bool {
    _ = context;
    if (isParentEntry(a)) return !isParentEntry(b);
    if (isParentEntry(b)) return false;
    const a_rank = fileKindSortRank(a.kind);
    const b_rank = fileKindSortRank(b.kind);
    if (a_rank != b_rank) return a_rank < b_rank;
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

fn isParentEntry(entry: remote_file.RemoteFileEntry) bool {
    return entry.kind == .directory and std.mem.eql(u8, entry.name, "..");
}

fn entriesContainParent(entries: []const remote_file.RemoteFileEntry) bool {
    for (entries) |entry| {
        if (isParentEntry(entry)) return true;
    }
    return false;
}

fn fileKindSortRank(kind: remote_file.RemoteFileKind) u8 {
    return switch (kind) {
        .directory => 0,
        .symlink => 1,
        .file => 2,
        .other => 3,
    };
}

fn directoryEntryExists(entries: []const remote_file.RemoteFileEntry, name: []const u8) bool {
    for (entries) |entry| {
        if (entry.isDirectory() and std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

test "set file path accepts overlapping parent path slice" {
    var worker = SshWorkspaceWorker{
        .allocator = std.testing.allocator,
        .connection = undefined,
        .options = undefined,
    };
    worker.setFilePathLocked("/home/andy");
    worker.setFilePathLocked(parentPath(worker.filePathLocked()));
    try std.testing.expectEqualStrings("/home", worker.filePathLocked());
}

fn yieldThread() void {
    std.Thread.yield() catch {};
}

fn sleepMs(ms: c_long) void {
    const request: std.c.timespec = .{
        .sec = @divTrunc(ms, 1000),
        .nsec = @rem(ms, 1000) * std.time.ns_per_ms,
    };
    _ = std.c.nanosleep(&request, null);
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
