const std = @import("std");
const profile = @import("../core/profile.zig");
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
