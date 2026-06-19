const std = @import("std");
const Io = std.Io;
const ssh = @import("../../contracts/ssh.zig");
const status_panel = @import("../../core/status_panel.zig");

const monitor_interval_ms = 500;
const monitor_exec_timeout_ms = 1_000;
const latency_probe_interval_ms = 5_000;
const latency_probe_timeout_ms = 1_000;
const latency_probe_command = "printf shellowo_latency_probe";
const monitor_script = @embedFile("shellowo-ssh-status-script");

pub const LatencyProbeSnapshot = struct {
    generation: u64 = 0,
    latency_ms: ?u32 = null,
};

pub const Runtime = struct {
    lock: std.atomic.Mutex = .unlocked,
    status: status_panel.StatusPanelSnapshot = .{},
    monitor_elapsed_ms: u32 = monitor_interval_ms,
    latency_probe_elapsed_ms: u32 = latency_probe_interval_ms,
    latency_probe_generation: u64 = 0,
    latency_probe_ms: ?u32 = null,

    pub fn snapshot(self: *Runtime, host: []const u8) status_panel.StatusPanelSnapshot {
        self.acquire();
        defer self.release();
        var result = self.status;
        if (host.len > 0) result.monitor.setIp(host);
        return result;
    }

    pub fn latencySnapshot(self: *Runtime) LatencyProbeSnapshot {
        self.acquire();
        defer self.release();
        return .{
            .generation = self.latency_probe_generation,
            .latency_ms = self.latency_probe_ms,
        };
    }

    pub fn pump(self: *Runtime, allocator: std.mem.Allocator, io: ?std.Io, client: ssh.Client) void {
        if (self.latency_probe_elapsed_ms < latency_probe_interval_ms) {
            self.latency_probe_elapsed_ms += 1;
        } else {
            self.latency_probe_elapsed_ms = 0;
            self.pumpLatencyProbe(allocator, io, client);
        }

        if (self.monitor_elapsed_ms < monitor_interval_ms) {
            self.monitor_elapsed_ms += 1;
            return;
        }
        self.monitor_elapsed_ms = 0;

        const previous_network = blk: {
            self.acquire();
            defer self.release();
            break :blk self.status.monitor.network;
        };
        const output = client.exec(allocator, .{
            .command = monitor_script,
            .timeout_ms = monitor_exec_timeout_ms,
            .max_output_bytes = 32 * 1024,
        }) catch |err| {
            self.storeError(@errorName(err));
            return;
        };
        defer allocator.free(output);

        const parsed = status_panel.parseMonitorJson(output, previous_network) catch |err| {
            self.storeError(@errorName(err));
            return;
        };
        self.acquire();
        self.status = .{ .monitor = parsed };
        self.release();
    }

    pub fn storeError(self: *Runtime, message: []const u8) void {
        self.acquire();
        defer self.release();
        if (self.status.monitor.state == .ready) {
            self.status.monitor.state = .stale;
        } else {
            self.status.monitor.state = .failed;
        }
        const len = @min(self.status.monitor.error_summary.len, message.len);
        if (len > 0) @memcpy(self.status.monitor.error_summary[0..len], message[0..len]);
        self.status.monitor.error_len = len;
    }

    fn pumpLatencyProbe(self: *Runtime, allocator: std.mem.Allocator, io: ?std.Io, client: ssh.Client) void {
        const active_io = io orelse return;
        const started = Io.Timestamp.now(active_io, .awake);
        const output = client.exec(allocator, .{
            .command = latency_probe_command,
            .timeout_ms = latency_probe_timeout_ms,
            .max_output_bytes = 64,
        }) catch return;
        defer allocator.free(output);
        if (!std.mem.eql(u8, output, "shellowo_latency_probe")) return;
        const elapsed = started.durationTo(Io.Timestamp.now(active_io, .awake)).toMilliseconds();
        if (elapsed < 0) return;
        self.acquire();
        self.latency_probe_generation +%= 1;
        self.latency_probe_ms = @intCast(@min(@as(i64, 5_000), elapsed));
        self.release();
    }

    fn acquire(self: *Runtime) void {
        while (!self.lock.tryLock()) std.Thread.yield() catch {};
    }

    fn release(self: *Runtime) void {
        self.lock.unlock();
    }
};
