const std = @import("std");

pub const default_global_limit: usize = 10;
pub const default_session_limit: usize = 4;

pub const Task = struct {
    id: u64,
    session_id: u64,
};

pub const Scheduler = struct {
    global_limit: usize = default_global_limit,
    session_limit: usize = default_session_limit,
    pending: std.ArrayList(Task) = .empty,
    running: std.ArrayList(Task) = .empty,

    pub fn deinit(self: *Scheduler, allocator: std.mem.Allocator) void {
        self.pending.deinit(allocator);
        self.running.deinit(allocator);
    }

    pub fn enqueue(self: *Scheduler, allocator: std.mem.Allocator, task: Task) !void {
        if (self.contains(task.id)) return;
        try self.pending.append(allocator, task);
    }

    pub fn nextReady(self: *Scheduler, allocator: std.mem.Allocator) !?Task {
        if (self.running.items.len >= self.global_limit) return null;
        for (self.pending.items, 0..) |task, idx| {
            if (self.runningCountForSession(task.session_id) >= self.session_limit) continue;
            try self.running.ensureUnusedCapacity(allocator, 1);
            const ready = self.pending.orderedRemove(idx);
            self.running.appendAssumeCapacity(ready);
            return ready;
        }
        return null;
    }

    pub fn finish(self: *Scheduler, id: u64) bool {
        for (self.running.items, 0..) |task, idx| {
            if (task.id != id) continue;
            _ = self.running.orderedRemove(idx);
            return true;
        }
        return false;
    }

    pub fn cancelPending(self: *Scheduler, id: u64) bool {
        for (self.pending.items, 0..) |task, idx| {
            if (task.id != id) continue;
            _ = self.pending.orderedRemove(idx);
            return true;
        }
        return false;
    }

    pub fn removePendingSession(self: *Scheduler, session_id: u64, canceled_ids: *std.ArrayList(u64), allocator: std.mem.Allocator) void {
        removeSessionTasks(&self.pending, session_id, canceled_ids, allocator);
    }

    pub fn removeRunningSession(self: *Scheduler, session_id: u64, canceled_ids: *std.ArrayList(u64), allocator: std.mem.Allocator) void {
        removeSessionTasks(&self.running, session_id, canceled_ids, allocator);
    }

    pub fn isPending(self: *const Scheduler, id: u64) bool {
        return containsId(self.pending.items, id);
    }

    pub fn isRunning(self: *const Scheduler, id: u64) bool {
        return containsId(self.running.items, id);
    }

    pub fn runningSession(self: *const Scheduler, id: u64) ?u64 {
        for (self.running.items) |task| {
            if (task.id == id) return task.session_id;
        }
        return null;
    }

    pub fn runningCountForSession(self: *const Scheduler, session_id: u64) usize {
        var count: usize = 0;
        for (self.running.items) |task| {
            if (task.session_id == session_id) count += 1;
        }
        return count;
    }

    fn contains(self: *const Scheduler, id: u64) bool {
        return self.isPending(id) or self.isRunning(id);
    }
};

fn removeSessionTasks(
    tasks: *std.ArrayList(Task),
    session_id: u64,
    canceled_ids: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
) void {
    var idx: usize = 0;
    while (idx < tasks.items.len) {
        if (tasks.items[idx].session_id != session_id) {
            idx += 1;
            continue;
        }
        canceled_ids.append(allocator, tasks.items[idx].id) catch {};
        _ = tasks.orderedRemove(idx);
    }
}

fn containsId(tasks: []const Task, id: u64) bool {
    for (tasks) |task| {
        if (task.id == id) return true;
    }
    return false;
}

test "scheduler enforces global and per-session limits" {
    var scheduler = Scheduler{ .global_limit = 3, .session_limit = 2 };
    defer scheduler.deinit(std.testing.allocator);

    try scheduler.enqueue(std.testing.allocator, .{ .id = 1, .session_id = 10 });
    try scheduler.enqueue(std.testing.allocator, .{ .id = 2, .session_id = 10 });
    try scheduler.enqueue(std.testing.allocator, .{ .id = 3, .session_id = 10 });
    try scheduler.enqueue(std.testing.allocator, .{ .id = 4, .session_id = 20 });

    try std.testing.expectEqual(@as(u64, 1), (try scheduler.nextReady(std.testing.allocator)).?.id);
    try std.testing.expectEqual(@as(u64, 2), (try scheduler.nextReady(std.testing.allocator)).?.id);
    try std.testing.expectEqual(@as(u64, 4), (try scheduler.nextReady(std.testing.allocator)).?.id);
    try std.testing.expect((try scheduler.nextReady(std.testing.allocator)) == null);
    try std.testing.expectEqual(@as(usize, 3), scheduler.running.items.len);
    try std.testing.expectEqual(@as(usize, 2), scheduler.runningCountForSession(10));

    try std.testing.expect(scheduler.finish(1));
    try std.testing.expectEqual(@as(u64, 3), (try scheduler.nextReady(std.testing.allocator)).?.id);
}

test "scheduler cancels pending work without consuming a permit" {
    var scheduler = Scheduler{};
    defer scheduler.deinit(std.testing.allocator);

    try scheduler.enqueue(std.testing.allocator, .{ .id = 1, .session_id = 10 });
    try std.testing.expect(scheduler.cancelPending(1));
    try std.testing.expect(!scheduler.isPending(1));
    try std.testing.expectEqual(@as(usize, 0), scheduler.running.items.len);
}

test "retiring a session keeps running permits until its worker stops" {
    var scheduler = Scheduler{ .global_limit = 1, .session_limit = 1 };
    defer scheduler.deinit(std.testing.allocator);

    try scheduler.enqueue(std.testing.allocator, .{ .id = 1, .session_id = 10 });
    try scheduler.enqueue(std.testing.allocator, .{ .id = 2, .session_id = 20 });
    _ = try scheduler.nextReady(std.testing.allocator);

    var canceled: std.ArrayList(u64) = .empty;
    defer canceled.deinit(std.testing.allocator);
    scheduler.removePendingSession(10, &canceled, std.testing.allocator);
    try std.testing.expect((try scheduler.nextReady(std.testing.allocator)) == null);

    scheduler.removeRunningSession(10, &canceled, std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 2), (try scheduler.nextReady(std.testing.allocator)).?.id);
}

test "default scheduler caps ten globally and four per session" {
    var scheduler = Scheduler{};
    defer scheduler.deinit(std.testing.allocator);

    for (0..16) |idx| {
        try scheduler.enqueue(std.testing.allocator, .{
            .id = idx + 1,
            .session_id = if (idx < 8) 1 else 2,
        });
    }
    while (try scheduler.nextReady(std.testing.allocator)) |_| {}

    try std.testing.expectEqual(@as(usize, 8), scheduler.running.items.len);
    try std.testing.expectEqual(@as(usize, 4), scheduler.runningCountForSession(1));
    try std.testing.expectEqual(@as(usize, 4), scheduler.runningCountForSession(2));

    for (0..8) |idx| {
        try scheduler.enqueue(std.testing.allocator, .{
            .id = 100 + idx,
            .session_id = 3 + idx,
        });
    }
    while (try scheduler.nextReady(std.testing.allocator)) |_| {}
    try std.testing.expectEqual(default_global_limit, scheduler.running.items.len);
}
