const dvui = @import("dvui");

const App = @import("../app/App.zig");
const theme = @import("theme.zig");

const panel_width: f32 = 380;
const panel_height: f32 = 176;
const field_height: f32 = 24;
const button_width: f32 = 72;
const button_height: f32 = 22;
const content_width: f32 = panel_width - 36;

pub fn show(app: *App, palette: theme.Palette) void {
    const window_rect = dvui.windowRect();
    const rect: dvui.Rect.Natural = .{
        .x = @max(12, @round((window_rect.w - panel_width) / 2)),
        .y = @max(24, @round((window_rect.h - panel_height) / 2)),
        .w = panel_width,
        .h = panel_height,
    };

    var panel: dvui.FloatingWidget = undefined;
    panel.init(@src(), .{}, theme.panel(.{
        .rect = .cast(rect),
        .min_size_content = .{ .w = rect.w, .h = rect.h },
        .max_size_content = .{ .w = rect.w, .h = rect.h },
        .padding = .all(0),
        .border = .all(1),
        .corner_radius = .all(8),
        .id_extra = 930_000,
    }, palette).override(.{
        .color_fill = palette.panel_bg,
        .color_border = palette.border,
    }));
    defer panel.deinit();
    dvui.focusSubwindow(panel.data().id, null);

    var content = dvui.box(@src(), .{ .dir = .vertical }, .{
        .min_size_content = .{ .w = rect.w, .h = rect.h },
        .max_size_content = .{ .w = rect.w, .h = rect.h },
        .padding = .{ .x = 12, .y = 7, .w = 12, .h = 7 },
        .id_extra = 930_001,
    });
    defer content.deinit();

    dvui.label(@src(), "Shellowo", .{}, .{
        .font = theme.textFont("Shellowo", 17),
        .color_text = palette.text,
        .margin = .{ .h = 8 },
        .id_extra = 930_002,
    });

    dvui.label(@src(), "Password:", .{}, .{
        .font = theme.textFont("Password:", 10),
        .color_text = palette.muted_text,
        .margin = .{ .h = 4 },
        .id_extra = 930_003,
    });

    const entered = passwordEntry(&app.unlock_password, content_width, palette, 930_004);

    var gap = dvui.box(@src(), .{}, .{
        .min_size_content = .height(button_height),
        .max_size_content = .height(button_height),
        .gravity_x = 1,
        .id_extra = 930_007,
        .padding = .all(0),
        .margin = .{ .y = 5 },
    });
    defer gap.deinit();

    if (theme.button(@src(), "Unlock", .{
        .min_size_content = .{ .w = button_width, .h = button_height },
        .max_size_content = .{ .w = button_width, .h = button_height },
        .padding = .all(0),
        .margin = .all(0),
        .id_extra = 930_006,
    }, palette, .{ .intent = .primary, .variant = .ghost, .font_size = theme.font_sizes.control }) or entered) {
        app.unlockProfiles();
    }

    clearFocusOnPanelBlankClick(&panel);
}

fn passwordEntry(buffer: []u8, width: f32, palette: theme.Palette, id_extra: usize) bool {
    var te = dvui.textEntry(@src(), .{
        .text = .{ .buffer = buffer },
        .password_char = "*",
    }, theme.panel(.{
        .min_size_content = .{ .w = width, .h = field_height },
        .max_size_content = .{ .w = width, .h = field_height },
        .font = theme.textFont("password", 10),
        .corner_radius = .all(5),
        .padding = .{ .x = 8, .y = 5, .w = 8, .h = 0 },
        .id_extra = id_extra,
    }, palette).override(.{
        .color_fill = palette.surface_bg,
        .color_border = palette.border,
    }));
    const entered = te.enter_pressed;
    te.deinit();
    return entered;
}

fn clearFocusOnPanelBlankClick(panel: *dvui.FloatingWidget) void {
    const rs = panel.data().rectScale();
    for (dvui.events()) |*event| {
        if (event.handled or event.evt != .mouse) continue;
        const mouse = event.evt.mouse;
        if (mouse.action != .focus) continue;
        if (mouse.floating_win != panel.data().id) continue;
        if (!rs.r.contains(mouse.p)) continue;
        event.handle(@src(), panel.data());
        dvui.focusWidget(null, null, event.num);
    }
}
