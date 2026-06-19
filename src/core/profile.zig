const std = @import("std");

pub const AuthType = enum {
    password,
    private_key,
    agent,

    pub fn label(self: AuthType) []const u8 {
        return switch (self) {
            .password => "Password",
            .private_key => "Private Key",
            .agent => "Agent",
        };
    }
};

pub const BaseProfile = struct {
    id: u64,
    name: []const u8,
    host: []const u8,
    port: u16,
    username: []const u8,
    group: []const u8 = "Default",
};

pub const ConnectionProfile = struct {
    base: BaseProfile,
    auth_type: AuthType = .password,
    password: []const u8 = "",
    private_key_path: []const u8 = "",
    private_key_passphrase: []const u8 = "",
    sftp_enabled: bool = true,

    pub fn deinit(self: ConnectionProfile, allocator: std.mem.Allocator) void {
        const b = self.base;
        allocator.free(b.name);
        allocator.free(b.host);
        allocator.free(b.username);
        allocator.free(b.group);
        allocator.free(self.password);
        allocator.free(self.private_key_path);
        allocator.free(self.private_key_passphrase);
    }

    pub fn clone(self: ConnectionProfile, allocator: std.mem.Allocator) !ConnectionProfile {
        const b = self.base;
        const copied_base = BaseProfile{
            .id = b.id,
            .name = try allocator.dupe(u8, b.name),
            .host = try allocator.dupe(u8, b.host),
            .port = b.port,
            .username = try allocator.dupe(u8, b.username),
            .group = try allocator.dupe(u8, b.group),
        };

        return .{
            .base = copied_base,
            .auth_type = self.auth_type,
            .password = try allocator.dupe(u8, self.password),
            .private_key_path = try allocator.dupe(u8, self.private_key_path),
            .private_key_passphrase = try allocator.dupe(u8, self.private_key_passphrase),
            .sftp_enabled = self.sftp_enabled,
        };
    }
};

pub const ProfileDraft = struct {
    name: [64]u8 = std.mem.zeroes([64]u8),
    host: [128]u8 = std.mem.zeroes([128]u8),
    username: [64]u8 = std.mem.zeroes([64]u8),
    password: [96]u8 = std.mem.zeroes([96]u8),
    private_key_path: [256]u8 = std.mem.zeroes([256]u8),
    private_key_passphrase: [96]u8 = std.mem.zeroes([96]u8),
    group: [64]u8 = std.mem.zeroes([64]u8),
    auth_type: AuthType = .password,
    port: u16 = 22,
    sftp_enabled: bool = true,
    editing_id: ?u64 = null,

    pub fn reset(self: *ProfileDraft) void {
        self.* = .{};
        setBuffer(&self.group, "Default");
    }

    pub fn load(self: *ProfileDraft, profile: ConnectionProfile) void {
        const b = profile.base;
        self.* = .{
            .port = b.port,
            .sftp_enabled = profile.sftp_enabled,
            .auth_type = profile.auth_type,
            .editing_id = b.id,
        };
        setBuffer(&self.name, b.name);
        setBuffer(&self.host, b.host);
        setBuffer(&self.username, b.username);
        setBuffer(&self.password, profile.password);
        setBuffer(&self.private_key_path, profile.private_key_path);
        setBuffer(&self.private_key_passphrase, profile.private_key_passphrase);
        setBuffer(&self.group, b.group);
    }

    pub fn toProfile(self: *const ProfileDraft, allocator: std.mem.Allocator, id: u64) !ConnectionProfile {
        const base_profile = BaseProfile{
            .id = id,
            .name = try allocator.dupe(u8, textFromBuffer(&self.name)),
            .host = try allocator.dupe(u8, textFromBuffer(&self.host)),
            .port = self.port,
            .username = try allocator.dupe(u8, textFromBuffer(&self.username)),
            .group = try allocator.dupe(u8, textFromBuffer(&self.group)),
        };

        return .{
            .base = base_profile,
            .auth_type = self.auth_type,
            .password = try allocator.dupe(u8, textFromBuffer(&self.password)),
            .private_key_path = try allocator.dupe(u8, textFromBuffer(&self.private_key_path)),
            .private_key_passphrase = try allocator.dupe(u8, textFromBuffer(&self.private_key_passphrase)),
            .sftp_enabled = self.sftp_enabled,
        };
    }
};

pub fn textFromBuffer(buffer: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len;
    return std.mem.trim(u8, buffer[0..end], " \t\r\n");
}

pub fn setBuffer(buffer: []u8, value: []const u8) void {
    @memset(buffer, 0);
    const len = @min(buffer.len, value.len);
    @memcpy(buffer[0..len], value[0..len]);
}

test "draft defaults use ssh port" {
    var draft = ProfileDraft{};
    draft.reset();
    try std.testing.expectEqual(@as(u16, 22), draft.port);
}

test "connection profile clone owns copied fields" {
    var draft = ProfileDraft{};
    draft.reset();
    setBuffer(&draft.name, "Clone Me");
    setBuffer(&draft.host, "example.test");
    setBuffer(&draft.username, "dev");
    setBuffer(&draft.password, "pw");

    const original = try draft.toProfile(std.testing.allocator, 1);
    defer original.deinit(std.testing.allocator);
    const copied = try original.clone(std.testing.allocator);
    defer copied.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(original.base.name, copied.base.name);
    try std.testing.expect(original.base.name.ptr != copied.base.name.ptr);
    try std.testing.expectEqualStrings(original.password, copied.password);
    try std.testing.expect(original.password.ptr != copied.password.ptr);
}

test "draft can create private key auth profile" {
    var draft = ProfileDraft{};
    draft.reset();
    draft.auth_type = .private_key;
    setBuffer(&draft.name, "Key Login");
    setBuffer(&draft.host, "example.test");
    setBuffer(&draft.username, "dev");
    setBuffer(&draft.private_key_path, "/Users/dev/.ssh/id_ed25519");
    setBuffer(&draft.private_key_passphrase, "phrase");

    const item = try draft.toProfile(std.testing.allocator, 2);
    defer item.deinit(std.testing.allocator);

    try std.testing.expectEqual(AuthType.private_key, item.auth_type);
    try std.testing.expectEqualStrings("/Users/dev/.ssh/id_ed25519", item.private_key_path);
    try std.testing.expectEqualStrings("phrase", item.private_key_passphrase);
}
