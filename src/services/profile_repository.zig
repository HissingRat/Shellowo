const std = @import("std");
const profile = @import("../core/profile.zig");
const secret_file = @import("../security/secret_file.zig");

pub const Error = error{
    ProfileNotFound,
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

        try self.createSeed(.ssh, "Local Lab", "127.0.0.1", "dev", "Default");
        try self.createSeed(.ftp, "Demo FTP", "files.example.test", "deploy", "Ops");
    }

    pub fn loadFromDisk(self: *MemoryProfileRepository, io: std.Io, path: []const u8) !void {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(bytes);

        const parsed = try std.json.parseFromSlice([]PersistedProfile, self.allocator, bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        self.clear();
        self.next_id = 1;
        for (parsed.value) |item| {
            const session_type: profile.SessionType = if (std.mem.eql(u8, item.@"type", "ftp")) .ftp else .ssh;
            var draft = profile.ProfileDraft{};
            draft.reset(session_type);
            draft.editing_id = item.id;
            draft.port = item.port;
            draft.sftp_enabled = item.sftp_enabled;
            draft.secure_ftp = item.secure;
            profile.setBuffer(&draft.name, item.name);
            profile.setBuffer(&draft.host, item.host);
            profile.setBuffer(&draft.username, item.username);
            profile.setBuffer(&draft.group, item.group);
            const decrypted_password = try secret_file.decrypt(self.allocator, item.encrypted_password);
            defer self.allocator.free(decrypted_password);
            profile.setBuffer(&draft.password, decrypted_password);
            _ = try self.upsertDraft(&draft);
            self.next_id = @max(self.next_id, item.id + 1);
        }
    }

    pub fn saveToDisk(self: *MemoryProfileRepository, io: std.Io, path: []const u8) !void {
        var persisted: std.ArrayList(PersistedProfile) = .empty;
        defer {
            for (persisted.items) |item| {
                self.allocator.free(item.encrypted_password);
            }
            persisted.deinit(self.allocator);
        }

        for (self.profiles.items) |item| {
            const b = item.base();
            const password = switch (item) {
                .ssh => |ssh| ssh.password,
                .ftp => |ftp| ftp.password,
            };
            const encrypted_password = try secret_file.encrypt(self.allocator, password);
            errdefer self.allocator.free(encrypted_password);
            try persisted.append(self.allocator, .{
                .id = b.id,
                .@"type" = @tagName(item.sessionType()),
                .name = b.name,
                .host = b.host,
                .port = b.port,
                .username = b.username,
                .encrypted_password = encrypted_password,
                .group = b.group,
                .sftp_enabled = if (item == .ssh) item.ssh.sftp_enabled else false,
                .secure = if (item == .ftp) item.ftp.secure else false,
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
        session_type: profile.SessionType,
        name: []const u8,
        host: []const u8,
        username: []const u8,
        group: []const u8,
    ) !void {
        var draft = profile.ProfileDraft{};
        draft.reset(session_type);
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
            if (item.base().id == id) return i;
        }
        return null;
    }
};

const PersistedProfile = struct {
    id: u64,
    @"type": []const u8,
    name: []const u8,
    host: []const u8,
    port: u16,
    username: []const u8,
    encrypted_password: []const u8 = "",
    group: []const u8 = "Default",
    sftp_enabled: bool = true,
    secure: bool = false,
};
