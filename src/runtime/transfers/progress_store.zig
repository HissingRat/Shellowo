const std = @import("std");
const transfer = @import("../../core/transfer.zig");

const State = struct {
    id: u64,
    status: transfer.TransferStatus,
    progress: f32,
    bytes_done: u64 = 0,
    bytes_total: ?u64 = null,
    cancel_requested: bool = false,
    finished: bool = false,
    error_summary: [transfer.max_error_summary]u8 = undefined,
    error_len: usize = 0,
};

pub const Store = struct {
    items: std.ArrayList(State) = .empty,

    pub fn deinit(self: *Store, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
    }

    pub fn consumeFinished(self: *Store, buffer: []transfer.TransferProgress) []transfer.TransferProgress {
        var count: usize = 0;
        var idx: usize = 0;
        while (idx < self.items.items.len and count < buffer.len) {
            const item = self.items.items[idx];
            if (!isTerminal(item)) {
                idx += 1;
                continue;
            }
            buffer[count] = toSnapshot(item);
            count += 1;
            _ = self.items.orderedRemove(idx);
        }

        idx = 0;
        while (idx < self.items.items.len and count < buffer.len) : (idx += 1) {
            const item = self.items.items[idx];
            if (isTerminal(item)) continue;
            buffer[count] = toSnapshot(item);
            count += 1;
        }
        return buffer[0..count];
    }

    fn isTerminal(item: State) bool {
        if (!item.finished) return false;
        return switch (item.status) {
            .completed, .failed, .canceled => true,
            else => false,
        };
    }

    pub fn requestCancel(self: *Store, allocator: std.mem.Allocator, id: u64) void {
        const state = self.ensure(allocator, id) catch return;
        state.cancel_requested = true;
        state.status = .canceled;
        state.progress = 1;
    }

    pub fn cancelActive(self: *Store) void {
        for (self.items.items) |*state| {
            if (state.finished) continue;
            state.cancel_requested = true;
            state.status = .canceled;
            state.progress = 1;
        }
    }

    pub fn mark(self: *Store, allocator: std.mem.Allocator, id: u64, status: transfer.TransferStatus, progress: f32, bytes_done: u64, bytes_total: ?u64) void {
        const state = self.ensure(allocator, id) catch return;
        if (state.cancel_requested) return;
        state.status = status;
        state.progress = @max(0, @min(progress, 1));
        state.bytes_done = bytes_done;
        state.bytes_total = bytes_total;
        state.finished = false;
        state.error_len = 0;
    }

    pub fn finish(self: *Store, allocator: std.mem.Allocator, id: u64, status: transfer.TransferStatus) void {
        const state = self.ensure(allocator, id) catch return;
        state.status = if (state.cancel_requested and status != .canceled) .canceled else status;
        if (state.status == .completed) state.progress = 1;
        state.finished = true;
    }

    pub fn fail(self: *Store, allocator: std.mem.Allocator, id: u64, message: []const u8) void {
        const state = self.ensure(allocator, id) catch return;
        state.status = if (state.cancel_requested) .canceled else .failed;
        state.finished = true;
        const len = @min(state.error_summary.len, message.len);
        if (len > 0) @memcpy(state.error_summary[0..len], message[0..len]);
        state.error_len = len;
    }

    pub fn canceled(self: *const Store, id: u64) bool {
        const idx = self.indexOf(id) orelse return false;
        return self.items.items[idx].cancel_requested;
    }

    fn ensure(self: *Store, allocator: std.mem.Allocator, id: u64) !*State {
        if (self.indexOf(id)) |idx| return &self.items.items[idx];
        try self.items.append(allocator, .{ .id = id, .status = .running, .progress = 0 });
        return &self.items.items[self.items.items.len - 1];
    }

    fn indexOf(self: *const Store, id: u64) ?usize {
        for (self.items.items, 0..) |item, idx| {
            if (item.id == id) return idx;
        }
        return null;
    }
};

fn toSnapshot(item: State) transfer.TransferProgress {
    return .{
        .id = item.id,
        .status = item.status,
        .progress = item.progress,
        .bytes_done = item.bytes_done,
        .bytes_total = item.bytes_total,
        .error_summary = item.error_summary,
        .error_len = item.error_len,
    };
}

test "finished progress remains queued when output buffer is full" {
    var store = Store{};
    defer store.deinit(std.testing.allocator);

    store.finish(std.testing.allocator, 1, .completed);
    store.finish(std.testing.allocator, 2, .failed);

    var first_buffer: [1]transfer.TransferProgress = undefined;
    const first = store.consumeFinished(&first_buffer);
    try std.testing.expectEqual(@as(usize, 1), first.len);
    try std.testing.expectEqual(@as(u64, 1), first[0].id);

    var second_buffer: [1]transfer.TransferProgress = undefined;
    const second = store.consumeFinished(&second_buffer);
    try std.testing.expectEqual(@as(usize, 1), second.len);
    try std.testing.expectEqual(@as(u64, 2), second[0].id);
    try std.testing.expectEqual(@as(usize, 0), store.items.items.len);
}

test "finished progress is delivered before active progress" {
    var store = Store{};
    defer store.deinit(std.testing.allocator);

    store.mark(std.testing.allocator, 1, .running, 0.5, 5, 10);
    store.finish(std.testing.allocator, 2, .completed);

    var buffer: [1]transfer.TransferProgress = undefined;
    const updates = store.consumeFinished(&buffer);
    try std.testing.expectEqual(@as(usize, 1), updates.len);
    try std.testing.expectEqual(@as(u64, 2), updates[0].id);
    try std.testing.expectEqual(@as(usize, 1), store.items.items.len);
}
