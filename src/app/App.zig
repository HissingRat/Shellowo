const std = @import("std");
const app_config = @import("config.zig");
const native_event = @import("native_event.zig");
const profile = @import("../core/profile.zig");
const remote_file = @import("../core/remote_file.zig");
const transfer = @import("../core/transfer.zig");
const libssh2_backend = @import("../protocols/libssh2_backend.zig");
const ssh = @import("../protocols/ssh.zig");
const profile_repository = @import("../services/profile_repository.zig");
const session_registry = @import("../services/session_registry.zig");
const ssh_session = @import("../services/ssh_session.zig");
const known_hosts_store = @import("../security/known_hosts.zig");
const libvterm_backend = @import("../terminal/libvterm_backend.zig");
const terminal = @import("../terminal/terminal.zig");
const ui_theme = @import("../ui/theme.zig");

const App = @This();

const GroupExpansion = struct {
    name: []const u8,
    expanded: bool,
};

allocator: std.mem.Allocator,
io: ?std.Io = null,
config: app_config.Config,
profiles: profile_repository.MemoryProfileRepository,
known_hosts: known_hosts_store.KnownHosts,
sessions: session_registry.MockSessionRegistry,
ssh_backend: libssh2_backend.Backend,
terminal_backend: libvterm_backend.Backend,
transfers: std.ArrayList(transfer.TransferTask) = .empty,
native_events: std.ArrayList(native_event.NativeEvent) = .empty,
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

const profiles_path = "data/profiles.json";
const known_hosts_path = "data/known_hosts.json";

pub fn initMemory(allocator: std.mem.Allocator) !App {
    var config = try app_config.Config.load(allocator, null);
    errdefer config.deinit();
    var app = App{
        .allocator = allocator,
        .config = config,
        .profiles = profile_repository.MemoryProfileRepository.init(allocator),
        .known_hosts = known_hosts_store.KnownHosts.init(allocator),
        .sessions = session_registry.MockSessionRegistry.init(allocator),
        .ssh_backend = .{ .allocator = allocator },
        .terminal_backend = .{ .allocator = allocator },
    };
    app.theme_mode = app.config.theme_mode;
    app.known_hosts.trust_missing = true;
    app.draft.reset(.ssh);
    try app.profiles.seedDefaults();
    app.selectFirstProfile();
    return app;
}

pub fn initPersistent(allocator: std.mem.Allocator, io: std.Io) !App {
    var config = try app_config.Config.load(allocator, io);
    errdefer config.deinit();
    var app = App{
        .allocator = allocator,
        .io = io,
        .config = config,
        .profiles = profile_repository.MemoryProfileRepository.init(allocator),
        .known_hosts = known_hosts_store.KnownHosts.init(allocator),
        .sessions = session_registry.MockSessionRegistry.init(allocator),
        .ssh_backend = .{ .allocator = allocator },
        .terminal_backend = .{ .allocator = allocator },
    };
    app.theme_mode = app.config.theme_mode;
    app.known_hosts.trust_missing = true;
    app.draft.reset(.ssh);
    try app.profiles.loadFromDisk(io, profiles_path);
    try app.known_hosts.loadFromDisk(io, known_hosts_path);
    if (app.profiles.items().len == 0) {
        try app.profiles.seedDefaults();
        try app.profiles.saveToDisk(io, profiles_path);
    }
    app.selectFirstProfile();
    return app;
}

pub fn deinit(self: *App) void {
    self.config.theme_mode = self.theme_mode;
    self.persistConfig();
    for (self.group_expansions.items) |entry| {
        self.allocator.free(entry.name);
    }
    self.group_expansions.deinit(self.allocator);
    self.sessions.deinit();
    self.persistKnownHosts();
    self.profiles.deinit();
    self.known_hosts.deinit();
    for (self.transfers.items) |task| {
        self.allocator.free(task.title);
    }
    self.transfers.deinit(self.allocator);
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
    self.selected_profile_id = id;
    if (self.profiles.get(id)) |item| {
        self.draft.load(item.*);
        self.message = "Profile selected";
    }
}

pub fn newProfile(self: *App, session_type: profile.SessionType) void {
    self.selected_profile_id = null;
    self.draft.reset(session_type);
    self.show_config = true;
    self.message = "New profile";
}

pub fn editProfile(self: *App, id: u64) void {
    self.selectProfile(id);
    self.show_config = true;
}

pub fn cancelConfig(self: *App) void {
    if (self.selected_profile_id) |id| {
        if (self.profiles.get(id)) |item| self.draft.load(item.*);
    } else {
        self.draft.reset(.ssh);
    }
    self.show_config = false;
    self.message = "Home";
}

pub fn goHome(self: *App) void {
    self.sessions.active_tab_id = null;
    self.message = "Home";
}

pub fn toggleTheme(self: *App) void {
    self.setThemeMode(switch (self.theme_mode) {
        .dark => .light,
        .light => .dark,
    });
}

pub fn setThemeMode(self: *App, mode: ui_theme.ThemeMode) void {
    self.theme_mode = mode;
    self.config.theme_mode = self.theme_mode;
    self.persistConfig();
}

pub fn setDownloadPath(self: *App, path: []const u8) void {
    if (path.len == 0) return;
    const owned = self.allocator.dupe(u8, path) catch {
        self.message = "Could not update download path";
        return;
    };
    self.allocator.free(self.config.download_path);
    self.config.download_path = owned;
    self.persistConfig();
}

pub fn beginFrame(self: *App) void {
    self.frame_index +%= 1;
    self.sessions.pollWorkers();
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
    self.draft.reset(.ssh);
    self.show_config = false;
    self.message = "Profile deleted";
}

pub fn configVisible(self: *const App) bool {
    return self.show_config;
}

pub fn connectionSearchText(self: *const App) []const u8 {
    return profile.textFromBuffer(&self.connection_search);
}

pub fn ensureGroupDefaults(self: *App, visible_profile_capacity: usize) void {
    if (self.group_defaults_initialized) return;
    self.group_defaults_initialized = true;

    const expand_default = self.profiles.items().len <= visible_profile_capacity;
    for (self.profiles.items()) |item| {
        const group = normalizedGroup(item.base().group);
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
    const item = self.profiles.get(id) orelse {
        self.message = "Profile not found";
        return;
    };

    switch (item.*) {
        .ssh => {
            _ = self.sessions.openSshWorkerTab(item.*, self.sshRuntimeOptions()) catch {
                self.message = "Could not start SSH session";
                return;
            };
            self.message = "SSH session starting";
        },
        .ftp => {
            _ = self.sessions.openMockTab(item.*) catch {
                self.message = "Could not open mock tab";
                return;
            };
            self.message = "FTP session opened";
        },
    }
}

pub fn openSelectedProfile(self: *App) void {
    const id = self.selected_profile_id orelse {
        self.message = "No profile selected";
        return;
    };
    self.openProfile(id);
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

pub fn sendTerminalBytes(self: *App, tab_id: u64, bytes: []const u8) void {
    if (bytes.len == 0) return;
    self.sessions.sendSshInput(tab_id, bytes) catch {
        self.message = "Could not send terminal input";
        return;
    };
}

pub fn sendTerminalMouse(self: *App, tab_id: u64, event: terminal.MouseEvent) void {
    self.sessions.sendSshMouse(tab_id, event) catch {
        self.message = "Could not send terminal mouse event";
        return;
    };
}

pub fn resizeTerminal(self: *App, tab_id: u64, size: ssh.PtySize) void {
    self.sessions.resizeSshTerminal(tab_id, size) catch {
        self.message = "Could not resize terminal";
        return;
    };
}

pub fn clearTerminalScrollback(self: *App, tab_id: u64) void {
    self.sessions.clearSshScrollback(tab_id) catch {
        self.message = "Could not clear terminal scrollback";
        return;
    };
}

pub fn createTerminalSlot(self: *App, tab_id: u64) void {
    _ = self.sessions.createTerminalSlot(tab_id) catch {
        self.message = "Could not create terminal";
        return;
    };
    self.message = "Terminal created";
}

pub fn activateTerminalSlot(self: *App, tab_id: u64, slot_id: u64) void {
    if (!self.sessions.activateTerminalSlot(tab_id, slot_id)) {
        self.message = "Terminal not found";
        return;
    }
    self.message = "Terminal selected";
}

pub fn closeTerminalSlot(self: *App, tab_id: u64, slot_id: u64) void {
    if (!self.sessions.closeTerminalSlot(tab_id, slot_id)) {
        self.message = "Terminal not found";
        return;
    }
    self.message = "Terminal closed";
}

pub fn reconnectTab(self: *App, tab_id: u64) void {
    const tab = self.sessions.tabById(tab_id) orelse {
        self.message = "Workspace tab not found";
        return;
    };
    self.openProfile(tab.profile_id);
}

pub fn filePanelSnapshot(self: *App, tab_id: u64, local_buffer: []remote_file.RemoteFileEntry, remote_buffer: []remote_file.RemoteFileEntry) remote_file.FilePanelSnapshot {
    return self.sessions.filePanelSnapshot(tab_id, local_buffer, remote_buffer);
}

pub fn handleFilePanelIntent(self: *App, tab_id: u64, intent: remote_file.FilePanelIntent) void {
    var queued_intent = intent;
    const transfer_id = self.recordFileTransfer(&queued_intent) catch {
        self.message = "Could not create transfer task";
        return;
    };
    self.sessions.handleFilePanelIntent(tab_id, queued_intent) catch {
        if (transfer_id) |id| self.removeTransfer(id);
        self.message = "File action is not available yet";
        return;
    };
    self.message = fileIntentMessage(intent);
}

pub fn cancelTransfer(self: *App, transfer_id: u64) void {
    self.sessions.cancelTransfer(transfer_id);
    self.removeTransfer(transfer_id);
    self.message = "Transfer canceled";
}

pub fn dismissTransfer(self: *App, transfer_id: u64) void {
    self.removeTransfer(transfer_id);
}

fn syncTransferProgress(self: *App) void {
    var buffer: [128]transfer.TransferProgress = undefined;
    const updates = self.sessions.transferProgress(&buffer);
    for (updates) |update| {
        const idx = self.transferIndex(update.id) orelse continue;
        if (update.status == .completed or update.status == .canceled) {
            self.removeTransferAt(idx);
            continue;
        }
        self.transfers.items[idx].status = update.status;
        self.transfers.items[idx].progress = update.progress;
    }
}

fn recordFileTransfer(self: *App, intent: *remote_file.FilePanelIntent) !?u64 {
    switch (intent.*) {
        .upload => |*upload| {
            const id = try self.appendNamedTransfer(.upload, upload.name);
            upload.transfer_id = id;
            return id;
        },
        .upload_many => |*upload_many| {
            if (upload_many.entries.len == 1) {
                const id = try self.appendNamedTransfer(.upload, upload_many.entries[0].name);
                upload_many.transfer_id = id;
                return id;
            } else {
                var title_buf: [64]u8 = undefined;
                const title = try std.fmt.bufPrint(&title_buf, "Upload {d} items", .{upload_many.entries.len});
                const id = try self.appendTransferTitle(.upload, title);
                upload_many.transfer_id = id;
                return id;
            }
        },
        .download => |*download| {
            const id = try self.appendNamedTransfer(.download, download.name);
            download.transfer_id = id;
            return id;
        },
        .download_many => |*download_many| {
            if (download_many.entries.len == 1) {
                const id = try self.appendNamedTransfer(.download, download_many.entries[0].name);
                download_many.transfer_id = id;
                return id;
            } else {
                var title_buf: [64]u8 = undefined;
                const title = try std.fmt.bufPrint(&title_buf, "Download {d} items", .{download_many.entries.len});
                const id = try self.appendTransferTitle(.download, title);
                download_many.transfer_id = id;
                return id;
            }
        },
        else => return null,
    }
}

fn appendNamedTransfer(self: *App, direction: transfer.TransferDirection, name: []const u8) !u64 {
    const action = switch (direction) {
        .download => "Download",
        .upload => "Upload",
    };
    const title = try std.fmt.allocPrint(self.allocator, "{s} '{s}'", .{ action, name });
    return self.appendOwnedTransferTitle(direction, title);
}

fn appendTransferTitle(self: *App, direction: transfer.TransferDirection, title_text: []const u8) !u64 {
    const title = try self.allocator.dupe(u8, title_text);
    return self.appendOwnedTransferTitle(direction, title);
}

fn appendOwnedTransferTitle(self: *App, direction: transfer.TransferDirection, title: []const u8) !u64 {
    errdefer self.allocator.free(title);
    const id = self.next_transfer_id;
    try self.transfers.append(self.allocator, .{
        .id = id,
        .title = title,
        .direction = direction,
        .status = .running,
        .progress = 0,
    });
    self.next_transfer_id += 1;
    return id;
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
    self.allocator.free(self.transfers.items[idx].title);
    _ = self.transfers.orderedRemove(idx);
}

fn selectFirstProfile(self: *App) void {
    if (self.profiles.items().len == 0) return;
    self.selected_profile_id = self.profiles.items()[0].base().id;
    self.draft.load(self.profiles.items()[0]);
}

fn persistProfiles(self: *App) void {
    const io = self.io orelse return;
    self.profiles.saveToDisk(io, profiles_path) catch {
        self.message = "Profile saved in memory, but disk write failed";
    };
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
        .connector = self.ssh_backend.connector(),
        .terminal_factory = terminalFactory(&self.terminal_backend),
        .io = self.io,
        .host_key_verifier = self.known_hosts.verifier(),
        .host_key_policy = .trust_on_first_use,
        .download_path = self.config.download_path,
    };
}

fn terminalFactory(backend: *libvterm_backend.Backend) ssh_session.TerminalFactory {
    return .{
        .context = backend,
        .vtable = &terminal_factory_vtable,
    };
}

fn fileIntentMessage(intent: remote_file.FilePanelIntent) []const u8 {
    return switch (intent) {
        .select => "File selected",
        .toggle_tree => "Toggling folder",
        .refresh => "Refreshing files",
        .go_parent => "Opening parent folder",
        .open => "Opening folder",
        .create_file => "Creating file",
        .create_directory => "Creating folder",
        .rename => "Renaming file",
        .delete => "Deleting file",
        .upload, .upload_many => "Uploading file",
        .download, .download_many => "Downloading file",
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
    var app = try App.initMemory(std.testing.allocator);
    defer app.deinit();

    try std.testing.expect(app.profiles.items().len >= 2);
}
