const std = @import("std");
const predictive = @import("../core/terminal/predictive.zig");
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

pub const TerminalPredictionConfig = struct {
    mode: predictive.PredictionMode = .auto,

    pub fn toCore(self: TerminalPredictionConfig) predictive.PredictionConfig {
        var config: predictive.PredictionConfig = .{};
        config.enabled = self.mode != .off;
        config.mode = self.mode;
        return config;
    }
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    config_path: []u8,
    download_path: []u8,
    theme_mode: ui_theme.ThemeMode = .dark,
    window_size: WindowSize = .{},
    workspace: WorkspaceLayout = .{},
    file_columns: FileColumnWidths = .{},
    terminal_prediction: TerminalPredictionConfig = .{},

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
        const persisted = SavedConfig{
            .version = 1,
            .theme = self.theme_mode.label(),
            .window = self.window_size,
            .workspace = self.workspace,
            .file_columns = self.file_columns,
            .terminal_prediction = .{
                .mode = predictionModeLabel(self.terminal_prediction.mode),
            },
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
    terminal_prediction: ?PersistedPredictionConfig = null,
    download_path: ?[]const u8 = null,
};

const SavedConfig = struct {
    version: u32,
    theme: []const u8,
    window: WindowSize,
    workspace: WorkspaceLayout,
    file_columns: FileColumnWidths,
    terminal_prediction: SavedPredictionConfig,
    download_path: []const u8,
};

const SavedPredictionConfig = struct {
    mode: []const u8,
};

const PersistedPredictionConfig = struct {
    enabled: ?bool = null,
    mode: ?[]const u8 = null,
};

fn defaults(allocator: std.mem.Allocator, io: ?std.Io) !Config {
    return .{
        .allocator = allocator,
        .config_path = try runtimeDataPath(allocator, io, config_file_name),
        .download_path = try runtimeDataPath(allocator, io, default_download_dir_name),
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
    if (persisted.terminal_prediction) |prediction| {
        const persisted_mode = if (prediction.mode) |mode_label| predictionModeFromLabel(mode_label) else null;
        const enabled = prediction.enabled orelse (persisted_mode != .off);
        config.terminal_prediction.mode = if (enabled and persisted_mode != .off) .auto else .off;
    }
    canonicalizePredictionConfig(&config.terminal_prediction);
}

fn runtimeDataPath(allocator: std.mem.Allocator, io: ?std.Io, name: []const u8) ![]u8 {
    const active_io = io orelse return allocator.dupe(u8, name);
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = std.process.executableDirPath(active_io, &exe_buf) catch return allocator.dupe(u8, name);
    if (isMacAppExecutableDir(exe_buf[0..len])) return allocator.dupe(u8, name);
    return std.fs.path.join(allocator, &.{ exe_buf[0..len], name });
}

fn isMacAppExecutableDir(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".app/Contents/MacOS");
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

pub fn predictionModeLabel(mode: predictive.PredictionMode) []const u8 {
    return switch (mode) {
        .off => "off",
        .safe => "safe",
        .auto => "auto",
        .aggressive => "aggressive",
    };
}

pub fn predictionModeFromLabel(label: []const u8) ?predictive.PredictionMode {
    if (std.ascii.eqlIgnoreCase(label, "off")) return .off;
    if (std.ascii.eqlIgnoreCase(label, "safe")) return .safe;
    if (std.ascii.eqlIgnoreCase(label, "auto")) return .auto;
    if (std.ascii.eqlIgnoreCase(label, "aggressive")) return .aggressive;
    return null;
}

fn canonicalizePredictionConfig(config: *TerminalPredictionConfig) void {
    config.mode = if (config.mode == .off) .off else .auto;
}

test "theme labels parse case insensitively" {
    try std.testing.expectEqual(ui_theme.ThemeMode.dark, themeModeFromLabel("Dark").?);
    try std.testing.expectEqual(ui_theme.ThemeMode.light, themeModeFromLabel("light").?);
}

test "mac app executable directory uses writable runtime data paths" {
    try std.testing.expect(isMacAppExecutableDir("/Applications/Shellowo.app/Contents/MacOS"));
    try std.testing.expect(!isMacAppExecutableDir("/tmp/zig-out/bin"));
}

test "prediction settings migrate to fixed auto defaults" {
    var config = try defaults(std.testing.allocator, null);
    defer config.deinit();

    const legacy_json =
        \\{
        \\  "terminal_prediction": {
        \\    "enabled": true,
        \\    "mode": "aggressive",
        \\    "predict_in_alt_screen": false,
        \\    "predict_arrow_keys": false,
        \\    "rollback_threshold": 32,
        \\    "cooldown_ms": 2000,
        \\    "output_pause_ms": 1200,
        \\    "output_change_threshold": 384
        \\  }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(PersistedConfig, std.testing.allocator, legacy_json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    try applyPersisted(&config, parsed.value);

    try std.testing.expectEqual(predictive.PredictionMode.auto, config.terminal_prediction.mode);
    const core = config.terminal_prediction.toCore();
    try std.testing.expect(core.enabled);
    try std.testing.expect(core.predict_in_alt_screen);
    try std.testing.expect(core.predict_arrow_keys);
    try std.testing.expectEqual(@as(u64, 250), core.cooldown_ms);
    try std.testing.expectEqual(@as(u64, 150), core.output_pause_ms);
    try std.testing.expectEqual(@as(u32, 96), core.output_change_threshold);
    try std.testing.expectEqual(@as(u32, 64), core.rollback_threshold);
}

test "saved prediction config contains only the user-facing mode" {
    const saved = SavedPredictionConfig{ .mode = "auto" };
    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, saved, .{});
    defer std.testing.allocator.free(json);

    try std.testing.expectEqualStrings("{\"mode\":\"auto\"}", json);
    try std.testing.expect(std.mem.indexOf(u8, json, "predict_") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "threshold") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "cooldown") == null);
}
