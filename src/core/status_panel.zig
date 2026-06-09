const std = @import("std");

pub const max_disks = 4;
pub const max_processes = 5;
pub const max_network_points = 48;

pub const MonitorState = enum {
    unavailable,
    sampling,
    ready,
    stale,
    failed,
};

pub const PercentMetric = struct {
    percent: f32 = 0,
};

pub const CapacityMetric = struct {
    used_bytes: u64 = 0,
    total_bytes: u64 = 0,
    percent: f32 = 0,
};

pub const NetworkMetric = struct {
    rx_bytes_per_sec: u64 = 0,
    tx_bytes_per_sec: u64 = 0,
    sample_ms: u64 = 1000,
    sample_unix_ms: u64 = 0,
    history: [max_network_points]f32 = [_]f32{0} ** max_network_points,
    rx_history: [max_network_points]u64 = [_]u64{0} ** max_network_points,
    tx_history: [max_network_points]u64 = [_]u64{0} ** max_network_points,
    history_len: usize = 0,
};

pub const DiskMetric = struct {
    path: [64]u8 = undefined,
    path_len: usize = 0,
    free_bytes: u64 = 0,
    total_bytes: u64 = 0,
    percent: f32 = 0,

    pub fn pathText(self: *const DiskMetric) []const u8 {
        return self.path[0..self.path_len];
    }
};

pub const ProcessMetric = struct {
    cpu_percent: f32 = 0,
    memory_bytes: u64 = 0,
    command: [80]u8 = undefined,
    command_len: usize = 0,

    pub fn commandText(self: *const ProcessMetric) []const u8 {
        return self.command[0..self.command_len];
    }
};

pub const MonitorSnapshot = struct {
    state: MonitorState = .unavailable,
    last_sample_ms: ?i64 = null,
    ip: [64]u8 = undefined,
    ip_len: usize = 0,
    uptime_seconds: ?u64 = null,
    cpu: ?PercentMetric = null,
    memory: ?CapacityMetric = null,
    swap: ?CapacityMetric = null,
    network: ?NetworkMetric = null,
    disks: [max_disks]DiskMetric = undefined,
    disk_count: usize = 0,
    processes: [max_processes]ProcessMetric = undefined,
    process_count: usize = 0,
    error_summary: [96]u8 = undefined,
    error_len: usize = 0,

    pub fn ipText(self: *const MonitorSnapshot) []const u8 {
        return self.ip[0..self.ip_len];
    }

    pub fn setIp(self: *MonitorSnapshot, text: []const u8) void {
        copyText(&self.ip, &self.ip_len, text);
    }

    pub fn errorText(self: *const MonitorSnapshot) []const u8 {
        return self.error_summary[0..self.error_len];
    }
};

pub const StatusPanelSnapshot = struct {
    monitor: MonitorSnapshot = .{},
};

pub fn parseMonitorJson(input: []const u8, previous_network: ?NetworkMetric) !MonitorSnapshot {
    var parsed = try std.json.parseFromSlice(StatusJson, std.heap.page_allocator, input, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const value = parsed.value;
    if (!std.mem.eql(u8, value.schema, "shellow.status.v1")) return error.UnsupportedSchema;

    var snapshot = MonitorSnapshot{
        .state = .ready,
        .last_sample_ms = null,
        .uptime_seconds = value.uptime_seconds,
    };
    copyText(&snapshot.ip, &snapshot.ip_len, value.ip);

    if (value.cpu) |cpu| snapshot.cpu = .{ .percent = clampPercent(cpu.percent) };
    if (value.memory) |memory| snapshot.memory = capacityFromJson(memory);
    if (value.swap) |swap| snapshot.swap = capacityFromJson(swap);
    if (value.network) |network| {
        snapshot.network = if (previous_network) |prev|
            shiftedNetworkHistory(prev, network.rx_bytes_per_sec, network.tx_bytes_per_sec, value.sample_ms)
        else
            initialNetworkHistory(network.rx_bytes_per_sec, network.tx_bytes_per_sec, value.sample_ms);
    }

    if (value.disks) |disks| {
        for (disks[0..@min(disks.len, max_disks)], 0..) |disk, idx| {
            snapshot.disks[idx] = .{
                .free_bytes = disk.free_bytes,
                .total_bytes = disk.total_bytes,
                .percent = clampPercent(disk.percent),
            };
            copyText(&snapshot.disks[idx].path, &snapshot.disks[idx].path_len, disk.path);
            snapshot.disk_count += 1;
        }
    }

    if (value.processes) |processes| {
        for (processes[0..@min(processes.len, max_processes)], 0..) |proc, idx| {
            snapshot.processes[idx] = .{
                .cpu_percent = clampPercent(proc.cpu_percent),
                .memory_bytes = proc.memory_bytes,
            };
            copyText(&snapshot.processes[idx].command, &snapshot.processes[idx].command_len, proc.command);
            snapshot.process_count += 1;
        }
    }

    return snapshot;
}

pub fn unavailable() StatusPanelSnapshot {
    return .{};
}

fn capacityFromJson(value: CapacityJson) CapacityMetric {
    return .{
        .used_bytes = value.used_bytes,
        .total_bytes = value.total_bytes,
        .percent = clampPercent(value.percent),
    };
}

fn clampPercent(value: f32) f32 {
    if (!std.math.isFinite(value)) return 0;
    return @min(100, @max(0, value));
}

fn copyText(dest: []u8, len: *usize, text: []const u8) void {
    const count = @min(dest.len, text.len);
    if (count > 0) @memcpy(dest[0..count], text[0..count]);
    len.* = count;
}

fn initialNetworkHistory(rx: u64, tx: u64, sample_ms: u64) NetworkMetric {
    var network = NetworkMetric{
        .rx_bytes_per_sec = rx,
        .tx_bytes_per_sec = tx,
        .sample_ms = normalizedSampleMs(sample_ms),
        .sample_unix_ms = currentUnixMs(),
        .history_len = 1,
    };
    network.history[0] = @floatFromInt(rx + tx);
    network.rx_history[0] = rx;
    network.tx_history[0] = tx;
    return network;
}

fn shiftedNetworkHistory(previous: NetworkMetric, rx: u64, tx: u64, sample_ms: u64) NetworkMetric {
    var network = previous;
    network.rx_bytes_per_sec = rx;
    network.tx_bytes_per_sec = tx;
    network.sample_ms = normalizedSampleMs(sample_ms);
    network.sample_unix_ms = currentUnixMs();

    const len = @min(max_network_points, previous.history_len);
    if (len == 0) {
        network.history[0] = @floatFromInt(rx + tx);
        network.rx_history[0] = rx;
        network.tx_history[0] = tx;
        network.history_len = 1;
        return network;
    }

    if (len < max_network_points) {
        network.history[len] = @floatFromInt(rx + tx);
        network.rx_history[len] = rx;
        network.tx_history[len] = tx;
        network.history_len = len + 1;
        return network;
    }

    std.mem.copyForwards(f32, network.history[0 .. max_network_points - 1], network.history[1..max_network_points]);
    std.mem.copyForwards(u64, network.rx_history[0 .. max_network_points - 1], network.rx_history[1..max_network_points]);
    std.mem.copyForwards(u64, network.tx_history[0 .. max_network_points - 1], network.tx_history[1..max_network_points]);
    network.history[max_network_points - 1] = @floatFromInt(rx + tx);
    network.rx_history[max_network_points - 1] = rx;
    network.tx_history[max_network_points - 1] = tx;
    network.history_len = max_network_points;
    return network;
}

fn normalizedSampleMs(sample_ms: u64) u64 {
    return if (sample_ms == 0) 1000 else sample_ms;
}

fn currentUnixMs() u64 {
    if (@TypeOf(std.c.CLOCK) == void) return 0;
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return 0;
    const seconds: u64 = @intCast(@max(0, ts.sec));
    const nanos: u64 = @intCast(@max(0, ts.nsec));
    return seconds * std.time.ms_per_s + nanos / std.time.ns_per_ms;
}

const StatusJson = struct {
    schema: []const u8,
    platform: []const u8 = "",
    sample_ms: u64 = 1000,
    ip: []const u8 = "",
    uptime_seconds: ?u64 = null,
    cpu: ?PercentJson = null,
    memory: ?CapacityJson = null,
    swap: ?CapacityJson = null,
    network: ?NetworkJson = null,
    disks: ?[]DiskJson = null,
    processes: ?[]ProcessJson = null,
};

const PercentJson = struct {
    percent: f32 = 0,
};

const CapacityJson = struct {
    used_bytes: u64 = 0,
    total_bytes: u64 = 0,
    percent: f32 = 0,
};

const NetworkJson = struct {
    rx_bytes_per_sec: u64 = 0,
    tx_bytes_per_sec: u64 = 0,
};

const DiskJson = struct {
    path: []const u8 = "",
    free_bytes: u64 = 0,
    total_bytes: u64 = 0,
    percent: f32 = 0,
};

const ProcessJson = struct {
    cpu_percent: f32 = 0,
    memory_bytes: u64 = 0,
    command: []const u8 = "",
};

test "parse status monitor json" {
    const json =
        \\{
        \\  "schema": "shellow.status.v1",
        \\  "platform": "linux",
        \\  "sample_ms": 1000,
        \\  "ip": "10.0.0.2",
        \\  "uptime_seconds": 42,
        \\  "cpu": {"percent": 8.2},
        \\  "memory": {"used_bytes": 10, "total_bytes": 100, "percent": 10},
        \\  "swap": {"used_bytes": 0, "total_bytes": 0, "percent": 0},
        \\  "network": {"rx_bytes_per_sec": 20, "tx_bytes_per_sec": 30},
        \\  "disks": [{"path": "/", "free_bytes": 50, "total_bytes": 100, "percent": 50}],
        \\  "processes": [{"cpu_percent": 1.5, "memory_bytes": 12, "command": "sshd"}]
        \\}
    ;

    const snapshot = try parseMonitorJson(json, null);
    try std.testing.expectEqual(MonitorState.ready, snapshot.state);
    try std.testing.expectEqualStrings("10.0.0.2", snapshot.ipText());
    try std.testing.expectEqual(@as(u64, 42), snapshot.uptime_seconds.?);
    try std.testing.expectEqual(@as(usize, 1), snapshot.disk_count);
    try std.testing.expectEqualStrings("/", snapshot.disks[0].pathText());
    try std.testing.expectEqual(@as(usize, 1), snapshot.process_count);
    try std.testing.expectEqualStrings("sshd", snapshot.processes[0].commandText());
    try std.testing.expectEqual(@as(u64, 1000), snapshot.network.?.sample_ms);
    try std.testing.expectEqual(@as(u64, 20), snapshot.network.?.rx_history[0]);
    try std.testing.expectEqual(@as(u64, 30), snapshot.network.?.tx_history[0]);
}
