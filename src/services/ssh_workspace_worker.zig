const std = @import("std");
const Io = std.Io;
const profile = @import("../core/profile.zig");
const remote_file = @import("../core/remote_file.zig");
const status_panel = @import("../core/status_panel.zig");
const terminal_slot = @import("../core/terminal_slot.zig");
const transfer_core = @import("../core/transfer.zig");
const ssh = @import("../protocols/ssh.zig");
const terminal = @import("../terminal/terminal.zig");
const ssh_session = @import("ssh_session.zig");

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

const TransferProgressState = struct {
    id: u64,
    status: transfer_core.TransferStatus,
    progress: f32,
    cancel_requested: bool = false,
};

const DownloadProgress = struct {
    id: ?u64,
    completed: usize = 0,
    total: usize = 1,
};

const DownloadThread = struct {
    thread: std.Thread,
    done: *std.atomic.Value(bool),
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
    download_threads: std.ArrayList(DownloadThread) = .empty,
    thread_done: std.atomic.Value(bool) = .init(true),
    file_thread_done: std.atomic.Value(bool) = .init(true),
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
    transfer_progress: std.ArrayList(TransferProgressState) = .empty,
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
        self.destroyStorage();
    }

    fn destroyStorage(self: *SshWorkspaceWorker) void {
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
        self.transfer_progress.deinit(self.allocator);
        self.unlockFile();
        self.download_threads.deinit(self.allocator);
        self.connection.deinit(self.allocator);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn start(self: *SshWorkspaceWorker) !void {
        if (self.thread != null) return;
        self.setState(.starting);
        self.thread_done.store(false, .release);
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch |err| {
            self.thread_done.store(true, .release);
            return err;
        };
        self.file_thread_done.store(false, .release);
        self.file_thread = std.Thread.spawn(.{}, runFiles, .{self}) catch |err| {
            self.file_thread_done.store(true, .release);
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
        for (self.download_threads.items) |download_thread| {
            download_thread.thread.join();
            self.allocator.destroy(download_thread.done);
        }
        self.download_threads.clearRetainingCapacity();
    }

    pub fn requestRetire(self: *SshWorkspaceWorker) void {
        self.requestStop();
    }

    pub fn reapFinishedThreads(self: *SshWorkspaceWorker) void {
        if (self.thread) |thread| {
            if (self.thread_done.load(.acquire)) {
                thread.join();
                self.thread = null;
            }
        }
        if (self.file_thread) |thread| {
            if (self.file_thread_done.load(.acquire)) {
                thread.join();
                self.file_thread = null;
            }
        }
        if (self.file_thread == null) self.reapDownloadThreads();
    }

    pub fn canDestroyWithoutBlocking(self: *const SshWorkspaceWorker) bool {
        if (self.thread != null and !self.thread_done.load(.acquire)) return false;
        if (self.file_thread != null and !self.file_thread_done.load(.acquire)) return false;
        for (self.download_threads.items) |download_thread| {
            if (!download_thread.done.load(.acquire)) return false;
        }
        return true;
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
                    .idle,
                    .starting,
                    .resolving,
                    .connecting,
                    .verifying_host_key,
                    .authenticating,
                    .opening_shell,
                    => .opening,
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
        const base = self.connection.base;
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

    pub fn transferProgress(self: *SshWorkspaceWorker, buffer: []transfer_core.TransferProgress) []transfer_core.TransferProgress {
        self.lockFile();
        defer self.unlockFile();
        var count: usize = 0;
        var idx: usize = 0;
        while (idx < self.transfer_progress.items.len) {
            const item = self.transfer_progress.items[idx];
            if (item.cancel_requested) {
                _ = self.transfer_progress.orderedRemove(idx);
                continue;
            }
            if (count < buffer.len) {
                buffer[count] = .{
                    .id = item.id,
                    .status = item.status,
                    .progress = item.progress,
                };
                count += 1;
            }
            if (item.status == .completed) {
                _ = self.transfer_progress.orderedRemove(idx);
                continue;
            }
            idx += 1;
        }
        return buffer[0..count];
    }

    fn transferProgressSnapshotLocked(self: *const SshWorkspaceWorker, buffer: []transfer_core.TransferProgress) []transfer_core.TransferProgress {
        const count = @min(buffer.len, self.transfer_progress.items.len);
        for (self.transfer_progress.items[0..count], 0..) |item, idx| {
            buffer[idx] = .{
                .id = item.id,
                .status = item.status,
                .progress = item.progress,
            };
        }
        return buffer[0..count];
    }

    pub fn requestCancelTransfer(self: *SshWorkspaceWorker, transfer_id: u64) void {
        self.lockFile();
        defer self.unlockFile();
        const progress_state = self.ensureTransferProgressLocked(transfer_id) catch return;
        progress_state.cancel_requested = true;
        progress_state.status = .canceled;
        progress_state.progress = 1;
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
        defer self.thread_done.store(true, .release);
        const ssh_profile = self.connection;
        const endpoint = ssh.Endpoint{ .host = ssh_profile.base.host, .port = ssh_profile.base.port };
        const auth = ssh_session.authFromProfile(ssh_profile) catch |err| {
            self.fail(err);
            return;
        };

        self.setState(.resolving);
        const client = self.options.connector.connect(self.allocator, .{
            .endpoint = endpoint,
            .auth = auth,
            .host_key_policy = self.options.host_key_policy,
            .host_key_verifier = self.options.host_key_verifier,
            .progress_reporter = self.progressReporter(),
            .cancel_token = self.cancelToken(),
            .timeout_ms = @intCast(self.options.timeout_ms),
        }) catch |err| {
            self.fail(err);
            return;
        };
        defer client.close();
        defer self.closeAllSlots();

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
        self.setState(.stopped);
    }

    fn runFiles(self: *SshWorkspaceWorker) void {
        defer self.file_thread_done.store(true, .release);
        const ssh_profile = self.connection;
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
            .cancel_token = self.cancelToken(),
            .timeout_ms = @intCast(self.options.timeout_ms),
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
        self.setState(.opening_shell);
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
        self.setState(.connected);
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
        self.reapDownloadThreads();
        self.drainFileIntents(sftp);
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

    fn drainFileIntents(self: *SshWorkspaceWorker, sftp: ssh.Sftp) void {
        self.lockFile();
        var intents = self.pending_file_intents;
        self.pending_file_intents = .empty;
        self.unlockFile();
        defer {
            for (intents.items) |intent| self.freeFileIntent(intent);
            intents.deinit(self.allocator);
        }

        if (intents.items.len > 0) self.clearFileError();

        for (intents.items) |intent| {
            switch (intent) {
                .refresh => self.file_refresh_requested.store(true, .release),
                .select => |selection| if (selection.target.pane == .remote) {
                    self.lockFile();
                    defer self.unlockFile();
                    self.setFileSelectedNameLocked(selection.target.name);
                },
                .toggle_tree => |target| if (target.pane == .remote) {
                    self.lockFile();
                    defer self.unlockFile();
                    self.toggleTreeNodeLocked(target.path);
                    self.setFilePathLocked(target.path);
                    self.clearFileSelectionLocked();
                    if (!self.applyCachedFileEntriesLocked(target.path)) {
                        self.file_tree_load_requested.store(false, .release);
                        self.file_refresh_requested.store(true, .release);
                    }
                },
                .go_parent => |pane| if (pane == .remote) {
                    self.lockFile();
                    defer self.unlockFile();
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
                        self.lockFile();
                        defer self.unlockFile();
                        self.setFilePathLocked(path);
                        self.clearFileSelectionLocked();
                        if (!self.applyCachedFileEntriesLocked(path)) {
                            self.file_refresh_requested.store(true, .release);
                        }
                    }
                },
                .create_file => |create_intent| if (create_intent.pane == .remote) {
                    self.createRemoteFile(sftp, create_intent.parent_path, create_intent.name);
                },
                .create_directory => |create_intent| if (create_intent.pane == .remote) {
                    self.createRemoteDirectory(sftp, create_intent.parent_path, create_intent.name);
                },
                .rename => |rename| if (rename.pane == .remote) {
                    self.renameRemoteEntry(sftp, rename.path, rename.old_name, rename.new_name);
                },
                .delete => |target| if (target.pane == .remote) {
                    self.deleteRemoteEntry(sftp, target.path, target.name, target.kind orelse .file);
                },
                .download => |transfer| {
                    self.spawnDownloadIntent(intent) catch {
                        self.markTransferFinished(transfer.transfer_id, .failed);
                        self.storeFileNotice("Download failed");
                    };
                },
                .download_many => |transfer| {
                    self.spawnDownloadIntent(intent) catch {
                        self.markTransferFinished(transfer.transfer_id, .failed);
                        self.storeFileNotice("Download failed");
                    };
                },
                .upload => |transfer| {
                    self.spawnDownloadIntent(intent) catch {
                        self.markTransferFinished(transfer.transfer_id, .failed);
                        self.storeFileNotice("Upload failed");
                    };
                },
                .upload_many => |transfer| {
                    self.spawnDownloadIntent(intent) catch {
                        self.markTransferFinished(transfer.transfer_id, .failed);
                        self.storeFileNotice("Upload failed");
                    };
                },
            }
        }
    }

    fn spawnDownloadIntent(self: *SshWorkspaceWorker, intent: remote_file.FilePanelIntent) !void {
        const owned = try self.cloneFileIntent(intent);
        errdefer self.freeFileIntent(owned);
        const done = try self.allocator.create(std.atomic.Value(bool));
        errdefer self.allocator.destroy(done);
        done.* = .init(false);
        try self.download_threads.ensureUnusedCapacity(self.allocator, 1);
        const thread = try std.Thread.spawn(.{}, runDownloadIntent, .{ self, owned, done });
        self.download_threads.appendAssumeCapacity(.{ .thread = thread, .done = done });
    }

    fn reapDownloadThreads(self: *SshWorkspaceWorker) void {
        var idx: usize = 0;
        while (idx < self.download_threads.items.len) {
            const download_thread = self.download_threads.items[idx];
            if (!download_thread.done.load(.acquire)) {
                idx += 1;
                continue;
            }
            download_thread.thread.join();
            self.allocator.destroy(download_thread.done);
            _ = self.download_threads.orderedRemove(idx);
        }
    }

    fn runDownloadIntent(self: *SshWorkspaceWorker, intent: remote_file.FilePanelIntent, done: *std.atomic.Value(bool)) void {
        defer done.store(true, .release);
        defer self.freeFileIntent(intent);

        const transfer_id = switch (intent) {
            .upload => |transfer| transfer.transfer_id,
            .upload_many => |transfer| transfer.transfer_id,
            .download => |transfer| transfer.transfer_id,
            .download_many => |transfer| transfer.transfer_id,
            else => null,
        };
        self.markTransferProgress(transfer_id, .running, 0);

        if (self.stop_requested.load(.acquire)) {
            self.markTransferFinished(transfer_id, .canceled);
            return;
        }

        const sftp = self.openDownloadSftp() catch {
            self.markTransferFinished(transfer_id, .failed);
            self.storeFileNotice("Download failed");
            return;
        };
        defer sftp.client.close();
        defer sftp.sftp.close();

        switch (intent) {
            .upload => |transfer| {
                self.uploadLocalEntry(sftp.sftp, transfer.local_path, transfer.name, transfer.remote_path, transfer.transfer_id) catch |err| {
                    if (err == error.Canceled) {
                        self.markTransferFinished(transfer.transfer_id, .canceled);
                    } else {
                        self.markTransferFinished(transfer.transfer_id, .failed);
                        self.storeFileNotice("Upload failed");
                    }
                };
            },
            .upload_many => |transfer| {
                self.uploadLocalEntries(sftp.sftp, transfer) catch |err| {
                    if (err == error.Canceled) {
                        self.markTransferFinished(transfer.transfer_id, .canceled);
                    } else {
                        self.markTransferFinished(transfer.transfer_id, .failed);
                        self.storeFileNotice("Upload failed");
                    }
                };
            },
            .download => |transfer| {
                self.downloadRemoteEntry(sftp.sftp, transfer.remote_path, transfer.name, .file, transfer.transfer_id) catch |err| {
                    if (err == error.Canceled) {
                        self.markTransferFinished(transfer.transfer_id, .canceled);
                    } else {
                        self.markTransferFinished(transfer.transfer_id, .failed);
                        self.storeFileNotice("Download failed");
                    }
                };
            },
            .download_many => |transfer| {
                self.downloadRemoteEntries(sftp.sftp, transfer) catch |err| {
                    if (err == error.Canceled) {
                        self.markTransferFinished(transfer.transfer_id, .canceled);
                    } else {
                        self.markTransferFinished(transfer.transfer_id, .failed);
                        self.storeFileNotice("Download failed");
                    }
                };
            },
            else => {},
        }
    }

    const DownloadSftp = struct {
        client: ssh.Client,
        sftp: ssh.Sftp,
    };

    fn openDownloadSftp(self: *SshWorkspaceWorker) ssh_session.Error!DownloadSftp {
        const ssh_profile = self.connection;
        const endpoint = ssh.Endpoint{ .host = ssh_profile.base.host, .port = ssh_profile.base.port };
        const auth = try ssh_session.authFromProfile(ssh_profile);
        const client = try self.options.connector.connect(self.allocator, .{
            .endpoint = endpoint,
            .auth = auth,
            .host_key_policy = self.options.host_key_policy,
            .host_key_verifier = self.options.host_key_verifier,
            .cancel_token = self.cancelToken(),
            .timeout_ms = @intCast(self.options.timeout_ms),
        });
        errdefer client.close();
        const sftp = try client.openSftp();
        errdefer sftp.close();
        return .{ .client = client, .sftp = sftp };
    }

    fn createRemoteFile(self: *SshWorkspaceWorker, sftp: ssh.Sftp, parent_path: []const u8, name: []const u8) void {
        const full_path = joinRemotePath(self.allocator, parent_path, name) catch {
            self.storeFileNotice("File create failed");
            return;
        };
        defer self.allocator.free(full_path);
        sftp.writeFile(full_path, "") catch {
            self.storeFileNotice("File create failed");
            return;
        };
        self.invalidatePathCaches(parent_path);
        self.file_refresh_requested.store(true, .release);
    }

    fn createRemoteDirectory(self: *SshWorkspaceWorker, sftp: ssh.Sftp, parent_path: []const u8, name: []const u8) void {
        const full_path = joinRemotePath(self.allocator, parent_path, name) catch {
            self.storeFileNotice("Folder create failed");
            return;
        };
        defer self.allocator.free(full_path);
        sftp.mkdir(full_path) catch {
            self.storeFileNotice("Folder create failed");
            return;
        };
        self.invalidatePathCaches(parent_path);
        self.file_refresh_requested.store(true, .release);
    }

    fn renameRemoteEntry(self: *SshWorkspaceWorker, sftp: ssh.Sftp, parent_path: []const u8, old_name: []const u8, new_name: []const u8) void {
        const old_path = joinRemotePath(self.allocator, parent_path, old_name) catch {
            self.storeFileNotice("Rename failed");
            return;
        };
        defer self.allocator.free(old_path);
        const new_path = joinRemotePath(self.allocator, parent_path, new_name) catch {
            self.storeFileNotice("Rename failed");
            return;
        };
        defer self.allocator.free(new_path);
        sftp.rename(old_path, new_path) catch {
            self.storeFileNotice("Rename failed");
            return;
        };
        self.invalidatePathCaches(parent_path);
        self.file_refresh_requested.store(true, .release);
    }

    fn deleteRemoteEntry(self: *SshWorkspaceWorker, sftp: ssh.Sftp, parent_path: []const u8, name: []const u8, kind: remote_file.RemoteFileKind) void {
        if (std.mem.eql(u8, name, "..")) return;
        const full_path = joinRemotePath(self.allocator, parent_path, name) catch {
            self.storeFileNotice("Delete failed");
            return;
        };
        defer self.allocator.free(full_path);
        self.deleteRemotePath(sftp, full_path, kind) catch {
            self.storeFileNotice("Delete failed");
            return;
        };
        self.invalidatePathCaches(parent_path);
        self.file_refresh_requested.store(true, .release);
    }

    fn deleteRemotePath(self: *SshWorkspaceWorker, sftp: ssh.Sftp, path: []const u8, kind: remote_file.RemoteFileKind) ssh.Error!void {
        if (kind == .directory) {
            const entries = try sftp.list(self.allocator, path);
            defer self.freeRemoteEntries(entries);
            for (entries) |entry| {
                const child_path = joinRemotePath(self.allocator, path, entry.name) catch return ssh.Error.TransferFailed;
                defer self.allocator.free(child_path);
                try self.deleteRemotePath(sftp, child_path, entry.kind);
            }
            return sftp.removeDir(path);
        }
        return sftp.remove(path);
    }

    fn downloadRemoteEntries(self: *SshWorkspaceWorker, sftp: ssh.Sftp, transfer: remote_file.FileBatchTransferIntent) !void {
        const base_path = try self.downloadBasePath(transfer.local_path);
        defer self.allocator.free(base_path);
        var progress = DownloadProgress{
            .id = transfer.transfer_id,
            .total = @max(transfer.entries.len, 1),
        };
        self.markTransferProgress(transfer.transfer_id, .running, 0);
        for (transfer.entries) |entry| {
            try self.downloadRemoteEntryToBase(sftp, transfer.remote_path, entry.name, entry.kind, base_path, &progress);
        }
        self.markTransferFinished(transfer.transfer_id, .completed);
    }

    fn downloadRemoteEntry(self: *SshWorkspaceWorker, sftp: ssh.Sftp, remote_path: []const u8, name: []const u8, kind: remote_file.RemoteFileKind, transfer_id: ?u64) !void {
        const base_path = try self.downloadBasePath("");
        defer self.allocator.free(base_path);
        const remote_full = try joinRemotePath(self.allocator, remote_path, name);
        defer self.allocator.free(remote_full);
        var progress = DownloadProgress{
            .id = transfer_id,
            .total = 1,
        };
        self.markTransferProgress(transfer_id, .running, 0);
        try self.downloadRemoteEntryToBase(sftp, remote_path, name, kind, base_path, &progress);
        self.markTransferFinished(transfer_id, .completed);
    }

    fn downloadRemoteEntryToBase(self: *SshWorkspaceWorker, sftp: ssh.Sftp, remote_path: []const u8, name: []const u8, kind: remote_file.RemoteFileKind, local_base: []const u8, progress: *DownloadProgress) !void {
        const remote_full = try joinRemotePath(self.allocator, remote_path, name);
        defer self.allocator.free(remote_full);
        const local_full = try std.fs.path.join(self.allocator, &.{ local_base, name });
        defer self.allocator.free(local_full);
        try self.downloadRemotePath(sftp, remote_full, local_full, kind, progress);
    }

    fn downloadRemotePath(self: *SshWorkspaceWorker, sftp: ssh.Sftp, remote_path: []const u8, local_path: []const u8, kind: remote_file.RemoteFileKind, progress: *DownloadProgress) !void {
        const io = self.options.io orelse return error.IoUnavailable;
        try self.checkTransferCanceled(progress.id);
        if (kind == .directory) {
            try std.Io.Dir.cwd().createDirPath(io, local_path);
            const entries = try sftp.list(self.allocator, remote_path);
            defer self.freeRemoteEntries(entries);
            progress.total += entries.len;
            self.bumpDownloadProgress(progress);
            for (entries) |entry| {
                try self.checkTransferCanceled(progress.id);
                const child_remote = try joinRemotePath(self.allocator, remote_path, entry.name);
                defer self.allocator.free(child_remote);
                const child_local = try std.fs.path.join(self.allocator, &.{ local_path, entry.name });
                defer self.allocator.free(child_local);
                try self.downloadRemotePath(sftp, child_remote, child_local, entry.kind, progress);
            }
            return;
        }

        const bytes = try sftp.readFile(self.allocator, remote_path);
        defer self.allocator.free(bytes);
        if (std.fs.path.dirname(local_path)) |dirname| {
            try std.Io.Dir.cwd().createDirPath(io, dirname);
        }
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = local_path,
            .data = bytes,
        });
        self.bumpDownloadProgress(progress);
    }

    fn bumpDownloadProgress(self: *SshWorkspaceWorker, progress: *DownloadProgress) void {
        progress.completed += 1;
        self.markTransferProgress(progress.id, .running, @as(f32, @floatFromInt(progress.completed)) / @as(f32, @floatFromInt(progress.total)));
    }

    fn downloadBasePath(self: *SshWorkspaceWorker, requested: []const u8) ![]u8 {
        if (requested.len > 0) return self.allocator.dupe(u8, requested);
        if (self.options.download_path.len > 0) return self.allocator.dupe(u8, self.options.download_path);
        const io = self.options.io orelse return error.IoUnavailable;
        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        const len = try std.process.executableDirPath(io, &exe_buf);
        return std.fs.path.join(self.allocator, &.{ exe_buf[0..len], "owoDownloads" });
    }

    fn uploadLocalEntries(self: *SshWorkspaceWorker, sftp: ssh.Sftp, transfer: remote_file.FileBatchTransferIntent) !void {
        var progress = DownloadProgress{
            .id = transfer.transfer_id,
            .total = @max(transfer.entries.len, 1),
        };
        self.markTransferProgress(transfer.transfer_id, .running, 0);
        for (transfer.entries) |entry| {
            try self.uploadLocalEntryToBase(sftp, transfer.local_path, entry.name, transfer.remote_path, &progress);
        }
        self.markTransferFinished(transfer.transfer_id, .completed);
        self.invalidatePathCaches(transfer.remote_path);
        self.file_refresh_requested.store(true, .release);
    }

    fn uploadLocalEntry(self: *SshWorkspaceWorker, sftp: ssh.Sftp, local_path: []const u8, name: []const u8, remote_path: []const u8, transfer_id: ?u64) !void {
        var progress = DownloadProgress{
            .id = transfer_id,
            .total = 1,
        };
        self.markTransferProgress(transfer_id, .running, 0);
        try self.uploadLocalEntryToBase(sftp, local_path, name, remote_path, &progress);
        self.markTransferFinished(transfer_id, .completed);
        self.invalidatePathCaches(remote_path);
        self.file_refresh_requested.store(true, .release);
    }

    fn uploadLocalEntryToBase(self: *SshWorkspaceWorker, sftp: ssh.Sftp, local_base: []const u8, name: []const u8, remote_path: []const u8, progress: *DownloadProgress) !void {
        const local_full = try std.fs.path.join(self.allocator, &.{ local_base, name });
        defer self.allocator.free(local_full);
        const remote_full = try joinRemotePath(self.allocator, remote_path, name);
        defer self.allocator.free(remote_full);
        try self.uploadLocalPath(sftp, local_full, remote_full, progress);
    }

    fn uploadLocalPath(self: *SshWorkspaceWorker, sftp: ssh.Sftp, local_path: []const u8, remote_path: []const u8, progress: *DownloadProgress) !void {
        const io = self.options.io orelse return error.IoUnavailable;
        try self.checkTransferCanceled(progress.id);

        if (self.openLocalDir(local_path)) |dir| {
            var local_dir = dir;
            defer local_dir.close(io);
            sftp.mkdir(remote_path) catch {};
            self.bumpDownloadProgress(progress);

            var walker = try local_dir.walk(self.allocator);
            defer walker.deinit();
            while (try walker.next(io)) |entry| {
                try self.checkTransferCanceled(progress.id);
                progress.total += 1;
                const child_local = try std.fs.path.join(self.allocator, &.{ local_path, entry.path });
                defer self.allocator.free(child_local);
                const child_remote = try joinRemotePath(self.allocator, remote_path, entry.path);
                defer self.allocator.free(child_remote);
                switch (entry.kind) {
                    .directory => {
                        sftp.mkdir(child_remote) catch {};
                        self.bumpDownloadProgress(progress);
                    },
                    .file => try self.uploadLocalFile(sftp, child_local, child_remote, progress),
                    else => self.bumpDownloadProgress(progress),
                }
            }
            return;
        } else |_| {}

        try self.uploadLocalFile(sftp, local_path, remote_path, progress);
    }

    fn uploadLocalFile(self: *SshWorkspaceWorker, sftp: ssh.Sftp, local_path: []const u8, remote_path: []const u8, progress: *DownloadProgress) !void {
        const io = self.options.io orelse return error.IoUnavailable;
        try self.checkTransferCanceled(progress.id);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, local_path, self.allocator, .limited(std.math.maxInt(usize)));
        defer self.allocator.free(bytes);
        try self.checkTransferCanceled(progress.id);
        try sftp.writeFile(remote_path, bytes);
        self.bumpDownloadProgress(progress);
    }

    fn openLocalDir(self: *SshWorkspaceWorker, local_path: []const u8) !std.Io.Dir {
        const io = self.options.io orelse return error.IoUnavailable;
        if (std.fs.path.isAbsolute(local_path)) {
            return std.Io.Dir.openDirAbsolute(io, local_path, .{ .iterate = true });
        }
        return std.Io.Dir.cwd().openDir(io, local_path, .{ .iterate = true });
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

    fn invalidatePathCaches(self: *SshWorkspaceWorker, path: []const u8) void {
        self.lockFile();
        defer self.unlockFile();
        if (self.findFileDirCacheIndexLocked(path)) |idx| {
            var cache = self.file_dir_caches.orderedRemove(idx);
            self.allocator.free(cache.path);
            self.clearEntryListLocked(&cache.entries);
            cache.entries.deinit(self.allocator);
        }
        if (self.findTreeNodeIndexLocked(path)) |idx| {
            self.file_tree_nodes.items[idx].loaded = false;
        }
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

    fn clearFileError(self: *SshWorkspaceWorker) void {
        self.lockFile();
        defer self.unlockFile();
        self.file_error_len = 0;
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

    fn progressReporter(self: *SshWorkspaceWorker) ssh.ConnectProgressReporter {
        return .{ .context = self, .vtable = &progress_vtable };
    }

    fn cancelToken(self: *SshWorkspaceWorker) ssh.CancelToken {
        return .{ .context = self, .vtable = &cancel_token_vtable };
    }

    fn reportProgress(context: *anyopaque, stage: ssh.ConnectStage) void {
        const self: *SshWorkspaceWorker = @ptrCast(@alignCast(context));
        self.setState(stateFromConnectStage(stage));
    }

    fn canceled(context: *anyopaque) bool {
        const self: *SshWorkspaceWorker = @ptrCast(@alignCast(context));
        return self.stop_requested.load(.acquire);
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

    fn storeFileNotice(self: *SshWorkspaceWorker, message: []const u8) void {
        self.lockFile();
        defer self.unlockFile();
        self.storeFileNoticeLocked(message);
    }

    fn storeFileNoticeLocked(self: *SshWorkspaceWorker, message: []const u8) void {
        const len = @min(self.file_error.len, message.len);
        if (len > 0) @memcpy(self.file_error[0..len], message[0..len]);
        self.file_error_len = len;
    }

    fn markTransferProgress(self: *SshWorkspaceWorker, transfer_id: ?u64, status: transfer_core.TransferStatus, progress: f32) void {
        const id = transfer_id orelse return;
        self.lockFile();
        defer self.unlockFile();
        const progress_state = self.ensureTransferProgressLocked(id) catch return;
        if (progress_state.cancel_requested) return;
        progress_state.status = status;
        progress_state.progress = @max(0, @min(progress, 1));
    }

    fn markTransferFinished(self: *SshWorkspaceWorker, transfer_id: ?u64, status: transfer_core.TransferStatus) void {
        const id = transfer_id orelse return;
        self.lockFile();
        defer self.unlockFile();
        const progress_state = self.ensureTransferProgressLocked(id) catch return;
        if (progress_state.cancel_requested and status != .canceled) return;
        progress_state.status = status;
        progress_state.progress = 1;
    }

    fn checkTransferCanceled(self: *SshWorkspaceWorker, transfer_id: ?u64) !void {
        const id = transfer_id orelse return;
        self.lockFile();
        defer self.unlockFile();
        const idx = self.transferProgressIndexLocked(id) orelse return;
        if (self.transfer_progress.items[idx].cancel_requested) return error.Canceled;
    }

    fn ensureTransferProgressLocked(self: *SshWorkspaceWorker, transfer_id: u64) !*TransferProgressState {
        if (self.transferProgressIndexLocked(transfer_id)) |idx| return &self.transfer_progress.items[idx];
        try self.transfer_progress.append(self.allocator, .{
            .id = transfer_id,
            .status = .running,
            .progress = 0,
        });
        return &self.transfer_progress.items[self.transfer_progress.items.len - 1];
    }

    fn transferProgressIndexLocked(self: *const SshWorkspaceWorker, transfer_id: u64) ?usize {
        for (self.transfer_progress.items, 0..) |item, idx| {
            if (item.id == transfer_id) return idx;
        }
        return null;
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
            .create_file => |create_intent| .{ .create_file = .{
                .pane = create_intent.pane,
                .parent_path = try self.allocator.dupe(u8, create_intent.parent_path),
                .name = try self.allocator.dupe(u8, create_intent.name),
            } },
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
            .upload_many => |transfer| .{ .upload_many = try self.cloneBatchTransferIntent(transfer) },
            .download => |transfer| .{ .download = try self.cloneTransferIntent(transfer) },
            .download_many => |transfer| .{ .download_many = try self.cloneBatchTransferIntent(transfer) },
        };
    }

    fn cloneEntryTarget(self: *SshWorkspaceWorker, target: remote_file.FileEntryTarget) !remote_file.FileEntryTarget {
        const path = try self.allocator.dupe(u8, target.path);
        errdefer self.allocator.free(path);
        const name = try self.allocator.dupe(u8, target.name);
        return .{ .pane = target.pane, .path = path, .name = name, .kind = target.kind };
    }

    fn cloneTransferIntent(self: *SshWorkspaceWorker, transfer: remote_file.FileTransferIntent) !remote_file.FileTransferIntent {
        const local_path = try self.allocator.dupe(u8, transfer.local_path);
        errdefer self.allocator.free(local_path);
        const remote_path = try self.allocator.dupe(u8, transfer.remote_path);
        errdefer self.allocator.free(remote_path);
        const name = try self.allocator.dupe(u8, transfer.name);
        return .{ .local_path = local_path, .remote_path = remote_path, .name = name, .transfer_id = transfer.transfer_id };
    }

    fn cloneBatchTransferIntent(self: *SshWorkspaceWorker, transfer: remote_file.FileBatchTransferIntent) !remote_file.FileBatchTransferIntent {
        const local_path = try self.allocator.dupe(u8, transfer.local_path);
        errdefer self.allocator.free(local_path);
        const remote_path = try self.allocator.dupe(u8, transfer.remote_path);
        errdefer self.allocator.free(remote_path);
        const entries = try self.allocator.alloc(remote_file.FileBatchEntry, transfer.entries.len);
        errdefer self.allocator.free(entries);
        for (transfer.entries, 0..) |entry, idx| {
            entries[idx] = .{
                .name = try self.allocator.dupe(u8, entry.name),
                .kind = entry.kind,
            };
        }
        return .{ .local_path = local_path, .remote_path = remote_path, .entries = entries, .transfer_id = transfer.transfer_id };
    }

    fn freeFileIntent(self: *SshWorkspaceWorker, intent: remote_file.FilePanelIntent) void {
        switch (intent) {
            .select => |selection| self.freeEntryTarget(selection.target),
            .toggle_tree => |target| self.freeEntryTarget(target),
            .refresh, .go_parent => {},
            .open => |target| self.freeEntryTarget(target),
            .create_file => |create_intent| {
                self.allocator.free(create_intent.parent_path);
                self.allocator.free(create_intent.name);
            },
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
            .upload_many => |transfer| self.freeBatchTransferIntent(transfer),
            .download => |transfer| self.freeTransferIntent(transfer),
            .download_many => |transfer| self.freeBatchTransferIntent(transfer),
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

    fn freeBatchTransferIntent(self: *SshWorkspaceWorker, transfer: remote_file.FileBatchTransferIntent) void {
        self.allocator.free(transfer.local_path);
        self.allocator.free(transfer.remote_path);
        for (transfer.entries) |entry| self.allocator.free(entry.name);
        self.allocator.free(transfer.entries);
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

const progress_vtable: ssh.ConnectProgressReporter.VTable = .{ .report = SshWorkspaceWorker.reportProgress };
const cancel_token_vtable: ssh.CancelToken.VTable = .{ .canceled = SshWorkspaceWorker.canceled };

fn stateFromConnectStage(stage: ssh.ConnectStage) State {
    return switch (stage) {
        .resolving => .resolving,
        .connecting => .connecting,
        .verifying_host_key => .verifying_host_key,
        .authenticating => .authenticating,
    };
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
    var threaded: Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();
    io.sleep(.fromMilliseconds(ms), .awake) catch {};
}

test "workspace worker owns one initial terminal slot" {
    var fake_options = ssh_session.Options{
        .connector = .{ .context = undefined, .vtable = undefined },
        .terminal_factory = .{ .context = undefined, .vtable = undefined },
        .host_key_policy = .insecure_accept_any,
    };
    _ = &fake_options;

    var draft = profile.ProfileDraft{};
    draft.reset();
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
