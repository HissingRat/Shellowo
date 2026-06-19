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
};

pub const Store = struct {
    items: std.ArrayList(State) = .empty,

    pub fn deinit(self: *Store, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
    }

    pub fn consumeFinished(self: *Store, buffer: []transfer.TransferProgress) []transfer.TransferProgress {
        var count: usize = 0;
        var idx: usize = 0;
        while (idx < self.items.items.len) {
            const item = self.items.items[idx];
            if (count < buffer.len) {
                buffer[count] = toSnapshot(item);
                count += 1;
            }
            if (item.finished and (item.status == .completed or item.status == .failed or item.status == .canceled)) {
                _ = self.items.orderedRemove(idx);
                continue;
            }
            idx += 1;
        }
        return buffer[0..count];
    }

    pub fn snapshot(self: *const Store, buffer: []transfer.TransferProgress) []transfer.TransferProgress {
        const count = @min(buffer.len, self.items.items.len);
        for (self.items.items[0..count], 0..) |item, idx| buffer[idx] = toSnapshot(item);
        return buffer[0..count];
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
    }

    pub fn finish(self: *Store, allocator: std.mem.Allocator, id: u64, status: transfer.TransferStatus) void {
        const state = self.ensure(allocator, id) catch return;
        state.status = if (state.cancel_requested and status != .canceled) .canceled else status;
        state.progress = 1;
        state.finished = true;
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
    };
}
