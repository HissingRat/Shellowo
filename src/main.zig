const std = @import("std");
const dvui = @import("dvui");
const App = @import("app/App.zig");
const libssh2_backend = @import("protocols/libssh2_backend.zig");
const ui_theme = @import("ui/theme.zig");
const screen = @import("ui/screen.zig");

const zed_font_bytes = @embedFile("shellowo-zed-font");
const cjk_font_bytes = @embedFile("shellowo-cjk-font");

pub const dvui_app: dvui.App = .{
    .config = .{
        .options = .{
            .size = .{ .w = 1180, .h = 760 },
            .min_size = .{ .w = 920, .h = 560 },
            .title = "Shellowo",
        },
    },
    .initFn = appInit,
    .deinitFn = appDeinit,
    .frameFn = appFrame,
};

pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{
    .log_level = .warn,
    .logFn = dvui.App.logFn,
};

var gpa_instance: std.heap.DebugAllocator(.{}) = .init;
var app_state: ?App = null;

fn appInit(window: *dvui.Window) !void {
    const init = dvui.App.main_init orelse return error.MissingProcessInit;
    try libssh2_backend.init();
    loadEmbeddedFonts(window);
    app_state = App.initPersistent(gpa_instance.allocator(), init.io) catch |err| {
        libssh2_backend.deinit();
        return err;
    };
}

fn appDeinit() void {
    if (app_state) |*app| {
        app.deinit();
    }
    app_state = null;
    libssh2_backend.deinit();
    _ = gpa_instance.deinit();
}

fn appFrame() !dvui.App.Result {
    return screen.frame(&app_state.?);
}

fn loadEmbeddedFonts(window: *dvui.Window) void {
    var zed_loaded = true;
    window.addFont(ui_theme.cjk_font_family, cjk_font_bytes, null) catch return;
    window.addFont(ui_theme.zed_font_family, zed_font_bytes, null) catch {
        zed_loaded = false;
    };

    var current_theme = window.theme;
    const primary_family = if (zed_loaded) ui_theme.zed_font_family else ui_theme.cjk_font_family;
    current_theme.font_body = current_theme.font_body.withFamily(primary_family).withSize(ui_theme.font_sizes.body);
    current_theme.font_heading = current_theme.font_heading.withFamily(primary_family).withWeight(.normal).withSize(ui_theme.font_sizes.heading);
    current_theme.font_title = current_theme.font_title.withFamily(primary_family).withWeight(.normal).withSize(ui_theme.font_sizes.title);
    current_theme.font_mono = current_theme.font_mono.withFamily(primary_family).withSize(ui_theme.font_sizes.body);
    window.themeSet(current_theme);
}
