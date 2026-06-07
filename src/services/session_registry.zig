const std = @import("std");
const profile = @import("../core/profile.zig");
const workspace = @import("../core/workspace.zig");

pub const MockSessionRegistry = struct {
    allocator: std.mem.Allocator,
    tabs: std.ArrayList(workspace.WorkspaceTab) = .empty,
    next_id: u64 = 1,
    active_tab_id: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator) MockSessionRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MockSessionRegistry) void {
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

        const id = self.next_id;
        self.next_id += 1;

        const b = connection.base();
        const title = try self.allocator.dupe(u8, b.name);

        try self.tabs.append(self.allocator, .{
            .id = id,
            .profile_id = b.id,
            .session_type = connection.sessionType(),
            .title = title,
            .layout = workspace.layoutFor(connection.sessionType()),
            .status = .connected,
        });
        self.active_tab_id = id;
        return id;
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

    pub fn activeTab(self: *MockSessionRegistry) ?workspace.WorkspaceTab {
        const id = self.active_tab_id orelse return null;
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
};
