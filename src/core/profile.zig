const std = @import("std");

pub const SessionType = enum {
    ssh,
    ftp,

    pub fn label(self: SessionType) []const u8 {
        return switch (self) {
            .ssh => "SSH",
            .ftp => "FTP",
        };
    }
};

pub const AuthType = enum {
    password,
    private_key,
    agent,
};

pub const BaseProfile = struct {
    id: u64,
    name: []const u8,
    host: []const u8,
    port: u16,
    username: []const u8,
    group: []const u8 = "Default",
};

pub const SshProfile = struct {
    base: BaseProfile,
    auth_type: AuthType = .password,
    password: []const u8 = "",
    private_key_path: []const u8 = "",
    sftp_enabled: bool = true,
};

pub const FtpProfile = struct {
    base: BaseProfile,
    password: []const u8 = "",
    secure: bool = false,
};

pub const ConnectionProfile = union(SessionType) {
    ssh: SshProfile,
    ftp: FtpProfile,

    pub fn base(self: ConnectionProfile) BaseProfile {
        return switch (self) {
            .ssh => |profile| profile.base,
            .ftp => |profile| profile.base,
        };
    }

    pub fn basePtr(self: *ConnectionProfile) *BaseProfile {
        return switch (self.*) {
            .ssh => |*profile| &profile.base,
            .ftp => |*profile| &profile.base,
        };
    }

    pub fn sessionType(self: ConnectionProfile) SessionType {
        return switch (self) {
            .ssh => .ssh,
            .ftp => .ftp,
        };
    }

    pub fn layoutLabel(self: ConnectionProfile) []const u8 {
        return switch (self) {
            .ssh => "terminal + files",
            .ftp => "file only",
        };
    }

    pub fn deinit(self: ConnectionProfile, allocator: std.mem.Allocator) void {
        const b = self.base();
        allocator.free(b.name);
        allocator.free(b.host);
        allocator.free(b.username);
        allocator.free(b.group);
        switch (self) {
            .ssh => |profile| {
                allocator.free(profile.password);
                allocator.free(profile.private_key_path);
            },
            .ftp => |profile| allocator.free(profile.password),
        }
    }

    pub fn clone(self: ConnectionProfile, allocator: std.mem.Allocator) !ConnectionProfile {
        const b = self.base();
        const copied_base = BaseProfile{
            .id = b.id,
            .name = try allocator.dupe(u8, b.name),
            .host = try allocator.dupe(u8, b.host),
            .port = b.port,
            .username = try allocator.dupe(u8, b.username),
            .group = try allocator.dupe(u8, b.group),
        };

        return switch (self) {
            .ssh => |ssh| .{ .ssh = .{
                .base = copied_base,
                .auth_type = ssh.auth_type,
                .password = try allocator.dupe(u8, ssh.password),
                .private_key_path = try allocator.dupe(u8, ssh.private_key_path),
                .sftp_enabled = ssh.sftp_enabled,
            } },
            .ftp => |ftp| .{ .ftp = .{
                .base = copied_base,
                .password = try allocator.dupe(u8, ftp.password),
                .secure = ftp.secure,
            } },
        };
    }
};

pub const ProfileDraft = struct {
    profile_type: SessionType = .ssh,
    name: [64]u8 = std.mem.zeroes([64]u8),
    host: [128]u8 = std.mem.zeroes([128]u8),
    username: [64]u8 = std.mem.zeroes([64]u8),
    password: [96]u8 = std.mem.zeroes([96]u8),
    group: [64]u8 = std.mem.zeroes([64]u8),
    port: u16 = 22,
    sftp_enabled: bool = true,
    secure_ftp: bool = false,
    editing_id: ?u64 = null,

    pub fn reset(self: *ProfileDraft, profile_type: SessionType) void {
        self.* = .{ .profile_type = profile_type, .port = defaultPort(profile_type) };
        setBuffer(&self.group, "Default");
    }

    pub fn load(self: *ProfileDraft, profile: ConnectionProfile) void {
        const b = profile.base();
        self.* = .{
            .profile_type = profile.sessionType(),
            .port = b.port,
            .sftp_enabled = if (profile == .ssh) profile.ssh.sftp_enabled else false,
            .secure_ftp = if (profile == .ftp) profile.ftp.secure else false,
            .editing_id = b.id,
        };
        setBuffer(&self.name, b.name);
        setBuffer(&self.host, b.host);
        setBuffer(&self.username, b.username);
        switch (profile) {
            .ssh => |ssh| setBuffer(&self.password, ssh.password),
            .ftp => |ftp| setBuffer(&self.password, ftp.password),
        }
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

        return switch (self.profile_type) {
            .ssh => .{ .ssh = .{
                .base = base_profile,
                .auth_type = .password,
                .password = try allocator.dupe(u8, textFromBuffer(&self.password)),
                .private_key_path = try allocator.dupe(u8, ""),
                .sftp_enabled = self.sftp_enabled,
            } },
            .ftp => .{ .ftp = .{
                .base = base_profile,
                .password = try allocator.dupe(u8, textFromBuffer(&self.password)),
                .secure = self.secure_ftp,
            } },
        };
    }
};

pub fn defaultPort(session_type: SessionType) u16 {
    return switch (session_type) {
        .ssh => 22,
        .ftp => 21,
    };
}

pub fn textFromBuffer(buffer: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len;
    return std.mem.trim(u8, buffer[0..end], " \t\r\n");
}

pub fn setBuffer(buffer: []u8, value: []const u8) void {
    @memset(buffer, 0);
    const len = @min(buffer.len, value.len);
    @memcpy(buffer[0..len], value[0..len]);
}

test "draft defaults use protocol ports" {
    var draft = ProfileDraft{};
    draft.reset(.ftp);
    try std.testing.expectEqual(SessionType.ftp, draft.profile_type);
    try std.testing.expectEqual(@as(u16, 21), draft.port);
}

test "connection profile clone owns copied fields" {
    var draft = ProfileDraft{};
    draft.reset(.ssh);
    setBuffer(&draft.name, "Clone Me");
    setBuffer(&draft.host, "example.test");
    setBuffer(&draft.username, "dev");
    setBuffer(&draft.password, "pw");

    const original = try draft.toProfile(std.testing.allocator, 1);
    defer original.deinit(std.testing.allocator);
    const copied = try original.clone(std.testing.allocator);
    defer copied.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(original.base().name, copied.base().name);
    try std.testing.expect(original.base().name.ptr != copied.base().name.ptr);
    try std.testing.expectEqualStrings(original.ssh.password, copied.ssh.password);
    try std.testing.expect(original.ssh.password.ptr != copied.ssh.password.ptr);
}
