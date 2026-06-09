const std = @import("std");
const profile = @import("../core/profile.zig");
const remote_file = @import("../core/remote_file.zig");
const ssh = @import("../protocols/ssh.zig");
const status_panel = @import("../core/status_panel.zig");
const terminal_slot = @import("../core/terminal_slot.zig");
const workspace = @import("../core/workspace.zig");
const terminal = @import("../terminal/terminal.zig");
const ssh_session = @import("ssh_session.zig");
const ssh_workspace_worker = @import("ssh_workspace_worker.zig");

const SshRuntimeSlot = struct {
    tab_id: u64,
    session: ssh_session.SshSession,
};

const SshWorkspaceRuntimeSlot = struct {
    tab_id: u64,
    worker: *ssh_workspace_worker.SshWorkspaceWorker,
};

const ActiveTerminalSlot = struct {
    tab_id: u64,
    slot_id: terminal_slot.TerminalSlotId,
};

pub const MockSessionRegistry = struct {
    allocator: std.mem.Allocator,
    tabs: std.ArrayList(workspace.WorkspaceTab) = .empty,
    ssh_sessions: std.ArrayList(SshRuntimeSlot) = .empty,
    ssh_workspaces: std.ArrayList(SshWorkspaceRuntimeSlot) = .empty,
    active_terminal_slots: std.ArrayList(ActiveTerminalSlot) = .empty,
    next_id: u64 = 1,
    active_tab_id: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator) MockSessionRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MockSessionRegistry) void {
        for (self.ssh_workspaces.items) |slot| {
            slot.worker.destroy();
        }
        self.ssh_workspaces.deinit(self.allocator);
        self.active_terminal_slots.deinit(self.allocator);
        for (self.ssh_sessions.items) |*slot| {
            slot.session.deinit();
        }
        self.ssh_sessions.deinit(self.allocator);
        for (self.tabs.items) |tab| {
            self.allocator.free(tab.title);
        }
        self.tabs.deinit(self.allocator);
    }

    pub fn openMockTab(self: *MockSessionRegistry, connection: profile.ConnectionProfile) !u64 {
        if (self.findByProfileId(connection.base().id)) |existing| {
            self.active_tab_id = existing;
            return existing;
        }

        return self.createTab(connection, .connected);
    }

    pub fn openSshRuntimeTab(self: *MockSessionRegistry, connection: profile.ConnectionProfile, options: ssh_session.Options) !u64 {
        if (connection != .ssh) return ssh_session.Error.UnsupportedProfile;
        if (self.findByProfileId(connection.base().id)) |existing| {
            if (self.reuseExistingTab(existing)) return existing;
            self.closeTab(existing);
        }

        const id = try self.createTab(connection, .connecting);
        errdefer self.closeTab(id);

        var session = ssh_session.SshSession.init(self.allocator);
        session.open(connection, options) catch |err| {
            self.setTabStatus(id, .failed);
            session.deinit();
            return err;
        };

        try self.ssh_sessions.append(self.allocator, .{
            .tab_id = id,
            .session = session,
        });
        self.setTabStatus(id, .connected);
        return id;
    }

    pub fn openSshWorkerTab(self: *MockSessionRegistry, connection: profile.ConnectionProfile, options: ssh_session.Options) !u64 {
        if (connection != .ssh) return ssh_session.Error.UnsupportedProfile;
        if (self.findByProfileId(connection.base().id)) |existing| {
            if (self.reuseExistingTab(existing)) return existing;
            self.closeTab(existing);
        }

        const id = try self.createTab(connection, .connecting);
        errdefer self.closeTab(id);

        const worker = try ssh_workspace_worker.SshWorkspaceWorker.create(self.allocator, connection, options);
        errdefer worker.destroy();
        try worker.start();
        try self.ssh_workspaces.append(self.allocator, .{ .tab_id = id, .worker = worker });
        if (worker.firstVisibleSlotId()) |slot_id| {
            try self.setActiveTerminalSlot(id, slot_id);
        }
        return id;
    }

    pub fn pollWorkers(self: *MockSessionRegistry) void {
        for (self.tabs.items) |tab| {
            if (tab.session_type != .ssh) continue;
            const worker = self.sshWorkspace(tab.id) orelse {
                self.setTabStatus(tab.id, .closed);
                continue;
            };
            const status: workspace.TabStatus = switch (worker.state()) {
                .idle, .starting => .connecting,
                .connected => .connected,
                .stopping, .stopped => .closed,
                .failed => .failed,
            };
            self.setTabStatus(tab.id, status);
        }
    }

    pub fn activate(self: *MockSessionRegistry, id: u64) void {
        for (self.tabs.items) |tab| {
            if (tab.id == id) {
                self.active_tab_id = id;
                return;
            }
        }
    }

    pub fn closeTab(self: *MockSessionRegistry, id: u64) void {
        if (self.sshWorkspaceIndex(id)) |worker_idx| {
            self.ssh_workspaces.items[worker_idx].worker.destroy();
            _ = self.ssh_workspaces.orderedRemove(worker_idx);
        }

        if (self.activeTerminalSlotIndex(id)) |active_idx| {
            _ = self.active_terminal_slots.orderedRemove(active_idx);
        }

        if (self.sshSessionIndex(id)) |runtime_idx| {
            self.ssh_sessions.items[runtime_idx].session.deinit();
            _ = self.ssh_sessions.orderedRemove(runtime_idx);
        }

        for (self.tabs.items, 0..) |tab, i| {
            if (tab.id == id) {
                self.allocator.free(tab.title);
                _ = self.tabs.orderedRemove(i);
                if (self.active_tab_id == id) {
                    self.active_tab_id = if (self.tabs.items.len > 0) self.tabs.items[@min(i, self.tabs.items.len - 1)].id else null;
                }
                return;
            }
        }
    }

    pub fn sshSession(self: *MockSessionRegistry, tab_id: u64) ?*ssh_session.SshSession {
        const idx = self.sshSessionIndex(tab_id) orelse return null;
        return &self.ssh_sessions.items[idx].session;
    }

    pub fn sshWorkspace(self: *MockSessionRegistry, tab_id: u64) ?*ssh_workspace_worker.SshWorkspaceWorker {
        const idx = self.sshWorkspaceIndex(tab_id) orelse return null;
        return self.ssh_workspaces.items[idx].worker;
    }

    pub fn copySshSnapshot(self: *MockSessionRegistry, allocator: std.mem.Allocator, tab_id: u64) !?terminal.Snapshot {
        const worker = self.sshWorkspace(tab_id) orelse return null;
        const slot_id = self.activeTerminalSlotId(tab_id) orelse return null;
        return worker.copySnapshot(allocator, slot_id);
    }

    pub fn statusPanelSnapshot(self: *MockSessionRegistry, tab_id: u64) status_panel.StatusPanelSnapshot {
        const worker = self.sshWorkspace(tab_id) orelse return status_panel.unavailable();
        return worker.statusPanelSnapshot();
    }

    pub fn filePanelSnapshot(self: *MockSessionRegistry, tab_id: u64, local_buffer: []remote_file.RemoteFileEntry, remote_buffer: []remote_file.RemoteFileEntry) remote_file.FilePanelSnapshot {
        const tab = self.tabById(tab_id) orelse return .{};
        if (tab.session_type == .ssh) {
            if (self.sshWorkspace(tab_id)) |worker| {
                return .{
                    .local = worker.fileTreeSnapshot(local_buffer),
                    .remote = worker.filePanelSnapshot(remote_buffer),
                };
            }
        }
        const remote = switch (tab.session_type) {
            .ssh => mockSftpPane(tab.status),
            .ftp => mockFtpPane(tab.status),
        };
        const local = remoteTreePane(remote, local_buffer);
        return .{ .local = local, .remote = remote };
    }

    pub fn handleFilePanelIntent(self: *MockSessionRegistry, tab_id: u64, intent: remote_file.FilePanelIntent) !void {
        if (self.tabById(tab_id) == null) return ssh_session.Error.ChannelClosed;
        if (self.sshWorkspace(tab_id)) |worker| {
            try worker.queueFileIntent(intent);
        }
    }

    pub fn terminalSlots(self: *MockSessionRegistry, tab_id: u64, buffer: []terminal_slot.TerminalSlotSummary) []terminal_slot.TerminalSlotSummary {
        if (buffer.len == 0) return buffer[0..0];
        const tab = self.tabById(tab_id) orelse return buffer[0..0];
        const worker = self.sshWorkspace(tab_id) orelse return buffer[0..0];
        if (tab.session_type != .ssh) return buffer[0..0];
        return worker.slotSummaries(buffer);
    }

    pub fn activeTerminalSlotId(self: *MockSessionRegistry, tab_id: u64) ?terminal_slot.TerminalSlotId {
        if (self.activeTerminalSlotIndex(tab_id)) |idx| {
            const slot_id = self.active_terminal_slots.items[idx].slot_id;
            if (self.sshWorkspace(tab_id)) |worker| {
                if (worker.hasSlot(slot_id)) return slot_id;
            }
        }
        const worker = self.sshWorkspace(tab_id) orelse return null;
        return worker.firstVisibleSlotId();
    }

    pub fn activateTerminalSlot(self: *MockSessionRegistry, tab_id: u64, slot_id: terminal_slot.TerminalSlotId) bool {
        const worker = self.sshWorkspace(tab_id) orelse return false;
        if (!worker.hasSlot(slot_id)) return false;
        self.setActiveTerminalSlot(tab_id, slot_id) catch return false;
        return true;
    }

    pub fn createTerminalSlot(self: *MockSessionRegistry, tab_id: u64) !terminal_slot.TerminalSlotId {
        const tab = self.tabById(tab_id) orelse return ssh_session.Error.ChannelClosed;
        if (tab.session_type != .ssh) return ssh_session.Error.UnsupportedProfile;
        const worker = self.sshWorkspace(tab_id) orelse return ssh_session.Error.ChannelClosed;
        const slot_id = try worker.createSlot();
        try self.setActiveTerminalSlot(tab_id, slot_id);
        return slot_id;
    }

    pub fn closeTerminalSlot(self: *MockSessionRegistry, tab_id: u64, slot_id: terminal_slot.TerminalSlotId) bool {
        const worker = self.sshWorkspace(tab_id) orelse return false;
        if (!worker.hasSlot(slot_id)) return false;
        if (worker.visibleSlotCount() <= 1) {
            self.closeTab(tab_id);
            return true;
        }

        const was_active = if (self.activeTerminalSlotId(tab_id)) |active_id| active_id == slot_id else false;
        _ = worker.closeSlot(slot_id);

        if (was_active) {
            if (worker.firstVisibleSlotId()) |next_id| {
                self.setActiveTerminalSlot(tab_id, next_id) catch return false;
            }
        }
        return true;
    }

    pub fn sendSshInput(self: *MockSessionRegistry, tab_id: u64, bytes: []const u8) !void {
        const worker = self.sshWorkspace(tab_id) orelse return ssh_session.Error.ChannelClosed;
        const slot_id = self.activeTerminalSlotId(tab_id) orelse return ssh_session.Error.ChannelClosed;
        try worker.queueInput(slot_id, bytes);
    }

    pub fn sendSshMouse(self: *MockSessionRegistry, tab_id: u64, event: terminal.MouseEvent) !void {
        const worker = self.sshWorkspace(tab_id) orelse return ssh_session.Error.ChannelClosed;
        const slot_id = self.activeTerminalSlotId(tab_id) orelse return ssh_session.Error.ChannelClosed;
        try worker.queueMouse(slot_id, event);
    }

    pub fn resizeSshTerminal(self: *MockSessionRegistry, tab_id: u64, size: ssh.PtySize) !void {
        const worker = self.sshWorkspace(tab_id) orelse return ssh_session.Error.ChannelClosed;
        const slot_id = self.activeTerminalSlotId(tab_id) orelse return ssh_session.Error.ChannelClosed;
        try worker.queueResize(slot_id, size);
    }

    pub fn clearSshScrollback(self: *MockSessionRegistry, tab_id: u64) !void {
        const worker = self.sshWorkspace(tab_id) orelse return ssh_session.Error.ChannelClosed;
        const slot_id = self.activeTerminalSlotId(tab_id) orelse return ssh_session.Error.ChannelClosed;
        try worker.queueClearScrollback(slot_id);
    }

    pub fn sshFailure(self: *MockSessionRegistry, tab_id: u64) ?ssh_session.Error {
        const worker = self.sshWorkspace(tab_id) orelse return null;
        return worker.last_error;
    }

    pub fn activeTab(self: *MockSessionRegistry) ?workspace.WorkspaceTab {
        const id = self.active_tab_id orelse return null;
        return self.tabById(id);
    }

    pub fn tabById(self: *MockSessionRegistry, id: u64) ?workspace.WorkspaceTab {
        for (self.tabs.items) |tab| {
            if (tab.id == id) return tab;
        }
        return null;
    }

    pub fn findByProfileId(self: *MockSessionRegistry, profile_id: u64) ?u64 {
        for (self.tabs.items) |tab| {
            if (tab.profile_id == profile_id) return tab.id;
        }
        return null;
    }

    fn createTab(self: *MockSessionRegistry, connection: profile.ConnectionProfile, status: workspace.TabStatus) !u64 {
        const id = self.next_id;
        self.next_id += 1;

        const b = connection.base();
        const title = try self.allocator.dupe(u8, b.name);
        errdefer self.allocator.free(title);

        try self.tabs.append(self.allocator, .{
            .id = id,
            .profile_id = b.id,
            .session_type = connection.sessionType(),
            .title = title,
            .layout = workspace.layoutFor(connection.sessionType()),
            .status = status,
        });
        self.active_tab_id = id;
        return id;
    }

    fn setActiveTerminalSlot(self: *MockSessionRegistry, tab_id: u64, slot_id: terminal_slot.TerminalSlotId) !void {
        if (self.activeTerminalSlotIndex(tab_id)) |idx| {
            self.active_terminal_slots.items[idx].slot_id = slot_id;
            return;
        }
        try self.active_terminal_slots.append(self.allocator, .{ .tab_id = tab_id, .slot_id = slot_id });
    }

    fn setTabStatus(self: *MockSessionRegistry, id: u64, status: workspace.TabStatus) void {
        for (self.tabs.items) |*tab| {
            if (tab.id == id) {
                tab.status = status;
                return;
            }
        }
    }

    fn reuseExistingTab(self: *MockSessionRegistry, id: u64) bool {
        for (self.tabs.items) |tab| {
            if (tab.id != id) continue;
            if (tab.status == .failed or tab.status == .closed) return false;
            self.active_tab_id = id;
            return true;
        }
        return false;
    }

    fn sshSessionIndex(self: *MockSessionRegistry, tab_id: u64) ?usize {
        for (self.ssh_sessions.items, 0..) |slot, idx| {
            if (slot.tab_id == tab_id) return idx;
        }
        return null;
    }

    fn sshWorkspaceIndex(self: *MockSessionRegistry, tab_id: u64) ?usize {
        for (self.ssh_workspaces.items, 0..) |slot, idx| {
            if (slot.tab_id == tab_id) return idx;
        }
        return null;
    }

    fn activeTerminalSlotIndex(self: *MockSessionRegistry, tab_id: u64) ?usize {
        for (self.active_terminal_slots.items, 0..) |active, idx| {
            if (active.tab_id == tab_id) return idx;
        }
        return null;
    }
};

const mock_sftp_entries = [_]remote_file.RemoteFileEntry{
    .{ .name = "home", .kind = .directory, .permissions = 0o755 },
    .{ .name = "etc", .kind = .directory, .permissions = 0o755 },
    .{ .name = "var", .kind = .directory, .permissions = 0o755 },
    .{ .name = "motd.dynamic", .kind = .file, .size = 1024, .permissions = 0o644 },
};

fn mockSftpPane(status: workspace.TabStatus) remote_file.FilePaneSnapshot {
    if (status == .connecting) {
        return .{
            .location = .sftp,
            .path = "/",
            .state = .loading,
            .capabilities = .{ .can_refresh = true },
        };
    }
    if (status == .failed or status == .closed) {
        return .{
            .location = .sftp,
            .path = "/",
            .state = .failed,
            .error_summary = "SFTP is unavailable until the SSH workspace reconnects.",
        };
    }
    return .{
        .location = .sftp,
        .path = "/",
        .state = .ready,
        .entries = &mock_sftp_entries,
        .capabilities = .{
            .can_refresh = true,
            .can_go_parent = true,
            .can_create_directory = true,
            .can_rename = true,
            .can_delete = true,
            .can_upload = true,
            .can_download = true,
        },
    };
}

fn mockFtpPane(status: workspace.TabStatus) remote_file.FilePaneSnapshot {
    _ = status;
    return .{
        .location = .ftp,
        .path = "/",
        .state = .unavailable,
        .error_summary = "FTP file runtime is planned after SFTP MVP.",
        .capabilities = .{},
    };
}

fn remoteTreePane(remote: remote_file.FilePaneSnapshot, buffer: []remote_file.RemoteFileEntry) remote_file.FilePaneSnapshot {
    var count: usize = 0;
    if (buffer.len > 0) {
        buffer[count] = .{
            .name = "/",
            .kind = .directory,
            .full_path = "/",
            .depth = 0,
            .expanded = true,
        };
        count += 1;
    }

    count = appendPathAncestors(remote.path, buffer, count);
    const child_depth: u8 = @intCast(pathDepth(remote.path) + 1);
    for (remote.entries) |entry| {
        if (count >= buffer.len) break;
        if (!entry.isDirectory() or std.mem.eql(u8, entry.name, "..")) continue;
        buffer[count] = .{
            .name = entry.name,
            .kind = .directory,
            .full_path = entry.full_path,
            .depth = child_depth,
            .expanded = false,
        };
        count += 1;
    }

    return .{
        .location = remote.location,
        .path = remote.path,
        .state = remote.state,
        .entries = buffer[0..count],
        .selected_name = remote.selected_name,
        .error_summary = remote.error_summary,
        .capabilities = remote.capabilities,
    };
}

fn appendPathAncestors(path: []const u8, buffer: []remote_file.RemoteFileEntry, start: usize) usize {
    if (path.len <= 1) return start;
    var count = start;
    var depth: u8 = 1;
    var i: usize = 1;
    while (i < path.len and count < buffer.len) {
        while (i < path.len and path[i] == '/') i += 1;
        if (i >= path.len) break;
        const name_start = i;
        while (i < path.len and path[i] != '/') i += 1;
        const name = path[name_start..i];
        buffer[count] = .{
            .name = name,
            .kind = .directory,
            .full_path = path[0..i],
            .depth = depth,
            .expanded = true,
        };
        count += 1;
        depth += 1;
    }
    return count;
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
