const dvui = @import("dvui");
const App = @import("../app/App.zig");
const profile = @import("../core/profile.zig");
const theme = @import("theme.zig");

const panel_width: f32 = 520;
const panel_height: f32 = 460;
const header_height: f32 = 36;
const footer_height: f32 = 44;
const content_height: f32 = panel_height - header_height - footer_height;
const form_font_size: f32 = 11;
const control_font_size: f32 = 11;
const field_height: f32 = 20;

pub fn show(app: *App, palette: theme.Palette) void {
    var layer = dvui.overlay(@src(), .{
        .expand = .both,
        .id_extra = 50_000,
    });
    defer layer.deinit();

    var animator = dvui.animate(@src(), .{
        .kind = .alpha,
        .duration = 120_000,
    }, .{
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .min_size_content = .{ .w = panel_width, .h = panel_height },
        .max_size_content = .{ .w = panel_width, .h = panel_height },
        .id_extra = 50_001,
    });
    defer animator.deinit();

    var panel = dvui.box(@src(), .{ .dir = .vertical }, theme.panel(.{
        .min_size_content = .{ .w = panel_width, .h = panel_height },
        .max_size_content = .{ .w = panel_width, .h = panel_height },
        .padding = .all(0),
        .corner_radius = .all(8),
        .id_extra = 50_002,
    }, palette).override(.{
        .color_fill = palette.panel_bg,
        .color_border = palette.border_subtle,
    }));
    defer panel.deinit();

    header(palette);
    form(app, palette);
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

fn form(app: *App, palette: theme.Palette) void {
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

    {
        var kind = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .h = 4 },
            .id_extra = 50_022,
        });
        defer kind.deinit();

        if (dvui.radio(@src(), app.draft.profile_type == .ssh, "SSH", .{ .id_extra = 50_023, .color_text = palette.text, .font = theme.textFont("SSH", form_font_size) })) {
            app.draft.profile_type = .ssh;
            app.draft.port = profile.defaultPort(.ssh);
        }
        if (dvui.radio(@src(), app.draft.profile_type == .ftp, "FTP", .{ .id_extra = 50_024, .color_text = palette.text, .font = theme.textFont("FTP", form_font_size) })) {
            app.draft.profile_type = .ftp;
            app.draft.port = profile.defaultPort(.ftp);
        }
    }

    textField("Name", &app.draft.name, 50_030, palette);
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 50_040 });
        defer row.deinit();
        textFieldSized("Host", &app.draft.host, 50_041, palette, true);
        portField(app, palette);
    }
    textField("Group", &app.draft.group, 50_050, palette);
    textField("Username", &app.draft.username, 50_060, palette);
    textField("Password", &app.draft.password, 50_070, palette);

    if (app.draft.profile_type == .ssh) {
        _ = dvui.checkbox(@src(), &app.draft.sftp_enabled, "Enable SFTP", .{ .id_extra = 50_080, .color_text = palette.text, .font = theme.textFont("Enable SFTP", form_font_size) });
    } else {
        _ = dvui.checkbox(@src(), &app.draft.secure_ftp, "Use FTPS", .{ .id_extra = 50_081, .color_text = palette.text, .font = theme.textFont("Use FTPS", form_font_size) });
    }
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
    }, palette, .{ .intent = .danger, .variant = .ghost, .font_size = control_font_size })) {
        app.deleteSelectedProfile();
    }
    if (theme.button(@src(), "Save", .{
        .min_size_content = .{ .w = 64, .h = 26 },
        .margin = .{ .x = 3 },
        .id_extra = 50_093,
    }, palette, .{ .intent = .primary, .variant = .ghost, .font_size = control_font_size })) {
        app.saveDraft();
    }
    if (theme.button(@src(), "Cancel", .{
        .min_size_content = .{ .w = 64, .h = 26 },
        .margin = .{ .x = 3 },
        .id_extra = 50_094,
    }, palette, .{ .variant = .ghost, .font_size = control_font_size })) {
        app.cancelConfig();
    }
}

fn textField(label: []const u8, buffer: []u8, id_extra: usize, palette: theme.Palette) void {
    textFieldSized(label, buffer, id_extra, palette, true);
}

fn textFieldSized(label: []const u8, buffer: []u8, id_extra: usize, palette: theme.Palette, expand: bool) void {
    var cell = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = if (expand) .horizontal else .none,
        .margin = .{ .y = 3, .h = 3 },
        .id_extra = id_extra,
    });
    defer cell.deinit();

    dvui.label(@src(), "{s}", .{label}, .{
        .color_text = palette.muted_text,
        .font = theme.textFont(label, form_font_size),
        .id_extra = id_extra + 1,
    });
    var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = buffer } }, theme.panel(.{
        .expand = .horizontal,
        .min_size_content = .height(field_height),
        .font = theme.cjkFont(form_font_size),
        .corner_radius = .all(5),
        .id_extra = id_extra + 2,
    }, palette).override(.{
        .color_fill = palette.surface_bg,
        .color_border = palette.border,
    }));
    te.deinit();
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
    const port_result = dvui.textEntryNumber(@src(), i32, .{
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
    }));
    if (port_result.value == .Valid) {
        app.draft.port = @intCast(port_result.value.Valid);
    }
}
