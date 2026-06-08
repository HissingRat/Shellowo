const std = @import("std");
const profile = @import("../core/profile.zig");
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
profiles: profile_repository.MemoryProfileRepository,
known_hosts: known_hosts_store.KnownHosts,
sessions: session_registry.MockSessionRegistry,
ssh_backend: libssh2_backend.Backend,
terminal_backend: libvterm_backend.Backend,
transfers: std.ArrayList(transfer.TransferTask) = .empty,
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
    var app = App{
        .allocator = allocator,
        .profiles = profile_repository.MemoryProfileRepository.init(allocator),
        .known_hosts = known_hosts_store.KnownHosts.init(allocator),
        .sessions = session_registry.MockSessionRegistry.init(allocator),
        .ssh_backend = .{ .allocator = allocator },
        .terminal_backend = .{ .allocator = allocator },
    };
    app.known_hosts.trust_missing = true;
    app.draft.reset(.ssh);
    try app.profiles.seedDefaults();
    app.selectFirstProfile();
    try app.seedTransfers();
    return app;
}

pub fn initPersistent(allocator: std.mem.Allocator, io: std.Io) !App {
    var app = App{
        .allocator = allocator,
        .io = io,
        .profiles = profile_repository.MemoryProfileRepository.init(allocator),
        .known_hosts = known_hosts_store.KnownHosts.init(allocator),
        .sessions = session_registry.MockSessionRegistry.init(allocator),
        .ssh_backend = .{ .allocator = allocator },
        .terminal_backend = .{ .allocator = allocator },
    };
    app.known_hosts.trust_missing = true;
    app.draft.reset(.ssh);
    try app.profiles.loadFromDisk(io, profiles_path);
    try app.known_hosts.loadFromDisk(io, known_hosts_path);
    if (app.profiles.items().len == 0) {
        try app.profiles.seedDefaults();
        try app.profiles.saveToDisk(io, profiles_path);
    }
    app.selectFirstProfile();
    try app.seedTransfers();
    return app;
}

pub fn deinit(self: *App) void {
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
    self.theme_mode = switch (self.theme_mode) {
        .dark => .light,
        .light => .dark,
    };
}

pub fn beginFrame(self: *App) void {
    self.frame_index +%= 1;
    self.sessions.pollWorkers();
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

fn seedTransfers(self: *App) !void {
    try self.transfers.append(self.allocator, .{
        .id = 1,
        .title = try self.allocator.dupe(u8, "No active transfers"),
        .direction = .download,
        .status = .pending,
        .progress = 0,
    });
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
        .host_key_verifier = self.known_hosts.verifier(),
        .host_key_policy = .trust_on_first_use,
    };
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
