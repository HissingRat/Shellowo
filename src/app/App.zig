const std = @import("std");
const builtin = @import("builtin");
const app_config = @import("config.zig");
const native_event = @import("native_event.zig");
const profile_actions = @import("profile_actions.zig");
const settings_actions = @import("settings_actions.zig");
const terminal_state = @import("terminal_state.zig");
const transfer_rules = @import("transfer_rules.zig");
const workspace_actions = @import("workspace_actions.zig");
const profile = @import("../core/profile.zig");
const remote_file = @import("../core/remote_file.zig");
const transfer = @import("../core/transfer.zig");
const ssh = @import("../contracts/ssh.zig");
const profile_repository = @import("../runtime/profiles/profile_repository.zig");
const session_registry = @import("../runtime/sessions/registry.zig");
const ssh_session = @import("../runtime/sessions/ssh_session.zig");
const known_hosts_store = @import("../security/known_hosts.zig");
const terminal = @import("../contracts/terminal_emulator.zig");
const predictive = @import("../core/terminal/predictive.zig");
const ui_theme = @import("../ui/theme.zig");

const App = @This();

pub const Dependencies = struct {
    ssh_connector: ssh.Connector,
    terminal_factory: ssh_session.TerminalFactory,
};

const terminal_snapshot_max_fps: i128 = 60;
const terminal_snapshot_min_interval_ns: i128 = std.time.ns_per_s / terminal_snapshot_max_fps;

const GroupExpansion = struct {
    name: []const u8,
    expanded: bool,
};

const ProfileSecurity = enum {
    plain,
    locked,
    unlocked_encrypted,
};

const TransferRetryRecord = struct {
    id: u64,
    tab_id: u64,
    intent: remote_file.FilePanelIntent,
};

const DirtyEditorRecord = struct {
    tab_id: u64,
};

pub const CloseBlockers = struct {
    active_transfers: usize = 0,
    dirty_editors: usize = 0,
    active_sessions: usize = 0,

    pub fn any(self: CloseBlockers) bool {
        return self.active_transfers > 0 or self.dirty_editors > 0 or self.active_sessions > 0;
    }
};

const TerminalSnapshotCache = terminal_state.SnapshotCache;
const TerminalPredictiveState = terminal_state.PredictiveState;

allocator: std.mem.Allocator,
io: ?std.Io = null,
config: app_config.Config,
profiles: profile_repository.MemoryProfileRepository,
known_hosts: known_hosts_store.KnownHosts,
sessions: session_registry.SessionRegistry,
ssh_connector: ssh.Connector,
terminal_factory: ssh_session.TerminalFactory,
transfers: std.ArrayList(transfer.TransferTask) = .empty,
transfer_retries: std.ArrayList(TransferRetryRecord) = .empty,
dirty_editors: std.ArrayList(DirtyEditorRecord) = .empty,
native_events: std.ArrayList(native_event.NativeEvent) = .empty,
terminal_snapshot_cache: TerminalSnapshotCache = .{},
terminal_predictive_states: std.ArrayList(TerminalPredictiveState) = .empty,
file_drag_active: bool = false,
file_drag_point: native_event.Point = .{},
file_drop_target_active: bool = false,
file_drop_target_rect: native_event.Rect = .{},
next_transfer_id: u64 = 1,
selected_profile_id: ?u64 = null,
draft: profile.ProfileDraft = .{},
show_config: bool = false,
theme_mode: ui_theme.ThemeMode = .dark,
last_profile_click_id: ?u64 = null,
last_profile_click_frame: u64 = 0,
frame_index: u64 = 0,
message: []const u8 = "Home",
connection_search: [128]u8 = std.mem.zeroes([128]u8),
group_expansions: std.ArrayList(GroupExpansion) = .empty,
group_defaults_initialized: bool = false,
profile_security: ProfileSecurity = .plain,
unlock_password: [128]u8 = std.mem.zeroes([128]u8),
master_password_session: [128]u8 = std.mem.zeroes([128]u8),
master_password_new: [128]u8 = std.mem.zeroes([128]u8),
master_password_confirm: [128]u8 = std.mem.zeroes([128]u8),
master_password_disable: [128]u8 = std.mem.zeroes([128]u8),
window_close_pending: bool = false,
window_close_approved: bool = false,

const profiles_path = "data/profiles.json";
const known_hosts_path = "data/known_hosts.json";
const transfer_speed_sample_ns: i128 = 500 * std.time.ns_per_ms;

pub fn initMemory(allocator: std.mem.Allocator, dependencies: Dependencies) !App {
    var config = try app_config.Config.load(allocator, null);
    errdefer config.deinit();
    var app = App{
        .allocator = allocator,
        .config = config,
        .profiles = profile_repository.MemoryProfileRepository.init(allocator),
        .known_hosts = known_hosts_store.KnownHosts.init(allocator),
        .sessions = session_registry.SessionRegistry.init(allocator),
        .ssh_connector = dependencies.ssh_connector,
        .terminal_factory = dependencies.terminal_factory,
    };
    app.theme_mode = app.config.theme_mode;
    app.draft.reset();
    try app.profiles.seedDefaults();
    app.selectFirstProfile();
    return app;
}

pub fn initPersistent(allocator: std.mem.Allocator, io: std.Io, dependencies: Dependencies) !App {
    var config = try app_config.Config.load(allocator, io);
    errdefer config.deinit();
    var app = App{
        .allocator = allocator,
        .io = io,
        .config = config,
        .profiles = profile_repository.MemoryProfileRepository.init(allocator),
        .known_hosts = known_hosts_store.KnownHosts.init(allocator),
        .sessions = session_registry.SessionRegistry.init(allocator),
        .ssh_connector = dependencies.ssh_connector,
        .terminal_factory = dependencies.terminal_factory,
    };
    app.theme_mode = app.config.theme_mode;
    app.draft.reset();
    try app.known_hosts.loadFromDisk(io, known_hosts_path);
    if (try app.profiles.profileFileEncrypted(io, profiles_path)) {
        app.profile_security = .locked;
    } else {
        try app.profiles.loadFromDisk(io, profiles_path);
        if (app.profiles.items().len == 0) {
            try app.profiles.seedDefaults();
            try app.profiles.saveToDisk(io, profiles_path);
        }
        app.selectFirstProfile();
    }
    return app;
}

pub fn deinit(self: *App) void {
    self.config.theme_mode = self.theme_mode;
    self.persistConfig();
    self.clearMasterPasswordInputs();
    profile.setBuffer(&self.master_password_session, "");
    for (self.group_expansions.items) |entry| {
        self.allocator.free(entry.name);
    }
    self.group_expansions.deinit(self.allocator);
    self.sessions.deinit();
    self.terminal_snapshot_cache.deinit();
    for (self.terminal_predictive_states.items) |*slot_state| slot_state.deinit();
    self.terminal_predictive_states.deinit(self.allocator);
    self.persistKnownHosts();
    self.profiles.deinit();
    self.known_hosts.deinit();
    for (self.transfers.items) |task| {
        self.allocator.free(task.title);
    }
    self.transfers.deinit(self.allocator);
    for (self.transfer_retries.items) |record| {
        self.freeRetryIntent(record.intent);
    }
    self.transfer_retries.deinit(self.allocator);
    self.dirty_editors.deinit(self.allocator);
    self.clearNativeEvents();
    self.native_events.deinit(self.allocator);
    self.config.deinit();
}

pub fn pushFileDrop(self: *App, path: []const u8, x: f32, y: f32) !void {
    self.updateFileDrag(x, y);
    const owned_path = try self.allocator.dupe(u8, path);
    errdefer self.allocator.free(owned_path);
    try self.native_events.append(self.allocator, .{ .file_drop = .{
        .path = owned_path,
        .x = x,
        .y = y,
    } });
}

pub fn beginNativeFrame(self: *App) void {
    self.file_drop_target_active = false;
}

pub fn beginFileDrag(self: *App) void {
    self.file_drag_active = true;
}

pub fn updateFileDrag(self: *App, x: f32, y: f32) void {
    self.file_drag_active = true;
    self.file_drag_point = .{ .x = x, .y = y };
}

pub fn endFileDrag(self: *App) void {
    self.file_drag_active = false;
}

pub fn fileDragPoint(self: *const App) ?native_event.Point {
    if (!self.file_drag_active) return null;
    return self.file_drag_point;
}

pub fn registerFileDropTarget(self: *App, rect: native_event.Rect) void {
    self.file_drop_target_active = true;
    self.file_drop_target_rect = rect;
}

pub fn canAcceptFileDrop(self: *const App, x: f32, y: f32) bool {
    if (!self.file_drop_target_active) return false;
    return self.file_drop_target_rect.contains(.{ .x = x, .y = y });
}

pub fn nativeEvents(self: *const App) []const native_event.NativeEvent {
    return self.native_events.items;
}

pub fn clearNativeEvents(self: *App) void {
    for (self.native_events.items) |event| native_event.deinitEvent(self.allocator, event);
    self.native_events.clearRetainingCapacity();
}

pub fn selectProfile(self: *App, id: u64) void {
    profile_actions.select(self, id);
}

pub fn newProfile(self: *App) void {
    profile_actions.create(self);
}

pub fn editProfile(self: *App, id: u64) void {
    profile_actions.edit(self, id);
}

pub fn cancelConfig(self: *App) void {
    profile_actions.cancel(self);
}

pub fn goHome(self: *App) void {
    settings_actions.goHome(self);
}

pub fn toggleTheme(self: *App) void {
    settings_actions.toggleTheme(self);
}

pub fn setThemeMode(self: *App, mode: ui_theme.ThemeMode) void {
    settings_actions.setThemeMode(self, mode);
}

pub fn setDownloadPath(self: *App, path: []const u8) void {
    settings_actions.setDownloadPath(self, path);
}

pub fn setTerminalPredictionMode(self: *App, mode: predictive.PredictionMode) void {
    settings_actions.setTerminalPredictionMode(self, mode);
}

pub fn applyTerminalPredictionConfig(self: *App) void {
    settings_actions.applyTerminalPredictionConfig(self);
}

pub fn beginFrame(self: *App) void {
    self.frame_index +%= 1;
    self.sessions.pollWorkers();
    self.syncTerminalLatencyProbes();
    self.syncTransferProgress();
}

pub fn observeWindowSize(self: *App, width: f32, height: f32) void {
    if (!std.math.isFinite(width) or !std.math.isFinite(height)) return;
    if (width <= 0 or height <= 0) return;
    self.config.window_size = .{ .w = width, .h = height };
}

pub fn saveDraft(self: *App) void {
    if (profile.textFromBuffer(&self.draft.name).len == 0 or profile.textFromBuffer(&self.draft.host).len == 0) {
        self.message = "Name and host are required";
        return;
    }
    switch (self.draft.auth_type) {
        .password => if (profile.textFromBuffer(&self.draft.password).len == 0) {
            self.message = "Password is required";
            return;
        },
        .private_key => if (profile.textFromBuffer(&self.draft.private_key_path).len == 0) {
            self.message = "Private key path is required";
            return;
        },
        .agent => {},
    }

    const id = self.profiles.upsertDraft(&self.draft) catch {
        self.message = "Could not save profile";
        return;
    };
    self.persistProfiles();
    self.selected_profile_id = id;
    if (self.profiles.get(id)) |item| {
        self.draft.load(item.*);
    }
    self.show_config = false;
    self.message = "Profile saved";
}

pub fn deleteSelectedProfile(self: *App) void {
    const id = self.selected_profile_id orelse {
        self.message = "No profile selected";
        return;
    };
    self.profiles.remove(id) catch {
        self.message = "Could not delete profile";
        return;
    };
    self.persistProfiles();
    self.selected_profile_id = null;
    self.draft.reset();
    self.show_config = false;
    self.message = "Profile deleted";
}

pub fn configVisible(self: *const App) bool {
    return self.show_config;
}

pub fn profilesLocked(self: *const App) bool {
    return self.profile_security == .locked;
}

pub fn masterPasswordEnabled(self: *const App) bool {
    return self.profile_security != .plain;
}

pub fn unlockProfiles(self: *App) void {
    const io = self.io orelse {
        self.message = "Persistent storage is not available";
        return;
    };
    const password = profile.textFromBuffer(&self.unlock_password);
    if (password.len == 0) {
        self.message = "Master password is required";
        return;
    }

    self.profiles.loadFromDiskWithPassword(io, profiles_path, password) catch |err| {
        self.message = switch (err) {
            profile_repository.Error.WrongMasterPassword => "Wrong master password",
            profile_repository.Error.MasterPasswordRequired => "Master password is required",
            else => "Could not unlock profiles",
        };
        return;
    };
    profile.setBuffer(&self.master_password_session, password);
    profile.setBuffer(&self.unlock_password, "");
    self.profile_security = .unlocked_encrypted;
    self.group_defaults_initialized = false;
    self.selectFirstProfile();
    self.message = "Profiles unlocked";
}

pub fn enableMasterPassword(self: *App) void {
    const password = profile.textFromBuffer(&self.master_password_new);
    const confirm = profile.textFromBuffer(&self.master_password_confirm);
    if (password.len == 0) {
        self.message = "Master password is required";
        return;
    }
    if (!std.mem.eql(u8, password, confirm)) {
        self.message = "Master passwords do not match";
        return;
    }

    const io = self.io orelse {
        self.message = "Persistent storage is not available";
        return;
    };
    self.profiles.saveToDiskWithPassword(io, profiles_path, password) catch {
        self.message = "Could not enable master password";
        return;
    };
    profile.setBuffer(&self.master_password_session, password);
    self.clearMasterPasswordInputs();
    self.profile_security = .unlocked_encrypted;
    self.message = "Master password enabled";
}

pub fn cancelMasterPasswordSetup(self: *App) void {
    profile.setBuffer(&self.master_password_new, "");
    profile.setBuffer(&self.master_password_confirm, "");
    profile.setBuffer(&self.master_password_disable, "");
    self.message = "Home";
}

pub fn disableMasterPassword(self: *App) void {
    if (self.profile_security != .unlocked_encrypted) {
        self.message = "Profiles must be unlocked first";
        return;
    }
    const password = profile.textFromBuffer(&self.master_password_disable);
    const session_password = profile.textFromBuffer(&self.master_password_session);
    if (password.len == 0) {
        self.message = "Master password is required";
        return;
    }
    if (!std.mem.eql(u8, password, session_password)) {
        self.message = "Wrong master password";
        return;
    }

    const io = self.io orelse {
        self.message = "Persistent storage is not available";
        return;
    };
    self.profiles.saveToDiskWithPassword(io, profiles_path, null) catch {
        self.message = "Could not disable master password";
        return;
    };
    self.profile_security = .plain;
    self.clearMasterPasswordInputs();
    profile.setBuffer(&self.master_password_session, "");
    self.message = "Master password disabled";
}

pub fn pendingHostKey(self: *App, allocator: std.mem.Allocator) ?known_hosts_store.PendingHostKey {
    return self.known_hosts.copyPendingHostKey(allocator) catch {
        self.message = "Could not read pending host key";
        return null;
    };
}

pub fn trustPendingHostKey(self: *App) void {
    self.known_hosts.trustPendingHostKey() catch {
        self.message = "Could not trust host key";
        return;
    };
    self.persistKnownHosts();
    self.message = "Host key trusted";
    if (self.sessions.activeTab()) |tab| {
        if (tab.status == .failed) self.reconnectTab(tab.id);
    }
}

pub fn rejectPendingHostKey(self: *App) void {
    self.known_hosts.clearPendingHostKey();
    self.message = "Host key rejected";
}

pub fn connectionSearchText(self: *const App) []const u8 {
    return profile.textFromBuffer(&self.connection_search);
}

pub fn ensureGroupDefaults(self: *App, visible_profile_capacity: usize) void {
    if (self.group_defaults_initialized) return;
    self.group_defaults_initialized = true;

    const expand_default = self.profiles.items().len <= visible_profile_capacity;
    for (self.profiles.items()) |item| {
        const group = normalizedGroup(item.base.group);
        if (self.groupExpansionIndex(group) != null) continue;
        self.addGroupExpansion(group, expand_default and std.mem.eql(u8, group, "Default")) catch {
            self.message = "Could not initialize groups";
            return;
        };
    }
}

pub fn isGroupExpanded(self: *App, group_name: []const u8) bool {
    const group = normalizedGroup(group_name);
    if (self.groupExpansionIndex(group)) |idx| {
        return self.group_expansions.items[idx].expanded;
    }

    self.addGroupExpansion(group, false) catch {
        self.message = "Could not update group";
        return false;
    };
    return false;
}

pub fn toggleGroup(self: *App, group_name: []const u8) void {
    const group = normalizedGroup(group_name);
    if (self.groupExpansionIndex(group)) |idx| {
        self.group_expansions.items[idx].expanded = !self.group_expansions.items[idx].expanded;
        return;
    }

    self.addGroupExpansion(group, true) catch {
        self.message = "Could not update group";
    };
}

pub fn openProfile(self: *App, id: u64) void {
    self.selected_profile_id = id;
    self.terminal_snapshot_cache.clear();
    const item = self.profiles.get(id) orelse {
        self.message = "Profile not found";
        return;
    };

    _ = self.sessions.openSshWorkerTab(item.*, self.sshRuntimeOptions()) catch {
        self.message = "Could not start SSH session";
        return;
    };
    self.message = "SSH session starting";
}

pub fn profileClicked(self: *App, id: u64) void {
    self.selectProfile(id);
    if (self.last_profile_click_id == id and self.frame_index -% self.last_profile_click_frame <= 30) {
        self.openProfile(id);
    }
    self.last_profile_click_id = id;
    self.last_profile_click_frame = self.frame_index;
}

pub fn currentTitle(self: *App) []const u8 {
    if (self.sessions.activeTab()) |tab| return tab.title;
    return "Shellowo";
}

pub fn closeTab(self: *App, tab_id: u64) void {
    self.terminal_snapshot_cache.clear();
    self.removeTerminalPredictiveStatesForTab(tab_id);
    self.reportRemoteEditorDirty(tab_id, false);
    self.sessions.closeTab(tab_id);
}

pub fn reportRemoteEditorDirty(self: *App, tab_id: u64, dirty: bool) void {
    for (self.dirty_editors.items, 0..) |record, idx| {
        if (record.tab_id != tab_id) continue;
        if (!dirty) _ = self.dirty_editors.orderedRemove(idx);
        return;
    }
    if (dirty) self.dirty_editors.append(self.allocator, .{ .tab_id = tab_id }) catch {};
}

pub fn closeBlockers(self: *const App) CloseBlockers {
    var blockers: CloseBlockers = .{
        .dirty_editors = self.dirty_editors.items.len,
    };
    for (self.transfers.items) |task| {
        if (task.status == .pending or task.status == .running) blockers.active_transfers += 1;
    }
    for (self.sessions.tabs.items) |tab| {
        switch (tab.status) {
            .failed, .closed => {},
            else => blockers.active_sessions += 1,
        }
    }
    return blockers;
}

pub fn requestWindowClose(self: *App) void {
    if (self.window_close_approved) return;
    if (self.closeBlockers().any()) {
        self.window_close_pending = true;
    } else {
        self.window_close_approved = true;
    }
}

pub fn cancelWindowClose(self: *App) void {
    self.window_close_pending = false;
}

pub fn confirmWindowClose(self: *App) void {
    self.window_close_pending = false;
    self.window_close_approved = true;
}

pub fn windowClosePending(self: *const App) bool {
    return self.window_close_pending;
}

pub fn takeWindowCloseApproved(self: *App) bool {
    const approved = self.window_close_approved;
    self.window_close_approved = false;
    return approved;
}

pub fn sendTerminalBytes(self: *App, tab_id: u64, bytes: []const u8) void {
    workspace_actions.sendTerminalBytes(self, tab_id, bytes);
}

pub fn sendTerminalMouse(self: *App, tab_id: u64, event: terminal.MouseEvent) void {
    workspace_actions.sendTerminalMouse(self, tab_id, event);
}

pub fn resizeTerminal(self: *App, tab_id: u64, size: ssh.PtySize) void {
    workspace_actions.resizeTerminal(self, tab_id, size);
}

pub fn clearTerminalScrollback(self: *App, tab_id: u64) void {
    workspace_actions.clearScrollback(self, tab_id);
}

pub fn createTerminalSlot(self: *App, tab_id: u64) void {
    workspace_actions.createTerminalSlot(self, tab_id);
}

pub fn activateTerminalSlot(self: *App, tab_id: u64, slot_id: u64) void {
    workspace_actions.activateTerminalSlot(self, tab_id, slot_id);
}

pub fn closeTerminalSlot(self: *App, tab_id: u64, slot_id: u64) void {
    self.terminal_snapshot_cache.clear();
    self.removeTerminalPredictiveState(tab_id, slot_id);
    if (!self.sessions.closeTerminalSlot(tab_id, slot_id)) {
        self.message = "Terminal not found";
        return;
    }
    self.message = "Terminal closed";
}

pub fn reconnectTab(self: *App, tab_id: u64) void {
    self.terminal_snapshot_cache.clear();
    const tab = self.sessions.tabById(tab_id) orelse {
        self.message = "Workspace tab not found";
        return;
    };
    self.removeTerminalPredictiveStatesForTab(tab_id);
    self.openProfile(tab.profile_id);
}

pub fn filePanelSnapshot(self: *App, tab_id: u64, tree_buffer: []remote_file.RemoteFileEntry, remote_buffer: []remote_file.RemoteFileEntry) remote_file.FilePanelSnapshot {
    return self.sessions.filePanelSnapshot(tab_id, tree_buffer, remote_buffer);
}

pub fn cachedSshSnapshot(self: *App, tab_id: u64, slot_id: ?u64, now_ns: i128) ?terminal.Snapshot {
    const active_slot_id = slot_id orelse {
        self.terminal_snapshot_cache.clear();
        return null;
    };
    const generation = self.sessions.sshSnapshotGeneration(tab_id, active_slot_id) orelse {
        self.terminal_snapshot_cache.clear();
        return null;
    };

    if (self.terminal_snapshot_cache.snapshot != null and
        self.terminal_snapshot_cache.tab_id == tab_id and
        self.terminal_snapshot_cache.slot_id == active_slot_id and
        self.terminal_snapshot_cache.generation == generation)
    {
        self.terminal_snapshot_cache.pending_generation = null;
        return self.terminal_snapshot_cache.snapshot.?;
    }

    if (self.terminal_snapshot_cache.snapshot != null and
        self.terminal_snapshot_cache.tab_id == tab_id and
        self.terminal_snapshot_cache.slot_id == active_slot_id and
        now_ns - self.terminal_snapshot_cache.last_present_ns < terminal_snapshot_min_interval_ns)
    {
        self.terminal_snapshot_cache.pending_generation = generation;
        return self.terminal_snapshot_cache.snapshot.?;
    }

    const snapshot = self.sessions.copySshSnapshot(self.allocator, tab_id) catch {
        self.terminal_snapshot_cache.clear();
        return null;
    } orelse {
        self.terminal_snapshot_cache.clear();
        return null;
    };

    const state = self.ensureTerminalPredictiveState(tab_id, active_slot_id) catch {
        self.terminal_snapshot_cache.clear();
        return null;
    };
    state.prediction_policy.config = self.config.terminal_prediction.toCore();
    _ = state.syncRealAt(snapshot, frameNsToMs(now_ns)) catch {
        self.terminal_snapshot_cache.clear();
        return null;
    };

    if (self.terminal_snapshot_cache.snapshot) |*cached| cached.deinit();
    self.terminal_snapshot_cache.tab_id = tab_id;
    self.terminal_snapshot_cache.slot_id = active_slot_id;
    self.terminal_snapshot_cache.generation = snapshot.generation;
    self.terminal_snapshot_cache.pending_generation = null;
    self.terminal_snapshot_cache.last_present_ns = now_ns;
    self.terminal_snapshot_cache.snapshot = snapshot;
    return self.terminal_snapshot_cache.snapshot.?;
}

pub fn predictedSshSnapshot(self: *const App, tab_id: u64, slot_id: ?u64) ?terminal.Snapshot {
    const active_slot_id = slot_id orelse return null;
    const state = self.terminalPredictiveState(tab_id, active_slot_id) orelse return null;
    const predicted = state.predictedSnapshot() orelse return null;
    return predicted.*;
}

pub fn decideTerminalPrediction(self: *App, tab_id: u64, slot_id: ?u64, snapshot: terminal.Snapshot, context: predictive.PredictionContext, bytes: []const u8, now_ns: i128) predictive.PredictionDecision {
    const active_slot_id = slot_id orelse return .{ .allowed = false, .level = .disabled, .kind = predictive.classifyPrediction(bytes) };
    const state = self.ensureTerminalPredictiveState(tab_id, active_slot_id) catch {
        return predictive.decidePrediction(snapshot, context, bytes, .disabled, self.config.terminal_prediction.toCore());
    };
    state.prediction_policy.config = self.config.terminal_prediction.toCore();
    return state.decideCurrentPrediction(snapshot, context, bytes, frameNsToMs(now_ns));
}

pub fn recordTerminalPrediction(self: *App, tab_id: u64, slot_id: ?u64, bytes: []const u8, now_ns: i128) void {
    const active_slot_id = slot_id orelse return;
    const state = self.ensureTerminalPredictiveState(tab_id, active_slot_id) catch {
        self.message = "Terminal prediction unavailable";
        return;
    };
    state.prediction_policy.config = self.config.terminal_prediction.toCore();
    _ = state.recordLocalInput(bytes, frameNsToMs(now_ns)) catch {
        self.message = "Terminal prediction paused";
        return;
    };
}

pub fn terminalPredictionDiagnostics(self: *const App, tab_id: u64, slot_id: ?u64) predictive.PredictionDiagnostics {
    const active_slot_id = slot_id orelse return .{};
    const state = self.terminalPredictiveState(tab_id, active_slot_id) orelse return .{};
    return state.diagnostics();
}

pub fn terminalSnapshotPendingDelayNs(self: *const App, tab_id: u64, slot_id: ?u64, now_ns: i128) ?i128 {
    const active_slot_id = slot_id orelse return null;
    if (self.terminal_snapshot_cache.snapshot == null) return null;
    if (self.terminal_snapshot_cache.tab_id != tab_id) return null;
    if (self.terminal_snapshot_cache.slot_id != active_slot_id) return null;
    _ = self.terminal_snapshot_cache.pending_generation orelse return null;

    const elapsed = now_ns - self.terminal_snapshot_cache.last_present_ns;
    if (elapsed >= terminal_snapshot_min_interval_ns) return 0;
    return terminal_snapshot_min_interval_ns - elapsed;
}

pub fn handleFilePanelIntent(self: *App, tab_id: u64, intent: remote_file.FilePanelIntent) void {
    var queued_intent = intent;
    if (std.meta.activeTag(queued_intent) == .go_path) {
        queued_intent.go_path.terminal_slot_id = self.sessions.activeTerminalSlotId(tab_id);
    }
    const transfer_id = self.recordFileTransfer(tab_id, &queued_intent) catch {
        self.message = "Could not create transfer task";
        return;
    };
    self.sessions.handleFilePanelIntent(tab_id, queued_intent) catch {
        if (transfer_id) |id| self.dismissTransfer(id);
        self.message = "File action is not available yet";
        return;
    };
    self.message = fileIntentMessage(intent);
}

pub fn cancelTransfer(self: *App, transfer_id: u64) void {
    self.sessions.cancelTransfer(transfer_id);
    if (self.transferIndex(transfer_id)) |idx| {
        self.transfers.items[idx].status = .canceled;
        self.transfers.items[idx].progress = 1;
        self.transfers.items[idx].finished_ns = self.nowNs();
        self.transfers.items[idx].bytes_per_sec = 0;
    }
    self.message = "Transfer canceled";
}

pub fn dismissTransfer(self: *App, transfer_id: u64) void {
    self.removeTransfer(transfer_id);
}

pub fn retryTransfer(self: *App, transfer_id: u64) void {
    const idx = self.transferIndex(transfer_id) orelse return;
    const retry_record = self.retryRecord(transfer_id) orelse return;
    var queued_intent = self.cloneRetryIntent(retry_record.intent) catch {
        self.message = "Could not retry transfer";
        return;
    };
    errdefer self.freeRetryIntent(queued_intent);

    const now = self.nowNs();
    const new_id = self.next_transfer_id;
    self.next_transfer_id += 1;
    setTransferIntentId(&queued_intent, new_id);

    const new_retry_intent = self.cloneRetryIntent(retry_record.intent) catch {
        self.message = "Could not retry transfer";
        return;
    };
    errdefer self.freeRetryIntent(new_retry_intent);

    self.sessions.handleFilePanelIntent(retry_record.tab_id, queued_intent) catch {
        self.message = "Retry is not available";
        return;
    };
    self.freeRetryIntent(queued_intent);

    self.freeRetryIntent(retry_record.intent);
    self.transfer_retries.items[self.retryRecordIndex(transfer_id).?] = .{
        .id = new_id,
        .tab_id = retry_record.tab_id,
        .intent = new_retry_intent,
    };

    self.transfers.items[idx].id = new_id;
    self.transfers.items[idx].status = .pending;
    self.transfers.items[idx].progress = 0;
    self.transfers.items[idx].bytes_done = 0;
    self.transfers.items[idx].bytes_total = null;
    self.transfers.items[idx].bytes_per_sec = 0;
    self.transfers.items[idx].started_ns = now;
    self.transfers.items[idx].finished_ns = null;
    self.transfers.items[idx].last_sample_ns = now;
    self.transfers.items[idx].last_sample_bytes = 0;
    self.transfers.items[idx].error_len = 0;
    self.transfers.items[idx].attempt += 1;
    self.message = "Transfer retry started";
}

pub fn remoteEntryTransferBusy(self: *const App, remote_path: []const u8, name: []const u8) bool {
    for (self.transfers.items) |task| {
        if (task.status != .pending and task.status != .running) continue;
        const record = self.retryRecord(task.id) orelse continue;
        switch (record.intent) {
            .download => |item| if (transfer_rules.remoteEntryMatches(item.remote_path, item.name, remote_path, name)) return true,
            .upload => |item| if (transfer_rules.remoteEntryMatches(item.remote_path, item.name, remote_path, name)) return true,
            .download_many => |item| if (transfer_rules.batchContainsRemoteEntry(item, remote_path, name)) return true,
            .upload_many => |item| if (transfer_rules.batchContainsRemoteEntry(item, remote_path, name)) return true,
            else => {},
        }
    }
    return false;
}

pub fn transferBusyInRemotePath(self: *const App, remote_path: []const u8) bool {
    for (self.transfers.items) |task| {
        if (task.status != .pending and task.status != .running) continue;
        const record = self.retryRecord(task.id) orelse continue;
        switch (record.intent) {
            .download => |item| if (transfer_rules.pathsOverlap(item.remote_path, remote_path)) return true,
            .download_many => |item| if (transfer_rules.pathsOverlap(item.remote_path, remote_path)) return true,
            .upload => |item| if (transfer_rules.pathsOverlap(item.remote_path, remote_path)) return true,
            .upload_many => |item| if (transfer_rules.pathsOverlap(item.remote_path, remote_path)) return true,
            else => {},
        }
    }
    return false;
}

fn syncTransferProgress(self: *App) void {
    var buffer: [128]transfer.TransferProgress = undefined;
    const updates = self.sessions.transferProgress(&buffer);
    for (updates) |update| {
        const idx = self.transferIndex(update.id) orelse continue;
        self.applyTransferProgress(idx, update);
    }
}

fn recordFileTransfer(self: *App, tab_id: u64, intent: *remote_file.FilePanelIntent) !?u64 {
    switch (intent.*) {
        .upload => |*upload| {
            const id = try self.appendNamedTransfer(tab_id, .upload, upload.name, intent.*);
            upload.transfer_id = id;
            return id;
        },
        .upload_many => |*upload_many| {
            if (upload_many.entries.len == 1) {
                const id = try self.appendNamedTransfer(tab_id, .upload, upload_many.entries[0].name, intent.*);
                upload_many.transfer_id = id;
                return id;
            } else {
                var title_buf: [64]u8 = undefined;
                const title = try std.fmt.bufPrint(&title_buf, "Upload {d} items", .{upload_many.entries.len});
                const id = try self.appendTransferTitle(tab_id, .upload, title, intent.*);
                upload_many.transfer_id = id;
                return id;
            }
        },
        .download => |*download| {
            const id = try self.appendNamedTransfer(tab_id, .download, download.name, intent.*);
            download.transfer_id = id;
            return id;
        },
        .download_many => |*download_many| {
            if (download_many.entries.len == 1) {
                const id = try self.appendNamedTransfer(tab_id, .download, download_many.entries[0].name, intent.*);
                download_many.transfer_id = id;
                return id;
            } else {
                var title_buf: [64]u8 = undefined;
                const title = try std.fmt.bufPrint(&title_buf, "Download {d} items", .{download_many.entries.len});
                const id = try self.appendTransferTitle(tab_id, .download, title, intent.*);
                download_many.transfer_id = id;
                return id;
            }
        },
        else => return null,
    }
}

fn appendNamedTransfer(self: *App, tab_id: u64, direction: transfer.TransferDirection, name: []const u8, intent: remote_file.FilePanelIntent) !u64 {
    const action = switch (direction) {
        .download => "Download",
        .upload => "Upload",
    };
    const title = try std.fmt.allocPrint(self.allocator, "{s} '{s}'", .{ action, name });
    return self.appendOwnedTransferTitle(tab_id, direction, title, intent);
}

fn appendTransferTitle(self: *App, tab_id: u64, direction: transfer.TransferDirection, title_text: []const u8, intent: remote_file.FilePanelIntent) !u64 {
    const title = try self.allocator.dupe(u8, title_text);
    return self.appendOwnedTransferTitle(tab_id, direction, title, intent);
}

fn appendOwnedTransferTitle(self: *App, tab_id: u64, direction: transfer.TransferDirection, title: []const u8, intent: remote_file.FilePanelIntent) !u64 {
    errdefer self.allocator.free(title);
    const retry_intent = try self.cloneRetryIntent(intent);
    errdefer self.freeRetryIntent(retry_intent);
    const id = self.next_transfer_id;
    const now = self.nowNs();
    try self.transfers.append(self.allocator, .{
        .id = id,
        .tab_id = tab_id,
        .title = title,
        .direction = direction,
        .status = .pending,
        .progress = 0,
        .started_ns = now,
        .last_sample_ns = now,
    });
    errdefer _ = self.transfers.pop();
    try self.transfer_retries.append(self.allocator, .{ .id = id, .tab_id = tab_id, .intent = retry_intent });
    self.next_transfer_id += 1;
    return id;
}

fn applyTransferProgress(self: *App, idx: usize, update: transfer.TransferProgress) void {
    var task = &self.transfers.items[idx];
    const now = self.nowNs();
    const is_terminal = update.status == .completed or update.status == .failed or update.status == .canceled;
    if (!is_terminal and update.bytes_done >= task.last_sample_bytes and now - task.last_sample_ns >= transfer_speed_sample_ns) {
        const delta_bytes = update.bytes_done - task.last_sample_bytes;
        const delta_ns = now - task.last_sample_ns;
        if (delta_ns > 0) {
            task.bytes_per_sec = @as(f32, @floatFromInt(delta_bytes)) / (@as(f32, @floatFromInt(delta_ns)) / @as(f32, @floatFromInt(std.time.ns_per_s)));
        }
        task.last_sample_ns = now;
        task.last_sample_bytes = update.bytes_done;
    }
    task.status = update.status;
    task.progress = update.progress;
    task.bytes_done = update.bytes_done;
    task.bytes_total = update.bytes_total;
    task.error_summary = update.error_summary;
    task.error_len = update.error_len;
    if (is_terminal) {
        if (task.finished_ns == null) task.finished_ns = now;
        task.last_sample_ns = now;
        task.last_sample_bytes = update.bytes_done;
        task.bytes_per_sec = 0;
    }
}

fn transferIndex(self: *const App, transfer_id: u64) ?usize {
    for (self.transfers.items, 0..) |task, idx| {
        if (task.id == transfer_id) return idx;
    }
    return null;
}

fn removeTransfer(self: *App, transfer_id: u64) void {
    const idx = self.transferIndex(transfer_id) orelse return;
    self.removeTransferAt(idx);
}

fn removeTransferAt(self: *App, idx: usize) void {
    const id = self.transfers.items[idx].id;
    self.allocator.free(self.transfers.items[idx].title);
    _ = self.transfers.orderedRemove(idx);
    if (self.retryRecordIndex(id)) |record_idx| {
        self.freeRetryIntent(self.transfer_retries.items[record_idx].intent);
        _ = self.transfer_retries.orderedRemove(record_idx);
    }
}

fn retryRecord(self: *const App, transfer_id: u64) ?TransferRetryRecord {
    const idx = self.retryRecordIndex(transfer_id) orelse return null;
    return self.transfer_retries.items[idx];
}

fn retryRecordIndex(self: *const App, transfer_id: u64) ?usize {
    for (self.transfer_retries.items, 0..) |record, idx| {
        if (record.id == transfer_id) return idx;
    }
    return null;
}

fn cloneRetryIntent(self: *App, intent: remote_file.FilePanelIntent) !remote_file.FilePanelIntent {
    var copied = try remote_file.clonePanelIntent(self.allocator, intent);
    clearTransferIntentId(&copied);
    return copied;
}

fn freeRetryIntent(self: *App, intent: remote_file.FilePanelIntent) void {
    remote_file.freePanelIntent(self.allocator, intent);
}

fn setTransferIntentId(intent: *remote_file.FilePanelIntent, id: u64) void {
    switch (intent.*) {
        .upload => |*item| item.transfer_id = id,
        .download => |*item| item.transfer_id = id,
        .upload_many => |*item| item.transfer_id = id,
        .download_many => |*item| item.transfer_id = id,
        else => {},
    }
}

fn clearTransferIntentId(intent: *remote_file.FilePanelIntent) void {
    switch (intent.*) {
        .upload => |*item| item.transfer_id = null,
        .download => |*item| item.transfer_id = null,
        .upload_many => |*item| item.transfer_id = null,
        .download_many => |*item| item.transfer_id = null,
        else => {},
    }
}

fn nowNs(self: *const App) i128 {
    if (self.io) |io| {
        const timestamp = std.Io.Clock.awake.now(io);
        return timestamp.nanoseconds;
    }

    if (builtin.os.tag == .windows) {
        return 0;
    } else {
        var ts: std.posix.timespec = undefined;
        switch (std.posix.errno(std.posix.system.clock_gettime(.MONOTONIC, &ts))) {
            .SUCCESS => return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec,
            else => return 0,
        }
    }
}

fn selectFirstProfile(self: *App) void {
    if (self.profiles.items().len == 0) return;
    self.selected_profile_id = self.profiles.items()[0].base.id;
    self.draft.load(self.profiles.items()[0]);
}

fn persistProfiles(self: *App) void {
    const io = self.io orelse return;
    const password: ?[]const u8 = if (self.profile_security == .unlocked_encrypted)
        profile.textFromBuffer(&self.master_password_session)
    else
        null;
    self.profiles.saveToDiskWithPassword(io, profiles_path, password) catch {
        self.message = "Profile saved in memory, but disk write failed";
    };
}

fn clearMasterPasswordInputs(self: *App) void {
    profile.setBuffer(&self.unlock_password, "");
    profile.setBuffer(&self.master_password_new, "");
    profile.setBuffer(&self.master_password_confirm, "");
    profile.setBuffer(&self.master_password_disable, "");
}

fn persistConfig(self: *App) void {
    self.config.save(self.io) catch {
        self.message = "Config saved in memory, but disk write failed";
    };
}

pub fn persistKnownHosts(self: *App) void {
    const io = self.io orelse return;
    self.known_hosts.saveToDisk(io, known_hosts_path) catch {
        self.message = "Known host trusted in memory, but disk write failed";
    };
}

pub fn sshRuntimeOptions(self: *App) ssh_session.Options {
    return .{
        .connector = self.ssh_connector,
        .terminal_factory = self.terminal_factory,
        .io = self.io,
        .host_key_verifier = self.known_hosts.verifier(),
        .host_key_policy = .trust_on_first_use,
        .download_path = self.config.download_path,
    };
}

fn ensureTerminalPredictiveState(self: *App, tab_id: u64, slot_id: u64) !*predictive.DualState {
    if (self.terminalPredictiveStateIndex(tab_id, slot_id)) |idx| {
        return &self.terminal_predictive_states.items[idx].state;
    }
    try self.terminal_predictive_states.append(self.allocator, .{
        .tab_id = tab_id,
        .slot_id = slot_id,
        .state = predictive.DualState.init(self.allocator),
    });
    return &self.terminal_predictive_states.items[self.terminal_predictive_states.items.len - 1].state;
}

fn terminalPredictiveState(self: *const App, tab_id: u64, slot_id: u64) ?*const predictive.DualState {
    const idx = self.terminalPredictiveStateIndex(tab_id, slot_id) orelse return null;
    return &self.terminal_predictive_states.items[idx].state;
}

fn terminalPredictiveStateIndex(self: *const App, tab_id: u64, slot_id: u64) ?usize {
    for (self.terminal_predictive_states.items, 0..) |slot_state, idx| {
        if (slot_state.tab_id == tab_id and slot_state.slot_id == slot_id) return idx;
    }
    return null;
}

fn removeTerminalPredictiveState(self: *App, tab_id: u64, slot_id: u64) void {
    const idx = self.terminalPredictiveStateIndex(tab_id, slot_id) orelse return;
    var slot_state = self.terminal_predictive_states.orderedRemove(idx);
    slot_state.deinit();
}

fn removeTerminalPredictiveStatesForTab(self: *App, tab_id: u64) void {
    var idx: usize = 0;
    while (idx < self.terminal_predictive_states.items.len) {
        if (self.terminal_predictive_states.items[idx].tab_id != tab_id) {
            idx += 1;
            continue;
        }
        var slot_state = self.terminal_predictive_states.orderedRemove(idx);
        slot_state.deinit();
    }
}

fn syncTerminalLatencyProbes(self: *App) void {
    for (self.terminal_predictive_states.items) |*slot_state| {
        const probe = self.sessions.latencyProbeSnapshot(slot_state.tab_id);
        const latency_ms = probe.latency_ms orelse continue;
        if (probe.generation == 0 or probe.generation == slot_state.last_probe_generation) continue;
        slot_state.last_probe_generation = probe.generation;
        slot_state.state.prediction_policy.config = self.config.terminal_prediction.toCore();
        slot_state.state.observeProbeLatency(latency_ms);
    }
}

fn frameNsToMs(ns: i128) u64 {
    if (ns <= 0) return 0;
    return @intCast(@divTrunc(ns, std.time.ns_per_ms));
}

fn fileIntentMessage(intent: remote_file.FilePanelIntent) []const u8 {
    return switch (intent) {
        .select => "File selected",
        .toggle_tree => "Toggling folder",
        .refresh => "Refreshing files",
        .go_parent => "Opening parent folder",
        .go_path => "Opening folder",
        .open => "Opening folder",
        .create_file => "Creating file",
        .create_directory => "Creating folder",
        .rename => "Renaming file",
        .chmod => "Updating permissions",
        .open_edit => "Opening editor",
        .save_edit => "Saving file",
        .reload_edit => "Reloading file",
        .close_edit => "Closing editor",
        .delete => "Deleting file",
        .upload, .upload_many => "Uploading file",
        .download, .download_many => "Downloading file",
    };
}

fn normalizedGroup(group_name: []const u8) []const u8 {
    return if (group_name.len == 0) "Default" else group_name;
}

fn groupExpansionIndex(self: *App, group_name: []const u8) ?usize {
    for (self.group_expansions.items, 0..) |entry, idx| {
        if (std.mem.eql(u8, entry.name, group_name)) return idx;
    }
    return null;
}

fn addGroupExpansion(self: *App, group_name: []const u8, expanded: bool) !void {
    try self.group_expansions.append(self.allocator, .{
        .name = try self.allocator.dupe(u8, group_name),
        .expanded = expanded,
    });
}

test "app seeds profiles" {
    var app = try App.initMemory(std.testing.allocator, testingDependencies());
    defer app.deinit();

    try std.testing.expectEqual(@as(usize, 1), app.profiles.items().len);
    try std.testing.expectEqual(@as(u16, 22), app.profiles.items()[0].base.port);
}

test "terminal predictive state is isolated per workspace slot" {
    var app = try App.initMemory(std.testing.allocator, testingDependencies());
    defer app.deinit();

    const first = try app.ensureTerminalPredictiveState(10, 1);
    first.prediction_policy.rollback_count = 3;
    const second = try app.ensureTerminalPredictiveState(10, 2);
    second.prediction_policy.rollback_count = 7;

    try std.testing.expectEqual(@as(u32, 3), app.terminalPredictionDiagnostics(10, 1).rollback_count);
    try std.testing.expectEqual(@as(u32, 7), app.terminalPredictionDiagnostics(10, 2).rollback_count);

    app.removeTerminalPredictiveState(10, 1);
    try std.testing.expect(app.terminalPredictiveState(10, 1) == null);
    try std.testing.expect(app.terminalPredictiveState(10, 2) != null);
}

test "window close is immediate without blockers" {
    var app = try App.initMemory(std.testing.allocator, testingDependencies());
    defer app.deinit();

    app.requestWindowClose();
    try std.testing.expect(!app.windowClosePending());
    try std.testing.expect(app.takeWindowCloseApproved());
    try std.testing.expect(!app.takeWindowCloseApproved());
}

test "window close requires confirmation for dirty editors and transfers" {
    var app = try App.initMemory(std.testing.allocator, testingDependencies());
    defer app.deinit();

    app.reportRemoteEditorDirty(42, true);
    const title = try app.allocator.dupe(u8, "Upload file");
    try app.transfers.append(app.allocator, .{
        .id = 1,
        .tab_id = 42,
        .title = title,
        .direction = .upload,
        .status = .running,
        .progress = 0.5,
    });

    const blockers = app.closeBlockers();
    try std.testing.expectEqual(@as(usize, 1), blockers.dirty_editors);
    try std.testing.expectEqual(@as(usize, 1), blockers.active_transfers);

    app.requestWindowClose();
    try std.testing.expect(app.windowClosePending());
    try std.testing.expect(!app.takeWindowCloseApproved());

    app.cancelWindowClose();
    try std.testing.expect(!app.windowClosePending());

    app.requestWindowClose();
    app.confirmWindowClose();
    try std.testing.expect(app.takeWindowCloseApproved());
    try std.testing.expect(!app.takeWindowCloseApproved());
}

fn testingDependencies() Dependencies {
    return .{
        .ssh_connector = .{
            .context = undefined,
            .vtable = &testing_connector_vtable,
        },
        .terminal_factory = .{
            .context = undefined,
            .vtable = &testing_terminal_factory_vtable,
        },
    };
}

fn testingConnect(_: *anyopaque, _: std.mem.Allocator, _: ssh.ConnectOptions) ssh.Error!ssh.Client {
    return ssh.Error.ConnectionFailed;
}

fn testingCreateTerminal(_: *anyopaque, _: std.mem.Allocator, _: terminal.Size) terminal.Error!terminal.Emulator {
    return terminal.Error.InitFailed;
}

const testing_connector_vtable: ssh.Connector.VTable = .{
    .connect = testingConnect,
};

const testing_terminal_factory_vtable: ssh_session.TerminalFactory.VTable = .{
    .create = testingCreateTerminal,
};
