const std = @import("std");
const profile = @import("../../core/profile.zig");
const remote_file = @import("../../core/remote_file.zig");
const ssh = @import("../../contracts/ssh.zig");
const status_panel = @import("../../core/status_panel.zig");
const terminal_slot = @import("../../core/terminal_slot.zig");
const transfer = @import("../../core/transfer.zig");
const workspace = @import("../../core/workspace.zig");
const terminal = @import("../../contracts/terminal_emulator.zig");
const ssh_session = @import("ssh_session.zig");
const ssh_workspace_worker = @import("ssh_workspace_worker.zig");
const transfer_scheduler = @import("../transfers/scheduler.zig");

const SshWorkspaceRuntimeSlot = struct {
    tab_id: u64,
    worker: *ssh_workspace_worker.SshWorkspaceWorker,
    presented_file_notice_generation: u64 = 0,
};

const RetiredSshWorkspaceRuntimeSlot = struct {
    tab_id: u64,
    worker: *ssh_workspace_worker.SshWorkspaceWorker,
};

const ActiveTerminalSlot = struct {
    tab_id: u64,
    slot_id: terminal_slot.TerminalSlotId,
};

const QueuedTransferIntent = struct {
    id: u64,
    tab_id: u64,
    intent: remote_file.FilePanelIntent,
};

pub const SessionRegistry = struct {
    allocator: std.mem.Allocator,
    tabs: std.ArrayList(workspace.WorkspaceTab) = .empty,
    ssh_workspaces: std.ArrayList(SshWorkspaceRuntimeSlot) = .empty,
    retired_ssh_workspaces: std.ArrayList(RetiredSshWorkspaceRuntimeSlot) = .empty,
    active_terminal_slots: std.ArrayList(ActiveTerminalSlot) = .empty,
    transfer_scheduler: transfer_scheduler.Scheduler = .{},
    queued_transfer_intents: std.ArrayList(QueuedTransferIntent) = .empty,
    transfer_updates: std.ArrayList(transfer.TransferProgress) = .empty,
    next_id: u64 = 1,
    active_tab_id: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator) SessionRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SessionRegistry) void {
        for (self.queued_transfer_intents.items) |record| {
            remote_file.freePanelIntent(self.allocator, record.intent);
        }
        self.queued_transfer_intents.deinit(self.allocator);
        self.transfer_updates.deinit(self.allocator);
        self.transfer_scheduler.deinit(self.allocator);
        for (self.ssh_workspaces.items) |slot| {
            slot.worker.destroy();
        }
        self.ssh_workspaces.deinit(self.allocator);
        for (self.retired_ssh_workspaces.items) |slot| {
            slot.worker.destroy();
        }
        self.retired_ssh_workspaces.deinit(self.allocator);
        self.active_terminal_slots.deinit(self.allocator);
        for (self.tabs.items) |tab| {
            self.allocator.free(tab.title);
        }
        self.tabs.deinit(self.allocator);
    }

    pub fn openSshWorkerTab(self: *SessionRegistry, connection: profile.ConnectionProfile, options: ssh_session.Options) !u64 {
        if (self.findByProfileId(connection.base.id)) |existing| {
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

    pub fn pollWorkers(self: *SessionRegistry) void {
        self.reapRetiredWorkspaces();
        for (self.tabs.items) |tab| {
            const worker = self.sshWorkspace(tab.id) orelse {
                self.setTabStatus(tab.id, .closed);
                continue;
            };
            const status: workspace.TabStatus = switch (worker.state()) {
                .idle, .starting => .connecting,
                .resolving => .resolving,
                .connecting => .connecting,
                .verifying_host_key => .verifying_host_key,
                .authenticating => .authenticating,
                .opening_shell => .opening_shell,
                .connected => .connected,
                .stopping, .stopped => .closed,
                .failed => .failed,
            };
            self.setTabStatus(tab.id, status);
        }
        self.dispatchTransfers();
    }

    pub fn activate(self: *SessionRegistry, id: u64) void {
        for (self.tabs.items) |tab| {
            if (tab.id == id) {
                self.active_tab_id = id;
                return;
            }
        }
    }

    pub fn closeTab(self: *SessionRegistry, id: u64) void {
        self.cancelPendingTransfersForTab(id);
        if (self.sshWorkspaceIndex(id)) |worker_idx| {
            const slot = self.ssh_workspaces.orderedRemove(worker_idx);
            slot.worker.requestRetire();
            self.retired_ssh_workspaces.append(self.allocator, .{
                .tab_id = id,
                .worker = slot.worker,
            }) catch {
                slot.worker.destroy();
                self.releaseRunningTransfersForTab(id);
            };
        } else {
            self.releaseRunningTransfersForTab(id);
        }

        if (self.activeTerminalSlotIndex(id)) |active_idx| {
            _ = self.active_terminal_slots.orderedRemove(active_idx);
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

    pub fn sshWorkspace(self: *SessionRegistry, tab_id: u64) ?*ssh_workspace_worker.SshWorkspaceWorker {
        const idx = self.sshWorkspaceIndex(tab_id) orelse return null;
        return self.ssh_workspaces.items[idx].worker;
    }

    pub fn copySshSnapshot(self: *SessionRegistry, allocator: std.mem.Allocator, tab_id: u64) !?terminal.Snapshot {
        const worker = self.sshWorkspace(tab_id) orelse return null;
        const slot_id = self.activeTerminalSlotId(tab_id) orelse return null;
        return worker.copySnapshot(allocator, slot_id);
    }

    pub fn sshSnapshotGeneration(self: *SessionRegistry, tab_id: u64, slot_id: u64) ?u64 {
        const worker = self.sshWorkspace(tab_id) orelse return null;
        return worker.snapshotGeneration(slot_id);
    }

    pub fn statusPanelSnapshot(self: *SessionRegistry, tab_id: u64) status_panel.StatusPanelSnapshot {
        const worker = self.sshWorkspace(tab_id) orelse return status_panel.unavailable();
        return worker.statusPanelSnapshot();
    }

    pub fn latencyProbeSnapshot(self: *SessionRegistry, tab_id: u64) ssh_workspace_worker.LatencyProbeSnapshot {
        const worker = self.sshWorkspace(tab_id) orelse return .{};
        return worker.latencyProbeSnapshot();
    }

    pub fn filePanelSnapshot(self: *SessionRegistry, tab_id: u64, tree_buffer: []remote_file.RemoteFileEntry, remote_buffer: []remote_file.RemoteFileEntry) remote_file.FilePanelSnapshot {
        _ = self.tabById(tab_id) orelse return .{};
        const idx = self.sshWorkspaceIndex(tab_id) orelse return .{};
        const slot = &self.ssh_workspaces.items[idx];
        const remote = slot.worker.filePanelSnapshot(remote_buffer);
        const toast_summary = consumeFileNotice(
            &slot.presented_file_notice_generation,
            remote.notice_generation,
            remote.error_summary,
        );
        return .{
            .tree = slot.worker.fileTreeSnapshot(tree_buffer),
            .remote = remote,
            .editor = slot.worker.fileEditorSnapshot(),
            .toast_summary = toast_summary,
        };
    }

    pub fn handleFilePanelIntent(self: *SessionRegistry, tab_id: u64, intent: remote_file.FilePanelIntent) !void {
        if (self.tabById(tab_id) == null) return ssh_session.Error.ChannelClosed;
        if (transferIntentId(intent)) |transfer_id| {
            const owned = try remote_file.clonePanelIntent(self.allocator, intent);
            errdefer remote_file.freePanelIntent(self.allocator, owned);
            try self.queued_transfer_intents.append(self.allocator, .{
                .id = transfer_id,
                .tab_id = tab_id,
                .intent = owned,
            });
            errdefer {
                const removed = self.queued_transfer_intents.pop().?;
                remote_file.freePanelIntent(self.allocator, removed.intent);
            }
            try self.transfer_scheduler.enqueue(self.allocator, .{
                .id = transfer_id,
                .session_id = tab_id,
            });
            self.dispatchTransfers();
            return;
        }
        if (self.sshWorkspace(tab_id)) |worker| {
            try worker.queueFileIntent(intent);
        }
    }

    pub fn transferProgress(self: *SessionRegistry, buffer: []transfer.TransferProgress) []transfer.TransferProgress {
        var count = self.drainTransferUpdates(buffer);
        for (self.ssh_workspaces.items) |slot| {
            if (count >= buffer.len) break;
            const written = slot.worker.transferProgress(buffer[count..]);
            for (written) |update| {
                if (isTerminalTransferStatus(update.status)) {
                    _ = self.transfer_scheduler.finish(update.id);
                }
            }
            count += written.len;
        }
        self.dispatchTransfers();
        return buffer[0..count];
    }

    pub fn cancelTransfer(self: *SessionRegistry, transfer_id: u64) void {
        if (self.transfer_scheduler.cancelPending(transfer_id)) {
            self.removeQueuedTransferIntent(transfer_id);
            self.emitTransferUpdate(transfer_id, .canceled);
            self.dispatchTransfers();
            return;
        }
        if (self.transfer_scheduler.runningSession(transfer_id)) |tab_id| {
            if (self.sshWorkspace(tab_id)) |worker| worker.requestCancelTransfer(transfer_id);
        }
    }

    pub fn terminalSlots(self: *SessionRegistry, tab_id: u64, buffer: []terminal_slot.TerminalSlotSummary) []terminal_slot.TerminalSlotSummary {
        if (buffer.len == 0) return buffer[0..0];
        _ = self.tabById(tab_id) orelse return buffer[0..0];
        const worker = self.sshWorkspace(tab_id) orelse return buffer[0..0];
        return worker.slotSummaries(buffer);
    }

    pub fn activeTerminalSlotId(self: *SessionRegistry, tab_id: u64) ?terminal_slot.TerminalSlotId {
        if (self.activeTerminalSlotIndex(tab_id)) |idx| {
            const slot_id = self.active_terminal_slots.items[idx].slot_id;
            if (self.sshWorkspace(tab_id)) |worker| {
                if (worker.hasSlot(slot_id)) return slot_id;
            }
        }
        const worker = self.sshWorkspace(tab_id) orelse return null;
        return worker.firstVisibleSlotId();
    }

    pub fn activateTerminalSlot(self: *SessionRegistry, tab_id: u64, slot_id: terminal_slot.TerminalSlotId) bool {
        const worker = self.sshWorkspace(tab_id) orelse return false;
        if (!worker.hasSlot(slot_id)) return false;
        self.setActiveTerminalSlot(tab_id, slot_id) catch return false;
        return true;
    }

    pub fn createTerminalSlot(self: *SessionRegistry, tab_id: u64) !terminal_slot.TerminalSlotId {
        _ = self.tabById(tab_id) orelse return ssh_session.Error.ChannelClosed;
        const worker = self.sshWorkspace(tab_id) orelse return ssh_session.Error.ChannelClosed;
        const slot_id = try worker.createSlot();
        try self.setActiveTerminalSlot(tab_id, slot_id);
        return slot_id;
    }

    pub fn closeTerminalSlot(self: *SessionRegistry, tab_id: u64, slot_id: terminal_slot.TerminalSlotId) bool {
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

    pub fn sendSshInput(self: *SessionRegistry, tab_id: u64, bytes: []const u8) !void {
        const worker = self.sshWorkspace(tab_id) orelse return ssh_session.Error.ChannelClosed;
        const slot_id = self.activeTerminalSlotId(tab_id) orelse return ssh_session.Error.ChannelClosed;
        try worker.queueInput(slot_id, bytes);
    }

    pub fn sendSshMouse(self: *SessionRegistry, tab_id: u64, event: terminal.MouseEvent) !void {
        const worker = self.sshWorkspace(tab_id) orelse return ssh_session.Error.ChannelClosed;
        const slot_id = self.activeTerminalSlotId(tab_id) orelse return ssh_session.Error.ChannelClosed;
        try worker.queueMouse(slot_id, event);
    }

    pub fn resizeSshTerminal(self: *SessionRegistry, tab_id: u64, size: ssh.PtySize) !void {
        const worker = self.sshWorkspace(tab_id) orelse return ssh_session.Error.ChannelClosed;
        const slot_id = self.activeTerminalSlotId(tab_id) orelse return ssh_session.Error.ChannelClosed;
        try worker.queueResize(slot_id, size);
    }

    pub fn clearSshScrollback(self: *SessionRegistry, tab_id: u64) !void {
        const worker = self.sshWorkspace(tab_id) orelse return ssh_session.Error.ChannelClosed;
        const slot_id = self.activeTerminalSlotId(tab_id) orelse return ssh_session.Error.ChannelClosed;
        try worker.queueClearScrollback(slot_id);
    }

    pub fn sshFailure(self: *SessionRegistry, tab_id: u64) ?ssh_session.Error {
        const worker = self.sshWorkspace(tab_id) orelse return null;
        return worker.last_error;
    }

    pub fn activeTab(self: *SessionRegistry) ?workspace.WorkspaceTab {
        const id = self.active_tab_id orelse return null;
        return self.tabById(id);
    }

    pub fn tabById(self: *SessionRegistry, id: u64) ?workspace.WorkspaceTab {
        for (self.tabs.items) |tab| {
            if (tab.id == id) return tab;
        }
        return null;
    }

    pub fn findByProfileId(self: *SessionRegistry, profile_id: u64) ?u64 {
        for (self.tabs.items) |tab| {
            if (tab.profile_id == profile_id) return tab.id;
        }
        return null;
    }

    fn createTab(self: *SessionRegistry, connection: profile.ConnectionProfile, status: workspace.TabStatus) !u64 {
        const id = self.next_id;
        self.next_id += 1;

        const b = connection.base;
        const title = try self.allocator.dupe(u8, b.name);
        errdefer self.allocator.free(title);

        try self.tabs.append(self.allocator, .{
            .id = id,
            .profile_id = b.id,
            .title = title,
            .layout = .terminal_file,
            .status = status,
        });
        self.active_tab_id = id;
        return id;
    }

    fn setActiveTerminalSlot(self: *SessionRegistry, tab_id: u64, slot_id: terminal_slot.TerminalSlotId) !void {
        if (self.activeTerminalSlotIndex(tab_id)) |idx| {
            self.active_terminal_slots.items[idx].slot_id = slot_id;
            return;
        }
        try self.active_terminal_slots.append(self.allocator, .{ .tab_id = tab_id, .slot_id = slot_id });
    }

    fn setTabStatus(self: *SessionRegistry, id: u64, status: workspace.TabStatus) void {
        for (self.tabs.items) |*tab| {
            if (tab.id == id) {
                tab.status = status;
                return;
            }
        }
    }

    fn reuseExistingTab(self: *SessionRegistry, id: u64) bool {
        for (self.tabs.items) |tab| {
            if (tab.id != id) continue;
            if (tab.status == .failed or tab.status == .closed) return false;
            self.active_tab_id = id;
            return true;
        }
        return false;
    }

    fn sshWorkspaceIndex(self: *SessionRegistry, tab_id: u64) ?usize {
        for (self.ssh_workspaces.items, 0..) |slot, idx| {
            if (slot.tab_id == tab_id) return idx;
        }
        return null;
    }

    fn activeTerminalSlotIndex(self: *SessionRegistry, tab_id: u64) ?usize {
        for (self.active_terminal_slots.items, 0..) |active, idx| {
            if (active.tab_id == tab_id) return idx;
        }
        return null;
    }

    fn reapRetiredWorkspaces(self: *SessionRegistry) void {
        var idx: usize = 0;
        while (idx < self.retired_ssh_workspaces.items.len) {
            const slot = self.retired_ssh_workspaces.items[idx];
            slot.worker.reapFinishedThreads();
            if (!slot.worker.canDestroyWithoutBlocking()) {
                idx += 1;
                continue;
            }
            slot.worker.destroy();
            self.releaseRunningTransfersForTab(slot.tab_id);
            _ = self.retired_ssh_workspaces.orderedRemove(idx);
        }
    }

    fn dispatchTransfers(self: *SessionRegistry) void {
        while (self.transfer_scheduler.nextReady(self.allocator) catch null) |task| {
            const record_idx = self.queuedTransferIntentIndex(task.id) orelse {
                _ = self.transfer_scheduler.finish(task.id);
                continue;
            };
            const record = self.queued_transfer_intents.items[record_idx];
            const worker = self.sshWorkspace(record.tab_id) orelse {
                _ = self.transfer_scheduler.finish(task.id);
                self.emitTransferUpdate(task.id, .failed);
                self.removeQueuedTransferIntentAt(record_idx);
                continue;
            };
            worker.queueFileIntent(record.intent) catch {
                _ = self.transfer_scheduler.finish(task.id);
                self.emitTransferUpdate(task.id, .failed);
                self.removeQueuedTransferIntentAt(record_idx);
                continue;
            };
            self.removeQueuedTransferIntentAt(record_idx);
        }
    }

    fn cancelPendingTransfersForTab(self: *SessionRegistry, tab_id: u64) void {
        var canceled_ids: std.ArrayList(u64) = .empty;
        defer canceled_ids.deinit(self.allocator);
        self.transfer_scheduler.removePendingSession(tab_id, &canceled_ids, self.allocator);
        for (canceled_ids.items) |transfer_id| {
            self.removeQueuedTransferIntent(transfer_id);
            self.emitTransferUpdate(transfer_id, .canceled);
        }
    }

    fn releaseRunningTransfersForTab(self: *SessionRegistry, tab_id: u64) void {
        var canceled_ids: std.ArrayList(u64) = .empty;
        defer canceled_ids.deinit(self.allocator);
        self.transfer_scheduler.removeRunningSession(tab_id, &canceled_ids, self.allocator);
        for (canceled_ids.items) |transfer_id| {
            self.removeQueuedTransferIntent(transfer_id);
            self.emitTransferUpdate(transfer_id, .canceled);
        }
    }

    fn emitTransferUpdate(self: *SessionRegistry, id: u64, status: transfer.TransferStatus) void {
        self.transfer_updates.append(self.allocator, .{
            .id = id,
            .status = status,
            .progress = if (status == .pending or status == .running) 0 else 1,
        }) catch {};
    }

    fn drainTransferUpdates(self: *SessionRegistry, buffer: []transfer.TransferProgress) usize {
        const count = @min(buffer.len, self.transfer_updates.items.len);
        if (count == 0) return 0;
        @memcpy(buffer[0..count], self.transfer_updates.items[0..count]);
        self.transfer_updates.replaceRange(self.allocator, 0, count, &.{}) catch {
            for (0..count) |_| _ = self.transfer_updates.orderedRemove(0);
        };
        return count;
    }

    fn queuedTransferIntentIndex(self: *const SessionRegistry, transfer_id: u64) ?usize {
        for (self.queued_transfer_intents.items, 0..) |record, idx| {
            if (record.id == transfer_id) return idx;
        }
        return null;
    }

    fn removeQueuedTransferIntent(self: *SessionRegistry, transfer_id: u64) void {
        const idx = self.queuedTransferIntentIndex(transfer_id) orelse return;
        self.removeQueuedTransferIntentAt(idx);
    }

    fn removeQueuedTransferIntentAt(self: *SessionRegistry, idx: usize) void {
        const record = self.queued_transfer_intents.orderedRemove(idx);
        remote_file.freePanelIntent(self.allocator, record.intent);
    }
};

fn transferIntentId(intent: remote_file.FilePanelIntent) ?u64 {
    return switch (intent) {
        .upload => |item| item.transfer_id,
        .upload_many => |item| item.transfer_id,
        .download => |item| item.transfer_id,
        .download_many => |item| item.transfer_id,
        else => null,
    };
}

fn isTerminalTransferStatus(status: transfer.TransferStatus) bool {
    return status == .completed or status == .failed or status == .canceled;
}

fn consumeFileNotice(presented_generation: *u64, generation: u64, summary: ?[]const u8) ?[]const u8 {
    if (generation == 0 or generation == presented_generation.* or summary == null) return null;
    presented_generation.* = generation;
    return summary;
}

test "file notices are presented once per generation" {
    var presented: u64 = 0;
    try std.testing.expectEqualStrings("Failed", consumeFileNotice(&presented, 1, "Failed").?);
    try std.testing.expect(consumeFileNotice(&presented, 1, "Failed") == null);
    try std.testing.expectEqualStrings("Failed", consumeFileNotice(&presented, 2, "Failed").?);
}
