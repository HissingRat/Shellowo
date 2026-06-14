const std = @import("std");
const profile = @import("../core/profile.zig");
const profile_vault = @import("../security/profile_vault.zig");
const secret_file = @import("../security/secret_file.zig");

pub const Error = error{
    ProfileNotFound,
    MasterPasswordRequired,
    WrongMasterPassword,
};

pub const MemoryProfileRepository = struct {
    allocator: std.mem.Allocator,
    profiles: std.ArrayList(profile.ConnectionProfile) = .empty,
    next_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) MemoryProfileRepository {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MemoryProfileRepository) void {
        for (self.profiles.items) |item| {
            item.deinit(self.allocator);
        }
        self.profiles.deinit(self.allocator);
    }

    pub fn seedDefaults(self: *MemoryProfileRepository) !void {
        if (self.profiles.items.len != 0) return;

        try self.createSeed("Local Lab", "127.0.0.1", "dev", "Default");
    }

    pub fn loadFromDisk(self: *MemoryProfileRepository, io: std.Io, path: []const u8) !void {
        try self.loadFromDiskWithPassword(io, path, null);
    }

    pub fn loadFromDiskWithPassword(self: *MemoryProfileRepository, io: std.Io, path: []const u8, password: ?[]const u8) !void {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(bytes);

        if (profile_vault.isVaultJson(self.allocator, bytes)) {
            const plain = profile_vault.decryptProfilesJson(self.allocator, io, bytes, password orelse return Error.MasterPasswordRequired) catch |err| switch (err) {
                profile_vault.Error.AuthenticationFailed => return Error.WrongMasterPassword,
                else => return err,
            };
            defer self.allocator.free(plain);
            try self.loadFromJsonBytes(plain);
            return;
        }

        try self.loadFromJsonBytes(bytes);
    }

    pub fn profileFileEncrypted(self: *MemoryProfileRepository, io: std.Io, path: []const u8) !bool {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer self.allocator.free(bytes);
        return profile_vault.isVaultJson(self.allocator, bytes);
    }

    fn loadFromJsonBytes(self: *MemoryProfileRepository, bytes: []const u8) !void {
        const parsed = try std.json.parseFromSlice([]PersistedProfile, self.allocator, bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        self.clear();
        self.next_id = 1;
        for (parsed.value) |item| {
            if (!std.mem.eql(u8, item.type, "ssh")) continue;
            var draft = profile.ProfileDraft{};
            draft.reset();
            draft.editing_id = item.id;
            draft.port = item.port;
            draft.sftp_enabled = item.sftp_enabled;
            draft.auth_type = authTypeFromString(item.auth_type);
            profile.setBuffer(&draft.name, item.name);
            profile.setBuffer(&draft.host, item.host);
            profile.setBuffer(&draft.username, item.username);
            profile.setBuffer(&draft.group, item.group);
            profile.setBuffer(&draft.private_key_path, item.private_key_path);
            const decrypted_password = try secret_file.decrypt(self.allocator, item.encrypted_password);
            defer self.allocator.free(decrypted_password);
            profile.setBuffer(&draft.password, decrypted_password);
            const decrypted_passphrase = try secret_file.decrypt(self.allocator, item.encrypted_private_key_passphrase);
            defer self.allocator.free(decrypted_passphrase);
            profile.setBuffer(&draft.private_key_passphrase, decrypted_passphrase);
            _ = try self.upsertDraft(&draft);
            self.next_id = @max(self.next_id, item.id + 1);
        }
    }

    pub fn saveToDisk(self: *MemoryProfileRepository, io: std.Io, path: []const u8) !void {
        try self.saveToDiskWithPassword(io, path, null);
    }

    pub fn saveToDiskWithPassword(self: *MemoryProfileRepository, io: std.Io, path: []const u8, password: ?[]const u8) !void {
        const json = try self.profilesJson();
        defer self.allocator.free(json);

        const data = if (password) |master|
            try profile_vault.encryptProfilesJson(self.allocator, io, json, master)
        else
            try self.allocator.dupe(u8, json);
        defer self.allocator.free(data);

        try std.Io.Dir.cwd().createDirPath(io, "data");
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = path,
            .data = data,
        });
    }

    fn profilesJson(self: *MemoryProfileRepository) ![]u8 {
        var persisted: std.ArrayList(PersistedProfile) = .empty;
        defer {
            for (persisted.items) |item| {
                self.allocator.free(item.encrypted_password);
                self.allocator.free(item.encrypted_private_key_passphrase);
            }
            persisted.deinit(self.allocator);
        }

        for (self.profiles.items) |item| {
            const b = item.base;
            const password = item.password;
            const encrypted_password = try secret_file.encrypt(self.allocator, password);
            const encrypted_passphrase = try secret_file.encrypt(self.allocator, item.private_key_passphrase);
            persisted.append(self.allocator, .{
                .id = b.id,
                .type = "ssh",
                .name = b.name,
                .host = b.host,
                .port = b.port,
                .username = b.username,
                .auth_type = item.auth_type.label(),
                .encrypted_password = encrypted_password,
                .private_key_path = item.private_key_path,
                .encrypted_private_key_passphrase = encrypted_passphrase,
                .group = b.group,
                .sftp_enabled = item.sftp_enabled,
            }) catch |err| {
                self.allocator.free(encrypted_password);
                self.allocator.free(encrypted_passphrase);
                return err;
            };
        }

        return std.json.Stringify.valueAlloc(self.allocator, persisted.items, .{ .whitespace = .indent_2 });
    }

    pub fn upsertDraft(self: *MemoryProfileRepository, draft: *const profile.ProfileDraft) !u64 {
        const id = draft.editing_id orelse self.takeId();
        const new_profile = try draft.toProfile(self.allocator, id);
        errdefer new_profile.deinit(self.allocator);

        if (self.indexOf(id)) |idx| {
            self.profiles.items[idx].deinit(self.allocator);
            self.profiles.items[idx] = new_profile;
        } else {
            try self.profiles.append(self.allocator, new_profile);
        }

        return id;
    }

    pub fn remove(self: *MemoryProfileRepository, id: u64) Error!void {
        const idx = self.indexOf(id) orelse return Error.ProfileNotFound;
        const removed = self.profiles.orderedRemove(idx);
        removed.deinit(self.allocator);
    }

    pub fn get(self: *MemoryProfileRepository, id: u64) ?*profile.ConnectionProfile {
        const idx = self.indexOf(id) orelse return null;
        return &self.profiles.items[idx];
    }

    pub fn items(self: *MemoryProfileRepository) []profile.ConnectionProfile {
        return self.profiles.items;
    }

    fn createSeed(
        self: *MemoryProfileRepository,
        name: []const u8,
        host: []const u8,
        username: []const u8,
        group: []const u8,
    ) !void {
        var draft = profile.ProfileDraft{};
        draft.reset();
        profile.setBuffer(&draft.name, name);
        profile.setBuffer(&draft.host, host);
        profile.setBuffer(&draft.username, username);
        profile.setBuffer(&draft.group, group);
        _ = try self.upsertDraft(&draft);
    }

    fn clear(self: *MemoryProfileRepository) void {
        for (self.profiles.items) |item| {
            item.deinit(self.allocator);
        }
        self.profiles.clearRetainingCapacity();
    }

    fn takeId(self: *MemoryProfileRepository) u64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn indexOf(self: *MemoryProfileRepository, id: u64) ?usize {
        for (self.profiles.items, 0..) |item, i| {
            if (item.base.id == id) return i;
        }
        return null;
    }
};

const PersistedProfile = struct {
    id: u64,
    type: []const u8,
    name: []const u8,
    host: []const u8,
    port: u16,
    username: []const u8,
    auth_type: []const u8 = "Password",
    encrypted_password: []const u8 = "",
    private_key_path: []const u8 = "",
    encrypted_private_key_passphrase: []const u8 = "",
    group: []const u8 = "Default",
    sftp_enabled: bool = true,
};

fn authTypeFromString(value: []const u8) profile.AuthType {
    if (std.ascii.eqlIgnoreCase(value, "private_key") or std.ascii.eqlIgnoreCase(value, "Private Key")) return .private_key;
    if (std.ascii.eqlIgnoreCase(value, "agent")) return .agent;
    return .password;
}
