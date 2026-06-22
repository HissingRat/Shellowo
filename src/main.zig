const std = @import("std");
const dvui = @import("dvui");
const App = @import("app/App.zig");
const bootstrap = @import("bootstrap.zig");
const libssh2_backend = @import("backends/ssh/libssh2.zig");
const sdl_app = @import("platform/sdl_app.zig");
const ui_fonts = @import("ui/fonts.zig");
const screen = @import("ui/features/app_shell/screen.zig");

const min_idle_fps: i32 = 4;
const min_idle_frame_interval_us: i32 = std.time.us_per_s / min_idle_fps;

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

pub const main = sdl_app.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{
    .log_level = .warn,
    .logFn = dvui.App.logFn,
};

var gpa_instance: std.heap.DebugAllocator(.{}) = .init;
var app_state: ?App = null;
var runtime_backends: ?bootstrap.RuntimeBackends = null;

fn appInit(window: *dvui.Window) !void {
    const init = dvui.App.main_init orelse return error.MissingProcessInit;
    try libssh2_backend.init();
    ui_fonts.loadEmbedded(window);
    runtime_backends = bootstrap.RuntimeBackends.init(gpa_instance.allocator());
    app_state = App.initPersistent(gpa_instance.allocator(), init.io, runtime_backends.?.dependencies()) catch |err| {
        runtime_backends = null;
        libssh2_backend.deinit();
        return err;
    };
}

fn appDeinit() void {
    ui_fonts.deinit();
    if (app_state) |*app| {
        app.deinit();
    }
    app_state = null;
    runtime_backends = null;
    libssh2_backend.deinit();
    _ = gpa_instance.deinit();
}

fn appFrame() !dvui.App.Result {
    app_state.?.beginNativeFrame();
    const result = try screen.frame(&app_state.?);
    app_state.?.clearNativeEvents();
    maintainMinIdleRefreshRate();
    return result;
}

pub fn shellowoPushFileDrop(path: []const u8, x: f32, y: f32) void {
    if (app_state) |*app| {
        app.pushFileDrop(path, x, y) catch {
            app.message = "File drop failed";
        };
    }
}

pub fn shellowoBeginFileDrag() void {
    if (app_state) |*app| {
        app.beginFileDrag();
    }
}

pub fn shellowoUpdateFileDrag(x: f32, y: f32) void {
    if (app_state) |*app| {
        app.updateFileDrag(x, y);
    }
}

pub fn shellowoEndFileDrag() void {
    if (app_state) |*app| {
        app.endFileDrag();
    }
}

pub fn shellowoRequestWindowClose() void {
    if (app_state) |*app| app.requestWindowClose();
}

pub fn shellowoTakeWindowCloseApproved() bool {
    if (app_state) |*app| return app.takeWindowCloseApproved();
    return true;
}

pub fn shellowoInitialWindowSize() ?dvui.Size {
    if (app_state) |*app| {
        return .{
            .w = app.config.window_size.w,
            .h = app.config.window_size.h,
        };
    }
    return null;
}

fn maintainMinIdleRefreshRate() void {
    const timer_id = dvui.currentWindow().data().id.update("shellowo_min_idle_refresh");
    if (dvui.timerDoneOrNone(timer_id)) {
        dvui.timer(timer_id, min_idle_frame_interval_us);
    }
}
