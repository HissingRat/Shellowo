const dvui = @import("dvui");
const profile = @import("../../../core/profile.zig");
const App = @import("../../../app/App.zig");
const theme = @import("../../theme.zig");

const panel_width: f32 = 520;
const panel_height: f32 = 540;
const header_height: f32 = 36;
const footer_height: f32 = 44;
const separator_height: f32 = 1;
const min_content_height: f32 = 120;
const form_font_size: f32 = 11;
const control_font_size: f32 = 11;
const field_height: f32 = 20;

pub fn show(app: *App, palette: theme.Palette) void {
    const window_rect = dvui.windowRect();
    const popup_w = @min(panel_width, @max(@as(f32, 360), window_rect.w - 48));
    const available_h = @max(@as(f32, 180), window_rect.h - 24);
    const popup_h = @min(panel_height, available_h);
    const rect: dvui.Rect.Natural = .{
        .x = @max(12, @round((window_rect.w - popup_w) / 2)),
        .y = @max(12, @round((window_rect.h - popup_h) / 2)),
        .w = popup_w,
        .h = popup_h,
    };

    var panel: dvui.FloatingWidget = undefined;
    panel.init(@src(), .{}, theme.panel(.{
        .rect = .cast(rect),
        .min_size_content = .{ .w = rect.w, .h = rect.h },
        .max_size_content = .{ .w = rect.w, .h = rect.h },
        .padding = .all(0),
        .border = .all(1),
        .corner_radius = .all(8),
        .id_extra = 50_002,
    }, palette).override(.{
        .color_fill = palette.panel_bg,
        .color_border = palette.border_subtle,
    }));
    defer panel.deinit();
    dvui.focusSubwindow(panel.data().id, null);

    header(palette);
    separator(palette, 50_012);
    form(app, palette, @max(min_content_height, rect.h - header_height - footer_height - separator_height * 2));
    separator(palette, 50_089);
    footer(app, palette);
}

fn header(palette: theme.Palette) void {
    var box = dvui.box(@src(), .{ .dir = .horizontal }, theme.topbar(.{
        .expand = .horizontal,
        .min_size_content = .height(header_height),
        .padding = .{ .x = 14, .y = 0, .w = 14, .h = 0 },
        .corner_radius = .{ .x = 8, .y = 8, .w = 0, .h = 0 },
        .id_extra = 50_010,
    }, palette).override(.{
        .color_fill = palette.surface_bg,
    }));
    defer box.deinit();

    dvui.label(@src(), "Configuration", .{}, .{
        .font = theme.cjkFont(13),
        .color_text = palette.text,
        .gravity_y = 0.5,
        .id_extra = 50_011,
    });
}

fn separator(palette: theme.Palette, id_extra: usize) void {
    var line = dvui.box(@src(), .{}, theme.panel(.{
        .expand = .horizontal,
        .min_size_content = .height(1),
        .max_size_content = .height(1),
        .padding = .all(0),
        .margin = .all(0),
        .id_extra = id_extra,
    }, palette).override(.{
        .color_fill = palette.border_subtle,
        .color_border = palette.border_subtle,
    }));
    defer line.deinit();
}

fn form(app: *App, palette: theme.Palette, content_height: f32) void {
    var scroll = dvui.scrollArea(@src(), .{
        .vertical = .auto,
        .vertical_bar = .auto_overlay,
        .horizontal = .none,
        .process_events_after = true,
    }, theme.panel(.{
        .expand = .horizontal,
        .min_size_content = .height(content_height),
        .max_size_content = .height(content_height),
        .padding = .all(0),
        .corner_radius = .all(0),
        .id_extra = 50_020,
    }, palette).override(.{
        .color_fill = palette.panel_bg,
        .color_border = palette.border_subtle,
    }));
    defer scroll.deinit();

    var content = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .{ .x = 14, .y = 10, .w = 14, .h = 10 },
        .id_extra = 50_021,
    });
    defer content.deinit();

    textField("Name", &app.draft.name, 50_030, palette);
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 50_040 });
        defer row.deinit();
        textFieldSized("Host", &app.draft.host, 50_041, palette, true);
        portField(app, palette);
    }
    textField("Group", &app.draft.group, 50_050, palette);
    textField("Username", &app.draft.username, 50_060, palette);
    authSelector(app, palette);
    switch (app.draft.auth_type) {
        .password => textField("Password", &app.draft.password, 50_070, palette),
        .private_key => {
            privateKeyPathField(app, palette);
            textField("Key Passphrase", &app.draft.private_key_passphrase, 50_075, palette);
        },
        .agent => authNotice("Uses SSH agent authentication when supported by the runtime.", 50_077, palette),
    }

    _ = theme.checkbox(@src(), &app.draft.sftp_enabled, "Enable SFTP", palette, .{
        .id_extra = 50_080,
        .font_size = form_font_size,
    });
}

fn authSelector(app: *App, palette: theme.Palette) void {
    var cell = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .margin = .{ .y = 3, .h = 3 },
        .id_extra = 50_065,
    });
    defer cell.deinit();

    dvui.label(@src(), "Authentication", .{}, .{
        .color_text = palette.muted_text,
        .font = theme.textFont("Authentication", form_font_size),
        .id_extra = 50_066,
    });

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 50_067 });
    defer row.deinit();

    authButton(app, .password, 50_068, palette);
    authButton(app, .private_key, 50_069, palette);
    authButton(app, .agent, 50_071, palette);
}

fn authButton(app: *App, auth_type: profile.AuthType, id_extra: usize, palette: theme.Palette) void {
    const selected = app.draft.auth_type == auth_type;
    if (theme.button(@src(), auth_type.label(), .{
        .expand = .horizontal,
        .min_size_content = .height(24),
        .margin = .{ .x = 2 },
        .id_extra = id_extra,
    }, palette, .{
        .intent = if (selected) .primary else .neutral,
        .state = if (selected) .selected else .normal,
        .variant = if (selected) .solid else .ghost,
        .font_size = control_font_size,
    })) {
        app.draft.auth_type = auth_type;
    }
}

fn privateKeyPathField(app: *App, palette: theme.Palette) void {
    var cell = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .margin = .{ .y = 3, .h = 3 },
        .id_extra = 50_072,
    });
    defer cell.deinit();

    dvui.label(@src(), "Private Key Path", .{}, .{
        .color_text = palette.muted_text,
        .font = theme.textFont("Private Key Path", form_font_size),
        .id_extra = 50_073,
    });

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .height(28),
        .id_extra = 50_074,
    });
    defer row.deinit();

    var te: theme.TextEntry = undefined;
    theme.textEntry(@src(), &te, .{ .text = .{ .buffer = &app.draft.private_key_path } }, theme.panel(.{
        .expand = .horizontal,
        .gravity_y = 0.5,
        .min_size_content = .height(field_height),
        .max_size_content = .height(field_height),
        .font = theme.cjkFont(form_font_size),
        .corner_radius = .all(5),
        .id_extra = 50_076,
    }, palette).override(.{
        .color_fill = palette.surface_bg,
        .color_border = palette.border,
    }), palette);
    te.deinit();

    if (theme.button(@src(), "Browse", .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 70, .h = field_height },
        .margin = .{ .x = 6 },
        .id_extra = 50_078,
    }, palette, .{ .variant = .ghost, .font_size = control_font_size })) {
        const selected = dvui.dialogNativeFileOpen(dvui.currentWindow().arena(), .{ .title = "Select Private Key" }) catch null;
        if (selected) |path| profile.setBuffer(&app.draft.private_key_path, path);
    }
}

fn authNotice(message: []const u8, id_extra: usize, palette: theme.Palette) void {
    dvui.label(@src(), "{s}", .{message}, .{
        .color_text = palette.muted_text,
        .font = theme.textFont(message, form_font_size),
        .margin = .{ .y = 4, .h = 6 },
        .id_extra = id_extra,
    });
}

fn footer(app: *App, palette: theme.Palette) void {
    var box = dvui.box(@src(), .{ .dir = .horizontal }, theme.panel(.{
        .expand = .horizontal,
        .min_size_content = .height(footer_height),
        .padding = .{ .x = 10, .y = 7, .w = 10, .h = 7 },
        .corner_radius = .{ .x = 0, .y = 0, .w = 8, .h = 8 },
        .id_extra = 50_090,
    }, palette).override(.{
        .color_fill = palette.surface_bg,
        .color_border = palette.border_subtle,
    }));
    defer box.deinit();

    var actions = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .gravity_x = 1,
        .gravity_y = 0.5,
        .id_extra = 50_091,
    });
    defer actions.deinit();

    if (theme.button(@src(), "Delete", .{
        .min_size_content = .{ .w = 64, .h = 26 },
        .margin = .{ .x = 3 },
        .id_extra = 50_092,
        .gravity_y = 0.5,
    }, palette, .{ .intent = .danger, .variant = .ghost, .font_size = control_font_size })) {
        app.deleteSelectedProfile();
    }
    if (theme.button(@src(), "Save", .{
        .min_size_content = .{ .w = 64, .h = 26 },
        .margin = .{ .x = 3 },
        .id_extra = 50_093,
        .gravity_y = 0.5,
    }, palette, .{ .intent = .primary, .variant = .ghost, .font_size = control_font_size })) {
        app.saveDraft();
    }
    if (theme.button(@src(), "Cancel", .{
        .min_size_content = .{ .w = 64, .h = 26 },
        .margin = .{ .x = 3 },
        .id_extra = 50_094,
        .gravity_y = 0.5,
    }, palette, .{ .variant = .ghost, .font_size = control_font_size })) {
        app.cancelConfig();
    }
}

fn textField(label: []const u8, buffer: []u8, id_extra: usize, palette: theme.Palette) void {
    textFieldSized(label, buffer, id_extra, palette, true);
}

fn textFieldSized(label: []const u8, buffer: []u8, id_extra: usize, palette: theme.Palette, expand: bool) void {
    theme.textField(@src(), label, buffer, palette, .{
        .id_extra = id_extra,
        .expand = expand,
        .field_height = field_height,
        .font_size = form_font_size,
    });
}

fn portField(app: *App, palette: theme.Palette) void {
    var cell = dvui.box(@src(), .{ .dir = .vertical }, .{
        .min_size_content = .width(92),
        .margin = .{ .x = 8, .y = 3, .h = 3 },
        .id_extra = 50_045,
    });
    defer cell.deinit();

    dvui.label(@src(), "Port", .{}, .{
        .color_text = palette.muted_text,
        .font = theme.textFont("Port", form_font_size),
        .id_extra = 50_046,
    });
    var port_i32: i32 = app.draft.port;
    const port_result = theme.textEntryNumber(@src(), i32, .{
        .value = &port_i32,
        .min = 1,
        .max = 65535,
    }, theme.panel(.{
        .expand = .horizontal,
        .min_size_content = .height(field_height),
        .font = theme.textFont("22", form_font_size),
        .corner_radius = .all(5),
        .id_extra = 50_047,
    }, palette).override(.{
        .color_fill = palette.surface_bg,
        .color_border = palette.border,
    }), palette);
    if (port_result.value == .Valid) {
        app.draft.port = @intCast(port_result.value.Valid);
    }
}
