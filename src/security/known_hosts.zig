const std = @import("std");
const ssh = @import("../protocols/ssh.zig");

pub const Entry = struct {
    host: []const u8,
    port: u16,
    algorithm: ssh.HostKeyAlgorithm,
    sha256: [32]u8,

    pub fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
    }
};

pub const PendingHostKey = struct {
    host: []const u8,
    port: u16,
    host_key: ssh.HostKey,

    pub fn deinit(self: PendingHostKey, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
    }

    pub fn endpoint(self: PendingHostKey) ssh.Endpoint {
        return .{ .host = self.host, .port = self.port };
    }
};

pub const KnownHosts = struct {
    allocator: std.mem.Allocator,
    lock: std.atomic.Mutex = .unlocked,
    entries: std.ArrayList(Entry) = .empty,
    trust_missing: bool = false,
    pending: ?PendingHostKey = null,

    pub fn init(allocator: std.mem.Allocator) KnownHosts {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *KnownHosts) void {
        self.clearPendingHostKey();
        for (self.entries.items) |entry| {
            entry.deinit(self.allocator);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn verifier(self: *KnownHosts) ssh.HostKeyVerifier {
        return .{
            .context = self,
            .vtable = &verifier_vtable,
        };
    }

    pub fn verify(self: *KnownHosts, endpoint: ssh.Endpoint, policy: ssh.HostKeyPolicy, host_key: ssh.HostKey) ssh.Error!void {
        self.lockKnownHosts();
        defer self.unlockKnownHosts();

        switch (policy) {
            .insecure_accept_any => return,
            .strict, .trust_on_first_use => {},
        }

        if (self.findLocked(endpoint)) |entry| {
            if (entry.algorithm == host_key.algorithm and std.mem.eql(u8, &entry.sha256, &host_key.sha256)) return;
            return ssh.Error.HostKeyChanged;
        }

        if (policy == .trust_on_first_use and self.trust_missing) {
            self.addTrustedLocked(endpoint, host_key) catch return ssh.Error.InvalidHostKey;
            return;
        }

        self.setPendingHostKeyLocked(endpoint, host_key) catch return ssh.Error.InvalidHostKey;
        return ssh.Error.HostKeyUnknown;
    }

    pub fn addTrusted(self: *KnownHosts, endpoint: ssh.Endpoint, host_key: ssh.HostKey) !void {
        self.lockKnownHosts();
        defer self.unlockKnownHosts();
        try self.addTrustedLocked(endpoint, host_key);
    }

    pub fn loadFromDisk(self: *KnownHosts, io: std.Io, path: []const u8) !void {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(bytes);

        const parsed = try std.json.parseFromSlice([]PersistedEntry, self.allocator, bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        self.clear();
        for (parsed.value) |item| {
            const decoded_len = try std.base64.standard_no_pad.Decoder.calcSizeForSlice(item.sha256);
            if (decoded_len != 32) continue;

            var sha256: [32]u8 = undefined;
            try std.base64.standard_no_pad.Decoder.decode(&sha256, item.sha256);

            try self.entries.append(self.allocator, .{
                .host = try self.allocator.dupe(u8, item.host),
                .port = item.port,
                .algorithm = algorithmFromLabel(item.algorithm),
                .sha256 = sha256,
            });
        }
    }

    pub fn saveToDisk(self: *KnownHosts, io: std.Io, path: []const u8) !void {
        self.lockKnownHosts();
        defer self.unlockKnownHosts();

        var persisted: std.ArrayList(PersistedEntry) = .empty;
        defer {
            for (persisted.items) |item| {
                self.allocator.free(item.sha256);
            }
            persisted.deinit(self.allocator);
        }

        for (self.entries.items) |entry| {
            const encoded_len = std.base64.standard_no_pad.Encoder.calcSize(entry.sha256.len);
            const encoded = try self.allocator.alloc(u8, encoded_len);
            _ = std.base64.standard_no_pad.Encoder.encode(encoded, &entry.sha256);
            errdefer self.allocator.free(encoded);

            try persisted.append(self.allocator, .{
                .host = entry.host,
                .port = entry.port,
                .algorithm = entry.algorithm.label(),
                .sha256 = encoded,
            });
        }

        const json = try std.json.Stringify.valueAlloc(self.allocator, persisted.items, .{ .whitespace = .indent_2 });
        defer self.allocator.free(json);

        try std.Io.Dir.cwd().createDirPath(io, "data");
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = path,
            .data = json,
        });
    }

    pub fn find(self: *KnownHosts, endpoint: ssh.Endpoint) ?Entry {
        self.lockKnownHosts();
        defer self.unlockKnownHosts();
        const idx = self.findIndexLocked(endpoint) orelse return null;
        return self.entries.items[idx];
    }

    pub fn copyPendingHostKey(self: *KnownHosts, allocator: std.mem.Allocator) !?PendingHostKey {
        self.lockKnownHosts();
        defer self.unlockKnownHosts();
        const pending = self.pending orelse return null;
        return .{
            .host = try allocator.dupe(u8, pending.host),
            .port = pending.port,
            .host_key = pending.host_key,
        };
    }

    pub fn trustPendingHostKey(self: *KnownHosts) !void {
        self.lockKnownHosts();
        defer self.unlockKnownHosts();
        const pending = self.pending orelse return;
        try self.addTrustedLocked(pending.endpoint(), pending.host_key);
        self.clearPendingHostKeyLocked();
    }

    pub fn clearPendingHostKey(self: *KnownHosts) void {
        self.lockKnownHosts();
        defer self.unlockKnownHosts();
        self.clearPendingHostKeyLocked();
    }

    fn clearPendingHostKeyLocked(self: *KnownHosts) void {
        if (self.pending) |pending| pending.deinit(self.allocator);
        self.pending = null;
    }

    fn findLocked(self: *KnownHosts, endpoint: ssh.Endpoint) ?Entry {
        const idx = self.findIndexLocked(endpoint) orelse return null;
        return self.entries.items[idx];
    }

    fn findIndexLocked(self: *KnownHosts, endpoint: ssh.Endpoint) ?usize {
        for (self.entries.items, 0..) |entry, idx| {
            if (entry.port == endpoint.port and std.mem.eql(u8, entry.host, endpoint.host)) return idx;
        }
        return null;
    }

    fn clear(self: *KnownHosts) void {
        self.clearPendingHostKeyLocked();
        for (self.entries.items) |entry| {
            entry.deinit(self.allocator);
        }
        self.entries.clearRetainingCapacity();
    }

    fn setPendingHostKeyLocked(self: *KnownHosts, endpoint: ssh.Endpoint, host_key: ssh.HostKey) !void {
        self.clearPendingHostKeyLocked();
        self.pending = .{
            .host = try self.allocator.dupe(u8, endpoint.host),
            .port = endpoint.port,
            .host_key = host_key,
        };
    }

    fn addTrustedLocked(self: *KnownHosts, endpoint: ssh.Endpoint, host_key: ssh.HostKey) !void {
        if (self.findIndexLocked(endpoint)) |idx| {
            self.entries.items[idx].algorithm = host_key.algorithm;
            self.entries.items[idx].sha256 = host_key.sha256;
            return;
        }

        try self.entries.append(self.allocator, .{
            .host = try self.allocator.dupe(u8, endpoint.host),
            .port = endpoint.port,
            .algorithm = host_key.algorithm,
            .sha256 = host_key.sha256,
        });
    }

    fn lockKnownHosts(self: *KnownHosts) void {
        while (!self.lock.tryLock()) {
            std.Thread.yield() catch {};
        }
    }

    fn unlockKnownHosts(self: *KnownHosts) void {
        self.lock.unlock();
    }
};

const PersistedEntry = struct {
    host: []const u8,
    port: u16,
    algorithm: []const u8,
    sha256: []const u8,
};

fn verifyFromVTable(context: *anyopaque, endpoint: ssh.Endpoint, policy: ssh.HostKeyPolicy, host_key: ssh.HostKey) ssh.Error!void {
    const self: *KnownHosts = @ptrCast(@alignCast(context));
    return self.verify(endpoint, policy, host_key);
}

const verifier_vtable: ssh.HostKeyVerifier.VTable = .{
    .verify = verifyFromVTable,
};

fn algorithmFromLabel(label: []const u8) ssh.HostKeyAlgorithm {
    inline for (@typeInfo(ssh.HostKeyAlgorithm).@"enum".fields) |field| {
        const value: ssh.HostKeyAlgorithm = @enumFromInt(field.value);
        if (std.mem.eql(u8, value.label(), label)) return value;
    }
    return .unknown;
}

test "strict policy rejects missing host key" {
    var known_hosts = KnownHosts.init(std.testing.allocator);
    defer known_hosts.deinit();

    try std.testing.expectError(ssh.Error.HostKeyUnknown, known_hosts.verify(
        .{ .host = "example.test", .port = 22 },
        .strict,
        .{ .algorithm = .ed25519, .sha256 = [_]u8{1} ** 32 },
    ));
}

test "trust on first use can explicitly add a missing host key" {
    var known_hosts = KnownHosts.init(std.testing.allocator);
    defer known_hosts.deinit();
    known_hosts.trust_missing = true;

    const endpoint = ssh.Endpoint{ .host = "example.test", .port = 22 };
    const host_key = ssh.HostKey{ .algorithm = .ed25519, .sha256 = [_]u8{2} ** 32 };
    try known_hosts.verify(endpoint, .trust_on_first_use, host_key);
    try known_hosts.verify(endpoint, .strict, host_key);
    try std.testing.expectEqual(@as(usize, 1), known_hosts.entries.items.len);
}

test "missing host key stores pending confirmation" {
    var known_hosts = KnownHosts.init(std.testing.allocator);
    defer known_hosts.deinit();

    const endpoint = ssh.Endpoint{ .host = "example.test", .port = 22 };
    const host_key = ssh.HostKey{ .algorithm = .ed25519, .sha256 = [_]u8{7} ** 32 };
    try std.testing.expectError(ssh.Error.HostKeyUnknown, known_hosts.verify(endpoint, .trust_on_first_use, host_key));
    const pending = (try known_hosts.copyPendingHostKey(std.testing.allocator)) orelse return error.MissingPendingHostKey;
    defer pending.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("example.test", pending.host);
    try std.testing.expectEqual(ssh.HostKeyAlgorithm.ed25519, pending.host_key.algorithm);
    try known_hosts.trustPendingHostKey();
    try std.testing.expect((try known_hosts.copyPendingHostKey(std.testing.allocator)) == null);
    try known_hosts.verify(endpoint, .strict, host_key);
}

test "changed host key is rejected" {
    var known_hosts = KnownHosts.init(std.testing.allocator);
    defer known_hosts.deinit();

    const endpoint = ssh.Endpoint{ .host = "example.test", .port = 22 };
    try known_hosts.addTrusted(endpoint, .{ .algorithm = .ed25519, .sha256 = [_]u8{3} ** 32 });

    try std.testing.expectError(ssh.Error.HostKeyChanged, known_hosts.verify(
        endpoint,
        .strict,
        .{ .algorithm = .ed25519, .sha256 = [_]u8{4} ** 32 },
    ));
}

test "algorithm labels round trip known host names" {
    try std.testing.expectEqual(ssh.HostKeyAlgorithm.ed25519, algorithmFromLabel("ssh-ed25519"));
    try std.testing.expectEqual(ssh.HostKeyAlgorithm.ecdsa_256, algorithmFromLabel("ecdsa-sha2-nistp256"));
    try std.testing.expectEqual(ssh.HostKeyAlgorithm.unknown, algorithmFromLabel("future-key"));
}
