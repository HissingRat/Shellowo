const builtin = @import("builtin");
const dvui = @import("dvui");

const c = dvui.backend.c;

pub const titlebar_height: f32 = 33;
pub const macos_traffic_light_inset: f32 = 88;
pub const macos_traffic_light_horizontal_offset: f64 = 3;
pub const macos_traffic_light_vertical_offset: f64 = 3;

pub const Action = enum {
    minimize,
    toggle_maximize,
    show_system_menu,
    close,
};

pub const Controller = struct {
    window: *c.SDL_Window,
    drag_rects: [8]dvui.Rect.Natural = undefined,
    drag_rect_count: usize = 0,
    close_requested: bool = false,

    pub fn activate(self: *Controller) !void {
        active_controller = self;

        switch (builtin.os.tag) {
            .macos => {
                const properties = c.SDL_GetWindowProperties(self.window);
                const ns_window = c.SDL_GetPointerProperty(properties, c.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, null);
                if (ns_window == null) return error.MissingCocoaWindow;
                shellowo_macos_set_close_callback(shellowo_macos_request_close);
                shellowo_macos_configure_titlebar(ns_window);
            },
            .windows => {
                if (!c.SDL_SetWindowBordered(self.window, false)) return error.WindowBorderConfigurationFailed;
                const properties = c.SDL_GetWindowProperties(self.window);
                const hwnd = c.SDL_GetPointerProperty(properties, c.SDL_PROP_WINDOW_WIN32_HWND_POINTER, null);
                if (hwnd == null) return error.MissingWin32Window;
                shellowo_windows_configure_chrome(hwnd);
            },
            else => return,
        }

        if (!c.SDL_SetWindowHitTest(self.window, hitTest, self)) {
            return error.WindowHitTestConfigurationFailed;
        }
    }

    pub fn deactivate(self: *Controller) void {
        if (active_controller == self) active_controller = null;
        if (builtin.os.tag == .macos) shellowo_macos_set_close_callback(null);
        _ = c.SDL_SetWindowHitTest(self.window, null, null);
    }

    pub fn windowShown(self: *Controller) void {
        if (builtin.os.tag != .macos) return;
        const ns_window = cocoaWindow(self.window);
        if (ns_window == null) return;
        shellowo_macos_position_traffic_lights(
            ns_window,
            macos_traffic_light_horizontal_offset,
            macos_traffic_light_vertical_offset,
        );
    }

    pub fn handleEvent(self: *Controller, event: *const c.SDL_Event) bool {
        if (builtin.os.tag == .windows and event.type == c.SDL_EVENT_MOUSE_BUTTON_DOWN) {
            const mouse = event.button;
            const x: f32 = mouse.x;
            const y: f32 = mouse.y;
            if (self.isDraggablePoint(x, y)) {
                if (mouse.button == c.SDL_BUTTON_RIGHT) {
                    _ = c.SDL_ShowWindowSystemMenu(self.window, @intFromFloat(x), @intFromFloat(y));
                    return true;
                }
                if (mouse.button == c.SDL_BUTTON_LEFT and mouse.clicks >= 2) {
                    perform(.toggle_maximize);
                    return true;
                }
            }
        }

        if (builtin.os.tag != .macos) return false;
        const event_window = c.SDL_GetWindowFromEvent(event) orelse return false;
        if (event_window != self.window) return false;
        const ns_window = cocoaWindow(self.window);
        if (ns_window == null) return false;
        if (isMacosChromeResetEvent(event.type)) {
            shellowo_macos_refresh_titlebar(
                ns_window,
                macos_traffic_light_horizontal_offset,
                macos_traffic_light_vertical_offset,
            );
        } else if (isMacosTrafficLightRelayoutEvent(event.type)) {
            shellowo_macos_position_traffic_lights(
                ns_window,
                macos_traffic_light_horizontal_offset,
                macos_traffic_light_vertical_offset,
            );
        }
        return false;
    }

    pub fn takeCloseRequested(self: *Controller) bool {
        const requested = self.close_requested;
        self.close_requested = false;
        return requested;
    }

    fn isDraggablePoint(self: *const Controller, x: f32, y: f32) bool {
        for (self.drag_rects[0..self.drag_rect_count]) |rect| {
            if (pointInRect(rect, x, y)) return true;
        }
        return false;
    }
};

var active_controller: ?*Controller = null;

fn shellowo_macos_request_close() callconv(.c) void {
    const controller = active_controller orelse return;
    controller.close_requested = true;
}

pub fn integratedTitlebar() bool {
    return switch (builtin.os.tag) {
        .macos, .windows => true,
        else => false,
    };
}

pub fn drawsWindowControls() bool {
    return builtin.os.tag == .windows;
}

pub fn leadingInset() f32 {
    return if (builtin.os.tag == .macos) macos_traffic_light_inset else 0;
}

pub fn clearTitlebarFrame() void {
    const controller = active_controller orelse return;
    controller.drag_rect_count = 0;
}

pub fn addTitlebarDragRect(rect_scale: dvui.RectScale) void {
    const controller = active_controller orelse return;
    if (controller.drag_rect_count >= controller.drag_rects.len) return;
    controller.drag_rects[controller.drag_rect_count] = hitTestRect(rect_scale.r, rect_scale.s);
    controller.drag_rect_count += 1;
}

pub fn perform(action: Action) void {
    const controller = active_controller orelse return;
    switch (action) {
        .minimize => _ = c.SDL_MinimizeWindow(controller.window),
        .toggle_maximize => {
            if (isMaximized()) {
                _ = c.SDL_RestoreWindow(controller.window);
            } else {
                _ = c.SDL_MaximizeWindow(controller.window);
            }
        },
        .show_system_menu => _ = c.SDL_ShowWindowSystemMenu(controller.window, 8, @intFromFloat(titlebar_height)),
        .close => controller.close_requested = true,
    }
}

pub fn isMaximized() bool {
    const controller = active_controller orelse return false;
    return (c.SDL_GetWindowFlags(controller.window) & c.SDL_WINDOW_MAXIMIZED) != 0;
}

fn hitTest(
    _: ?*c.SDL_Window,
    area: [*c]const c.SDL_Point,
    data: ?*anyopaque,
) callconv(.c) c.SDL_HitTestResult {
    const raw = data orelse return @intCast(c.SDL_HITTEST_NORMAL);
    const controller: *Controller = @ptrCast(@alignCast(raw));
    const point = area[0];

    if (builtin.os.tag == .windows and !isMaximizedWindow(controller.window)) {
        if (resizeHitTest(controller.window, point)) |result| return result;
    }

    const x: f32 = @floatFromInt(point.x);
    const y: f32 = @floatFromInt(point.y);
    if (controller.isDraggablePoint(x, y)) {
        return @intCast(c.SDL_HITTEST_DRAGGABLE);
    }
    return @intCast(c.SDL_HITTEST_NORMAL);
}

fn resizeHitTest(window: *c.SDL_Window, point: c.SDL_Point) ?c.SDL_HitTestResult {
    var width: c_int = 0;
    var height: c_int = 0;
    if (!c.SDL_GetWindowSize(window, &width, &height)) return null;

    const edge: c_int = 6;
    const left = point.x < edge;
    const right = point.x >= width - edge;
    const top = point.y < edge;
    const bottom = point.y >= height - edge;

    if (top and left) return @intCast(c.SDL_HITTEST_RESIZE_TOPLEFT);
    if (top and right) return @intCast(c.SDL_HITTEST_RESIZE_TOPRIGHT);
    if (bottom and left) return @intCast(c.SDL_HITTEST_RESIZE_BOTTOMLEFT);
    if (bottom and right) return @intCast(c.SDL_HITTEST_RESIZE_BOTTOMRIGHT);
    if (top) return @intCast(c.SDL_HITTEST_RESIZE_TOP);
    if (bottom) return @intCast(c.SDL_HITTEST_RESIZE_BOTTOM);
    if (left) return @intCast(c.SDL_HITTEST_RESIZE_LEFT);
    if (right) return @intCast(c.SDL_HITTEST_RESIZE_RIGHT);
    return null;
}

fn isMaximizedWindow(window: *c.SDL_Window) bool {
    return (c.SDL_GetWindowFlags(window) & c.SDL_WINDOW_MAXIMIZED) != 0;
}

fn pointInRect(rect: dvui.Rect.Natural, x: f32, y: f32) bool {
    return x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h;
}

fn hitTestRect(rect: dvui.Rect.Physical, scale_value: f32) dvui.Rect.Natural {
    if (builtin.os.tag == .windows) {
        return .{
            .x = rect.x,
            .y = rect.y,
            .w = rect.w,
            .h = rect.h,
        };
    }
    const scale = if (scale_value > 0) scale_value else 1;
    return .{
        .x = rect.x / scale,
        .y = rect.y / scale,
        .w = rect.w / scale,
        .h = rect.h / scale,
    };
}

fn cocoaWindow(window: *c.SDL_Window) ?*anyopaque {
    const properties = c.SDL_GetWindowProperties(window);
    return c.SDL_GetPointerProperty(properties, c.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, null);
}

fn isMacosChromeResetEvent(event_type: u32) bool {
    return event_type == c.SDL_EVENT_WINDOW_MAXIMIZED or
        event_type == c.SDL_EVENT_WINDOW_RESTORED or
        event_type == c.SDL_EVENT_WINDOW_ENTER_FULLSCREEN or
        event_type == c.SDL_EVENT_WINDOW_LEAVE_FULLSCREEN;
}

fn isMacosTrafficLightRelayoutEvent(event_type: u32) bool {
    return event_type == c.SDL_EVENT_WINDOW_RESIZED or
        event_type == c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED;
}

extern fn shellowo_macos_configure_titlebar(ns_window: ?*anyopaque) void;
extern fn shellowo_macos_set_close_callback(callback: ?*const fn () callconv(.c) void) void;
extern fn shellowo_macos_position_traffic_lights(
    ns_window: ?*anyopaque,
    horizontal_offset: f64,
    vertical_offset: f64,
) void;
extern fn shellowo_macos_refresh_titlebar(
    ns_window: ?*anyopaque,
    horizontal_offset: f64,
    vertical_offset: f64,
) void;
extern fn shellowo_windows_configure_chrome(window_pointer: ?*anyopaque) void;
