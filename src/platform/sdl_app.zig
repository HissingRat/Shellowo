const std = @import("std");
const dvui = @import("dvui");

const sdl = dvui.backend;
const c = sdl.c;

pub fn main(main_init: std.process.Init) !u8 {
    dvui.App.main_init = main_init;
    const app = dvui.App.get() orelse return error.DvuiAppNotDefined;
    const init_opts = app.config.get();

    if (@hasDecl(c, "SDL_SetMainReady")) c.SDL_SetMainReady();
    if (@hasDecl(c, "SDL_SetAppMetadata")) {
        _ = c.SDL_SetAppMetadata("Shellowo", "0.1", "app.shellowo.desktop");
    }

    var back = try sdl.initWindow(.{
        .io = init_opts.io orelse main_init.io,
        .environ_map = main_init.environ_map,
        .size = init_opts.size,
        .min_size = init_opts.min_size,
        .max_size = init_opts.max_size,
        .vsync = init_opts.vsync,
        .title = init_opts.title,
        .icon = init_opts.icon,
        .hidden = init_opts.hidden,
        .transparent = init_opts.transparent,
    });
    defer back.deinit();

    if (@hasDecl(c, "SDL_EnableScreenSaver")) {
        _ = c.SDL_EnableScreenSaver();
    }

    var win = try dvui.Window.init(@src(), main_init.gpa, back.backend(), init_opts.window_init_options);
    defer win.deinit();

    if (init_opts.window_init_options.open_flag != null) {
        dvui.log.warn("`open_flag` option has no effect in Shellowo SDL app. It is managed internally.", .{});
    }
    var window_open = true;
    win.open_flag = &window_open;

    if (app.initFn) |initFn| {
        try win.begin(win.frame_time_ns);
        try initFn(&win);
        _ = try win.end(.{});
    }
    applyConfiguredWindowSize(&back);
    defer if (app.deinitFn) |deinitFn| deinitFn();

    var interrupted = false;
    main_loop: while (window_open) {
        const nstime = win.beginWait(interrupted);
        try win.begin(nstime);

        try pumpEvents(&back, &win);

        const res = try app.frameFn();
        const end_micros = try win.end(.{});
        if (res != .ok) break :main_loop;

        const wait_event_micros = win.waitTime(end_micros);
        interrupted = try back.waitEventTimeout(wait_event_micros);
    }

    return 0;
}

fn pumpEvents(back: *sdl.SDLBackend, win: *dvui.Window) !void {
    var event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&event)) {
        if (event.type == c.SDL_EVENT_USER) continue;
        if (event.type == c.SDL_EVENT_DROP_BEGIN) {
            rootBeginFileDrag();
            continue;
        }
        if (event.type == c.SDL_EVENT_DROP_POSITION) {
            handleDropPosition(back, event);
            continue;
        }
        if (event.type == c.SDL_EVENT_DROP_FILE) {
            handleDropFile(back, event);
            continue;
        }
        if (event.type == c.SDL_EVENT_DROP_COMPLETE) {
            rootEndFileDrag();
            continue;
        }
        _ = try back.addEvent(win, event);
    }
}

fn handleDropFile(back: *sdl.SDLBackend, event: c.SDL_Event) void {
    const raw_path = event.drop.data orelse return;
    const pt = dropPoint(back, event);
    rootPushFileDrop(std.mem.span(raw_path), pt.x, pt.y);
}

fn handleDropPosition(back: *sdl.SDLBackend, event: c.SDL_Event) void {
    const pt = dropPoint(back, event);
    rootUpdateFileDrag(pt.x, pt.y);
}

fn dropPoint(back: *sdl.SDLBackend, event: c.SDL_Event) struct { x: f32, y: f32 } {
    const window_width = back.windowSize().w;
    const scale = if (window_width == 0) 1.0 else back.pixelSize().w / window_width;
    return .{ .x = event.drop.x * scale, .y = event.drop.y * scale };
}

fn rootPushFileDrop(path: []const u8, x: f32, y: f32) void {
    const root = @import("root");
    if (@hasDecl(root, "shellowoPushFileDrop")) {
        root.shellowoPushFileDrop(path, x, y);
    }
}

fn rootBeginFileDrag() void {
    const root = @import("root");
    if (@hasDecl(root, "shellowoBeginFileDrag")) {
        root.shellowoBeginFileDrag();
    }
}

fn rootUpdateFileDrag(x: f32, y: f32) void {
    const root = @import("root");
    if (@hasDecl(root, "shellowoUpdateFileDrag")) {
        root.shellowoUpdateFileDrag(x, y);
    }
}

fn rootEndFileDrag() void {
    const root = @import("root");
    if (@hasDecl(root, "shellowoEndFileDrag")) {
        root.shellowoEndFileDrag();
    }
}

fn applyConfiguredWindowSize(back: *sdl.SDLBackend) void {
    const root = @import("root");
    if (!@hasDecl(root, "shellowoInitialWindowSize")) return;
    const size = root.shellowoInitialWindowSize() orelse return;
    if (size.w <= 0 or size.h <= 0) return;
    if (std.math.isNan(size.w) or std.math.isNan(size.h)) return;
    _ = c.SDL_SetWindowSize(back.window, @intFromFloat(size.w), @intFromFloat(size.h));
}
