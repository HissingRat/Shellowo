const std = @import("std");
const predictive = @import("../core/terminal/predictive.zig");
const terminal = @import("../contracts/terminal_emulator.zig");

pub const SnapshotCache = struct {
    tab_id: ?u64 = null,
    slot_id: ?u64 = null,
    generation: u64 = 0,
    pending_generation: ?u64 = null,
    last_present_ns: i128 = 0,
    snapshot: ?terminal.Snapshot = null,

    pub fn deinit(self: *SnapshotCache) void {
        if (self.snapshot) |*snapshot| snapshot.deinit();
        self.* = .{};
    }

    pub fn clear(self: *SnapshotCache) void {
        self.deinit();
    }
};

pub const PredictiveState = struct {
    tab_id: u64,
    slot_id: u64,
    state: predictive.DualState,
    last_probe_generation: u64 = 0,

    pub fn deinit(self: *PredictiveState) void {
        self.state.deinit();
        self.* = undefined;
    }
};

test "empty snapshot cache is inert" {
    var cache: SnapshotCache = .{};
    cache.clear();
    try std.testing.expect(cache.snapshot == null);
}
