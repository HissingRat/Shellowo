const std = @import("std");
const ui_theme = @import("../ui/theme.zig");

pub const config_file_name = "owoConfig.json";
pub const default_download_dir_name = "owoDownloads";

pub const WindowSize = struct {
    w: f32 = 1180,
    h: f32 = 760,
};

pub const WorkspaceLayout = struct {
    sidebar_width: f32 = 190,
    file_panel_height: f32 = 230,
    local_file_width: f32 = 214,
};

pub const FileColumnWidths = struct {
    name: f32 = 220,
    size: f32 = 76,
    modified: f32 = 130,
    perm: f32 = 86,
    owner: f32 = 100,
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    config_path: []u8,
    download_path: []u8,
    theme_mode: ui_theme.ThemeMode = .dark,
    window_size: WindowSize = .{},
    workspace: WorkspaceLayout = .{},
    file_columns: FileColumnWidths = .{},

    pub fn load(allocator: std.mem.Allocator, io: ?std.Io) !Config {
        var config = try defaults(allocator, io);
        errdefer config.deinit();

        const active_io = io orelse return config;
        const bytes = readFileAllocPath(active_io, config.config_path, allocator, 128 * 1024) catch |err| switch (err) {
            error.FileNotFound => return config,
            else => return config,
        };
        defer allocator.free(bytes);

        const parsed = std.json.parseFromSlice(PersistedConfig, allocator, bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return config;
        defer parsed.deinit();

        applyPersisted(&config, parsed.value) catch return config;
        return config;
    }

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.config_path);
        self.allocator.free(self.download_path);
        self.* = undefined;
    }

    pub fn save(self: *const Config, io: ?std.Io) !void {
        const active_io = io orelse return;
        const persisted = PersistedConfig{
            .version = 1,
            .theme = self.theme_mode.label(),
            .window = self.window_size,
            .workspace = self.workspace,
            .file_columns = self.file_columns,
            .download_path = self.download_path,
        };

        const json = try std.json.Stringify.valueAlloc(self.allocator, persisted, .{ .whitespace = .indent_2 });
        defer self.allocator.free(json);

        try writeFilePath(active_io, self.config_path, json);
    }
};

const PersistedConfig = struct {
    version: u32 = 1,
    theme: ?[]const u8 = null,
    window: ?WindowSize = null,
    workspace: ?WorkspaceLayout = null,
    file_columns: ?FileColumnWidths = null,
    download_path: ?[]const u8 = null,
};

fn defaults(allocator: std.mem.Allocator, io: ?std.Io) !Config {
    return .{
        .allocator = allocator,
        .config_path = try exeSiblingPath(allocator, io, config_file_name),
        .download_path = try exeSiblingPath(allocator, io, default_download_dir_name),
    };
}

fn applyPersisted(config: *Config, persisted: PersistedConfig) !void {
    if (persisted.theme) |theme_label| {
        config.theme_mode = themeModeFromLabel(theme_label) orelse config.theme_mode;
    }
    if (persisted.window) |window| {
        config.window_size = .{
            .w = positiveOrDefault(window.w, config.window_size.w),
            .h = positiveOrDefault(window.h, config.window_size.h),
        };
    }
    if (persisted.workspace) |workspace| {
        config.workspace = .{
            .sidebar_width = positiveOrDefault(workspace.sidebar_width, config.workspace.sidebar_width),
            .file_panel_height = positiveOrDefault(workspace.file_panel_height, config.workspace.file_panel_height),
            .local_file_width = positiveOrDefault(workspace.local_file_width, config.workspace.local_file_width),
        };
    }
    if (persisted.file_columns) |columns| {
        config.file_columns = .{
            .name = positiveOrDefault(columns.name, config.file_columns.name),
            .size = positiveOrDefault(columns.size, config.file_columns.size),
            .modified = positiveOrDefault(columns.modified, config.file_columns.modified),
            .perm = positiveOrDefault(columns.perm, config.file_columns.perm),
            .owner = positiveOrDefault(columns.owner, config.file_columns.owner),
        };
    }
    if (persisted.download_path) |path| {
        if (path.len > 0) {
            const owned = try config.allocator.dupe(u8, path);
            config.allocator.free(config.download_path);
            config.download_path = owned;
        }
    }
}

fn exeSiblingPath(allocator: std.mem.Allocator, io: ?std.Io, name: []const u8) ![]u8 {
    const active_io = io orelse return allocator.dupe(u8, name);
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = std.process.executableDirPath(active_io, &exe_buf) catch return allocator.dupe(u8, name);
    return std.fs.path.join(allocator, &.{ exe_buf[0..len], name });
}

fn readFileAllocPath(io: std.Io, path: []const u8, allocator: std.mem.Allocator, max_size: usize) ![]u8 {
    if (!std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_size));
    }

    const dir_path = std.fs.path.dirname(path) orelse return error.FileNotFound;
    const file_name = std.fs.path.basename(path);
    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{});
    defer dir.close(io);
    return dir.readFileAlloc(io, file_name, allocator, .limited(max_size));
}

fn writeFilePath(io: std.Io, path: []const u8, data: []const u8) !void {
    if (!std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
    }

    const dir_path = std.fs.path.dirname(path) orelse return error.FileNotFound;
    const file_name = std.fs.path.basename(path);
    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{});
    defer dir.close(io);
    return dir.writeFile(io, .{ .sub_path = file_name, .data = data });
}

fn positiveOrDefault(value: f32, default_value: f32) f32 {
    if (!std.math.isFinite(value) or value <= 0) return default_value;
    return value;
}

fn themeModeFromLabel(label: []const u8) ?ui_theme.ThemeMode {
    if (std.ascii.eqlIgnoreCase(label, "dark")) return .dark;
    if (std.ascii.eqlIgnoreCase(label, "light")) return .light;
    return null;
}

test "theme labels parse case insensitively" {
    try std.testing.expectEqual(ui_theme.ThemeMode.dark, themeModeFromLabel("Dark").?);
    try std.testing.expectEqual(ui_theme.ThemeMode.light, themeModeFromLabel("light").?);
}
