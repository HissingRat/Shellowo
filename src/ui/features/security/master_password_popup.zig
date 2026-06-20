const dvui = @import("dvui");

const App = @import("../../../app/App.zig");
const theme = @import("../../theme.zig");

pub const Mode = enum {
    none,
    enable,
    disable,
};

pub const Action = enum {
    none,
    close,
    enabled,
    disabled,
};

const row_height: f32 = 26;
const field_height: f32 = 28;
const label_width: f32 = 86;
const field_width: f32 = 260;

pub fn show(app: *App, mode: Mode, palette: theme.Palette, id_extra: usize) Action {
    if (mode == .none) return .none;

    const disable_mode = mode == .disable;
    const window_rect = dvui.windowRect();
    const popup_w = @min(@as(f32, 400), @max(@as(f32, 340), window_rect.w - 48));
    const popup_h: f32 = if (disable_mode) 144 + 10 else 178 + 10;
    const rect: dvui.Rect.Natural = .{
        .x = @max(12, @round((window_rect.w - popup_w) / 2)),
        .y = @max(40, @round((window_rect.h - popup_h) / 2)),
        .w = popup_w,
        .h = popup_h,
    };

    var panel: dvui.FloatingWidget = undefined;
    panel.init(@src(), .{}, theme.popup(.{
        .rect = .cast(rect),
        .min_size_content = .{ .w = rect.w, .h = rect.h },
        .max_size_content = .{ .w = rect.w, .h = rect.h },
        .padding = .{ .x = 12, .y = 10, .w = 12, .h = 10 },
        .border = .all(1),
        .corner_radius = .all(8),
        .id_extra = id_extra,
    }, palette));
    defer panel.deinit();
    dvui.focusSubwindow(panel.data().id, null);

    const title = if (disable_mode) "Disable Master Password" else "Enable Master Password";
    dvui.label(@src(), "{s}", .{title}, .{
        .font = theme.textFont(title, 14),
        .color_text = palette.text,
        .margin = .{ .h = 8 },
        .id_extra = id_extra + 1,
    });

    if (disable_mode) {
        setupRow("Password", &app.master_password_disable, palette, id_extra + 10);
    } else {
        setupRow("Password", &app.master_password_new, palette, id_extra + 10);
        setupRow("Confirm", &app.master_password_confirm, palette, id_extra + 20);
    }

    var actions = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .gravity_x = 1,
        .margin = .{ .y = 10 },
        .id_extra = id_extra + 30,
    });
    defer actions.deinit();

    if (theme.button(@src(), "Cancel", .{
        .min_size_content = .{ .w = 64, .h = 20 },
        .margin = .{ .x = 4 },
        .id_extra = id_extra + 31,
    }, palette, .{ .variant = .ghost, .font_size = theme.font_sizes.control })) {
        app.cancelMasterPasswordSetup();
        return .close;
    }

    if (theme.button(@src(), "Done", .{
        .min_size_content = .{ .w = 64, .h = 20 },
        .margin = .{ .x = 4 },
        .id_extra = id_extra + 32,
    }, palette, .{ .intent = .primary, .variant = .ghost, .font_size = theme.font_sizes.control })) {
        if (disable_mode) {
            app.disableMasterPassword();
            return if (!app.masterPasswordEnabled()) .disabled else .none;
        }

        app.enableMasterPassword();
        return if (app.masterPasswordEnabled()) .enabled else .none;
    }

    return .none;
}

fn setupRow(label: []const u8, buffer: []u8, palette: theme.Palette, id_extra: usize) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .height(row_height),
        .max_size_content = .height(row_height),
        .padding = .all(0),
        .id_extra = id_extra,
    });
    defer row.deinit();

    fieldLabel(label, palette, id_extra + 1);
    _ = passwordEntry(buffer, field_width, palette, id_extra + 2);
}

fn fieldLabel(label: []const u8, palette: theme.Palette, id_extra: usize) void {
    var slot = dvui.box(@src(), .{}, .{
        .gravity_y = 0.5,
        .min_size_content = .width(label_width),
        .max_size_content = .width(label_width),
        .padding = .all(0),
        .margin = .all(0),
        .id_extra = id_extra,
    });
    defer slot.deinit();

    dvui.label(@src(), "{s}", .{label}, .{
        .font = theme.textFont(label, 10),
        .color_text = palette.muted_text,
        .gravity_y = 0.5,
        .id_extra = id_extra + 1,
    });
}

fn passwordEntry(buffer: []u8, width: f32, palette: theme.Palette, id_extra: usize) bool {
    var te: theme.TextEntry = undefined;
    theme.textEntry(@src(), &te, .{
        .text = .{ .buffer = buffer },
        .password_char = "*",
    }, theme.panel(.{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = @max(80, width), .h = field_height },
        .max_size_content = .{ .w = @max(80, width), .h = field_height },
        .font = theme.textFont("password", 10),
        .corner_radius = .all(5),
        .padding = .{ .x = 8, .y = 4, .w = 8, .h = 0 },
        .margin = .all(0),
        .id_extra = id_extra,
    }, palette).override(.{
        .color_fill = palette.surface_bg,
        .color_border = palette.border,
    }), palette);
    const entered = te.enterPressed();
    te.deinit();
    return entered;
}
