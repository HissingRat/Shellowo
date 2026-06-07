const std = @import("std");
const dvui = @import("dvui");
const App = @import("../app/App.zig");
const profile = @import("../core/profile.zig");
const workspace = @import("../core/workspace.zig");
const config_panel = @import("config_panel.zig");
const theme = @import("theme.zig");
const workspace_view = @import("workspace_view.zig");

const server_icon_bytes = @embedFile("shellowo-server-icon");
const settings_icon_bytes = @embedFile("shellowo-settings-icon");

const TabAction = enum {
    none,
    activate,
    close,
};

const home_width: f32 = 520;
const connection_list_height: f32 = 250;
const connection_row_height: f32 = 26;
const visible_connection_capacity: usize = 7;
const server_icon_size: f32 = 20;
const settings_icon_size: f32 = 18;

const IconTextButtonResult = struct {
    clicked: bool,
    hovered: bool,
};

fn maybeButton(src: std.builtin.SourceLocation, label: []const u8, opts: dvui.Options, palette: theme.Palette, style: theme.ButtonStyle, enabled: bool) bool {
    if (enabled) {
        return theme.button(src, label, opts, palette, style);
    }

    theme.buttonVisual(src, label, opts, palette, style);
    return false;
}

fn maybeButtonNoHoverAndPress(src: std.builtin.SourceLocation, label: []const u8, opts: dvui.Options, palette: theme.Palette, style: theme.ButtonStyle, enabled: bool) bool {
    if (enabled) {
        return theme.buttonNoHoverAndPress(src, label, opts, palette, style);
    }

    theme.buttonVisual(src, label, opts, palette, style);
    return false;
}

fn themedPng(src: std.builtin.SourceLocation, bytes: []const u8, name: []const u8, size: f32, color: dvui.Color, id_extra: usize) void {
    var slot = dvui.box(src, .{}, .{
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .min_size_content = .{ .w = size, .h = size },
        .max_size_content = .{ .w = size, .h = size },
        .padding = .all(0),
        .margin = .all(0),
        .id_extra = id_extra,
    });
    defer slot.deinit();

    const source: dvui.ImageSource = .{ .imageFile = .{
        .bytes = bytes,
        .name = name,
        .interpolation = .linear,
    } };
    dvui.renderImage(source, slot.data().contentRectScale(), .{ .colormod = color }) catch {};
}

fn renderPng(bytes: []const u8, name: []const u8, rs: dvui.RectScale, color: dvui.Color) void {
    const source: dvui.ImageSource = .{ .imageFile = .{
        .bytes = bytes,
        .name = name,
        .interpolation = .linear,
    } };
    dvui.renderImage(source, rs, .{ .colormod = color }) catch {};
}

fn spacer(src: std.builtin.SourceLocation, width: f32, id_extra: usize) void {
    var slot = dvui.box(src, .{}, .{
        .min_size_content = .width(width),
        .max_size_content = .width(width),
        .padding = .all(0),
        .margin = .all(0),
        .role = .none,
        .tab_index = 0,
        .id_extra = id_extra,
    });
    defer slot.deinit();
}

fn textSlot(src: std.builtin.SourceLocation, text: []const u8, width: f32, font: dvui.Font, color: dvui.Color, id_extra: usize) void {
    var slot = dvui.box(src, .{}, .{
        .expand = .vertical,
        .gravity_y = 0.5,
        .min_size_content = .width(width),
        .max_size_content = .width(width),
        .padding = .all(0),
        .margin = .all(0),
        .role = .none,
        .tab_index = 0,
        .id_extra = id_extra,
    });
    defer slot.deinit();

    const crs = slot.data().contentRectScale();
    const old_clip = dvui.clip(crs.r);
    defer dvui.clipSet(old_clip);

    const text_size = font.textSize(text);
    const text_height = text_size.h * crs.s;
    dvui.renderText(.{
        .font = font,
        .text = text,
        .rs = crs,
        .p = .{
            .x = crs.r.x,
            .y = crs.r.y + @round((crs.r.h - text_height) / 2),
        },
        .color = color,
    }) catch {};
}

fn maybeIconButton(
    src: std.builtin.SourceLocation,
    bytes: []const u8,
    name: []const u8,
    opts: dvui.Options,
    palette: theme.Palette,
    style: theme.ButtonStyle,
    enabled: bool,
    id_base: usize,
) bool {
    var bw: dvui.ButtonWidget = undefined;
    var options = theme.buttonOptions(opts, palette, style);
    if (!enabled) {
        options = options.override(.{
            .role = .none,
            .tab_index = 0,
        });
    }

    bw.init(src, .{ .draw_focus = false }, options);
    if (enabled) {
        bw.processEvents();
    }
    bw.drawBackground();

    themedPng(@src(), bytes, name, settings_icon_size, bw.style().color(.text), id_base);

    const clicked = enabled and bw.clicked();
    bw.drawFocus();
    bw.deinit();
    return clicked;
}

fn maybeIconTextButton(
    src: std.builtin.SourceLocation,
    bytes: []const u8,
    name: []const u8,
    label: []const u8,
    opts: dvui.Options,
    palette: theme.Palette,
    style: theme.ButtonStyle,
    enabled: bool,
) IconTextButtonResult {
    var bw: dvui.ButtonWidget = undefined;
    var options = theme.buttonOptions(opts, palette, style).override(.{
        .font = theme.textFont(label, style.font_size orelse opts.fontGet().size),
    });
    if (!enabled) {
        options = options.override(.{
            .role = .none,
            .tab_index = 0,
        });
    }

    bw.init(src, .{ .draw_focus = false }, options);
    if (enabled) {
        bw.processEvents();
    }
    bw.drawBackground();

    const font = theme.textFont(label, style.font_size orelse opts.fontGet().size);
    const button_style = bw.style();
    const crs = bw.data().contentRectScale();
    const icon_size = server_icon_size * crs.s;
    const left_pad = 10 * crs.s;
    const icon_gap = 8 * crs.s;
    const right_pad = 10 * crs.s;
    const icon_rect: dvui.Rect.Physical = .{
        .x = crs.r.x + left_pad,
        .y = crs.r.y + @round((crs.r.h - icon_size) / 2),
        .w = icon_size,
        .h = icon_size,
    };
    renderPng(bytes, name, .{ .r = icon_rect, .s = crs.s }, button_style.color(.text));

    const text_x = icon_rect.x + icon_rect.w + icon_gap;
    const text_w = @max(0, crs.r.x + crs.r.w - right_pad - text_x);
    const text_rect: dvui.Rect.Physical = .{
        .x = text_x,
        .y = crs.r.y,
        .w = text_w,
        .h = crs.r.h,
    };
    const old_clip = dvui.clip(text_rect);
    defer dvui.clipSet(old_clip);

    const text_size = font.textSize(label);
    const text_height = text_size.h * crs.s;
    dvui.renderText(.{
        .font = font,
        .text = label,
        .rs = .{ .r = text_rect, .s = crs.s },
        .p = .{
            .x = text_rect.x,
            .y = text_rect.y + @round((text_rect.h - text_height) / 2),
        },
        .color = button_style.color(.text),
    }) catch {};

    const clicked = enabled and bw.clicked();
    const hovered = enabled and bw.hovered();
    bw.drawFocus();
    bw.deinit();
    return .{ .clicked = clicked, .hovered = hovered };
}

fn iconButtonPlaceholder(src: std.builtin.SourceLocation, width: f32, height: f32, gap: f32, id_extra: usize) void {
    var slot = dvui.box(src, .{}, .{
        .gravity_x = 1,
        .gravity_y = 0.5,
        .min_size_content = .{ .w = width, .h = height },
        .max_size_content = .{ .w = width, .h = height },
        .padding = .all(0),
        .margin = .{ .x = gap },
        .role = .none,
        .tab_index = 0,
        .id_extra = id_extra,
    });
    defer slot.deinit();
}

pub fn frame(app: *App) !dvui.App.Result {
    app.beginFrame();
    const palette = theme.Palette.forMode(app.theme_mode);

    var root = dvui.box(@src(), .{ .dir = .vertical }, theme.app(.{
        .expand = .both,
        .padding = .all(0),
    }, palette));
    defer root.deinit();

    topBar(app, palette);
    mainArea(app, palette);

    return .ok;
}

fn topBar(app: *App, palette: theme.Palette) void {
    const bar_height: f32 = 32;
    const button_height: f32 = 28;
    const close_size: f32 = 18;
    const controls_enabled = !app.configVisible();
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, theme.topbar(.{
        .expand = .horizontal,
        .min_size_content = .height(bar_height),
        .max_size_content = .height(bar_height),
        .padding = .{ .x = 12, .y = 0, .w = 12, .h = 0 },
    }, palette));
    defer bar.deinit();

    topBarTitle(app.currentTitle(), bar_height, palette);

    separator(palette);

    if (maybeButton(@src(), "Home", .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 50, .h = button_height },
        .padding = .{ .x = 6, .y = 0, .w = 6, .h = 0 },
        .corner_radius = .all(5),
        .id_extra = 1,
    }, palette, .{ .variant = .tab, .font_size = 12 }, controls_enabled)) {
        app.goHome();
    }

    for (app.sessions.tabs.items) |tab| {
        const active = app.sessions.active_tab_id == tab.id;
        switch (connectionTab(tab, active, button_height, close_size, palette, controls_enabled)) {
            .none => {},
            .activate => app.sessions.activate(tab.id),
            .close => {
                app.sessions.closeTab(tab.id);
                break;
            },
        }
    }

    if (maybeButton(@src(), app.theme_mode.label(), .{
        .gravity_x = 1,
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 58, .h = button_height },
        .padding = .{ .x = 6, .y = 1.5, .w = 6, .h = 0 },
        .corner_radius = .all(5),
        .id_extra = 2,
    }, palette, .{ .variant = .ghost, .font_size = theme.font_sizes.tab }, controls_enabled)) {
        app.toggleTheme();
    }
}

fn topBarTitle(title: []const u8, bar_height: f32, palette: theme.Palette) void {
    const font = theme.textFont(title, 13);
    var slot = dvui.box(@src(), .{}, .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 130, .h = bar_height },
        .max_size_content = .{ .w = 130, .h = bar_height },
        .padding = .all(0),
        .id_extra = 101,
    });
    defer slot.deinit();

    const crs = slot.data().contentRectScale();
    const text_size = font.textSize(title);
    const text_height = text_size.h * crs.s;
    const y = crs.r.y + @round((crs.r.h - text_height) / 2 + theme.topBarTextOffset(title) * crs.s);

    dvui.renderText(.{
        .font = font,
        .text = title,
        .rs = crs,
        .p = .{ .x = crs.r.x, .y = y },
        .color = palette.text,
    }) catch {};
}

fn connectionTab(tab: workspace.WorkspaceTab, active: bool, height: f32, close_size: f32, palette: theme.Palette, enabled: bool) TabAction {
    const style: theme.ButtonStyle = .{
        .state = if (active) .selected else .normal,
        .variant = .tab,
        .font_size = theme.font_sizes.tab,
    };
    const title_width = tabTitleWidth(tab.title);
    var box = dvui.box(@src(), .{ .dir = .horizontal }, theme.buttonOptions(.{
        .gravity_y = 0.5,
        .min_size_content = .height(height),
        .padding = .{ .x = 0, .y = 0, .w = 2, .h = 0 },
        .margin = .{ .x = 4 },
        .corner_radius = .all(5),
        .id_extra = tab.id,
    }, palette, style));
    defer box.deinit();

    if (maybeButtonNoHoverAndPress(@src(), tab.title, .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = title_width, .h = height },
        .padding = .{ .x = 5, .y = 1, .w = 5, .h = 0 },
        .margin = .all(0),
        .corner_radius = .all(5),
        .id_extra = tab.id + 10_000,
    }, palette, style, enabled)) {
        return .activate;
    }

    if (maybeButton(@src(), "x", .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = close_size, .h = close_size },
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 2 },
        .margin = .all(0),
        .corner_radius = .all(5),
        .id_extra = tab.id + 20_000,
    }, palette, .{
        .state = style.state,
        .font_size = theme.font_sizes.close,
    }, enabled)) {
        return .close;
    }

    return .none;
}

fn tabTitleWidth(title: []const u8) f32 {
    const font = dvui.Font.theme(.body).withSize(theme.font_sizes.tab);
    return @ceil(font.textSize(title).w);
}

fn separator(palette: theme.Palette) void {
    var sep = dvui.box(@src(), .{ .dir = .vertical }, .{
        .background = true,
        .color_fill = palette.border_subtle,
        .min_size_content = .{ .w = 1, .h = 22 },
        .max_size_content = .{ .w = 1, .h = 22 },
        .margin = .{ .x = 10, .w = 10 },
        .gravity_y = 0.5,
        .id_extra = 300,
    });
    defer sep.deinit();
}

fn mainArea(app: *App, palette: theme.Palette) void {
    var body = dvui.box(@src(), .{ .dir = .vertical }, theme.app(.{
        .expand = .both,
        .padding = .all(0),
    }, palette));
    defer body.deinit();

    if (app.sessions.activeTab()) |tab| {
        workspace_view.show(tab, palette);
    } else {
        homeStage(app, palette);
    }

    if (app.configVisible()) {
        config_panel.show(app, palette);
    }
}

fn homeStage(app: *App, palette: theme.Palette) void {
    const controls_enabled = !app.configVisible();
    app.ensureGroupDefaults(visible_connection_capacity);
    var stage = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .gravity_x = 0.5,
        .gravity_y = 0.44,
        .padding = .all(20),
        .id_extra = 400,
    });
    defer stage.deinit();

    var column = dvui.box(@src(), .{ .dir = .vertical }, .{
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .min_size_content = .width(home_width),
        .max_size_content = .width(home_width),
        .id_extra = 403,
    });
    defer column.deinit();

    dvui.label(@src(), "Shellowo", .{}, .{
        .font = theme.textFont("Shellowo", 24),
        .color_text = palette.text,
        .gravity_x = 0.5,
        .margin = .{ .h = 4 },
    });

    dvui.label(@src(), "Remote workspace for who loves owo", .{}, .{
        .font = theme.textFont("Remote workspace for who loves owo", 12),
        .color_text = palette.muted_text,
        .gravity_x = 0.5,
        .margin = .{ .h = 28 },
    });

    sectionLabel("GET STARTED", palette, 410);

    if (maybeButton(@src(), "+  New Connection", .{
        .min_size_content = .{ .w = home_width, .h = 28 },
        .max_size_content = .width(home_width),
        .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
        .corner_radius = .all(5),
        .margin = .{ .y = 4 },
        .id_extra = 401,
    }, palette, .{ .variant = .row, .font_size = 12 }, controls_enabled)) {
        app.newProfile(.ssh);
    }

    connectionsHeader(app, palette, controls_enabled);

    connectionList(app, palette, controls_enabled);
}

fn connectionList(app: *App, palette: theme.Palette, controls_enabled: bool) void {
    const opts = theme.app(.{
        .min_size_content = .{ .w = home_width, .h = connection_list_height },
        .max_size_content = .{ .w = home_width, .h = connection_list_height },
        .padding = .all(0),
        .margin = .{ .y = 4 },
        .id_extra = 402,
    }, palette);

    if (controls_enabled) {
        var scroll = dvui.scrollArea(@src(), .{
            .vertical = .auto,
            .vertical_bar = .auto_overlay,
            .horizontal = .none,
        }, opts);
        defer scroll.deinit();

        connectionListBody(app, palette, controls_enabled);
        return;
    }

    var visual = dvui.box(@src(), .{ .dir = .vertical }, opts.override(.{
        .role = .none,
        .tab_index = 0,
    }));
    defer visual.deinit();

    connectionListBody(app, palette, controls_enabled);
}

fn connectionListBody(app: *App, palette: theme.Palette, controls_enabled: bool) void {
    var list = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .id_extra = 404,
    });
    defer list.deinit();

    groupedConnectionList(app, palette, controls_enabled);
}

fn connectionsHeader(app: *App, palette: theme.Palette, controls_enabled: bool) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .min_size_content = .width(home_width),
        .max_size_content = .width(home_width),
        .margin = .{ .y = 20, .h = 5 },
        .id_extra = 411,
    });
    defer row.deinit();

    dvui.label(@src(), "CONNECTIONS", .{}, .{
        .font = theme.textFont("CONNECTIONS", 10),
        .color_text = palette.text_subtle,
        .gravity_y = 0.5,
        .id_extra = 412,
    });

    searchBox(app, palette, controls_enabled);
}

fn searchBox(app: *App, palette: theme.Palette, controls_enabled: bool) void {
    const opts = theme.panel(.{
        .gravity_x = 1,
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 120, .h = 20 },
        .max_size_content = .{ .w = 120, .h = 20 },
        .font = theme.cjkFont(10),
        .corner_radius = .all(5),
        .padding = .{ .x = 8, .y = 2, .w = 8, .h = 2 },
        .id_extra = 405,
    }, palette).override(.{
        .color_fill = palette.surface_bg,
        .color_border = palette.border_subtle,
    });

    if (controls_enabled) {
        var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &app.connection_search } }, opts);
        te.deinit();
        return;
    }

    var visual = dvui.box(@src(), .{}, opts.override(.{
        .role = .none,
        .tab_index = 0,
    }));
    defer visual.deinit();

    const text = app.connectionSearchText();
    if (text.len > 0) {
        dvui.labelNoFmt(@src(), text, .{}, opts.strip().override(.{
            .expand = .both,
            .font = theme.cjkFont(10),
            .color_text = palette.muted_text,
            .gravity_y = 0.5,
            .id_extra = 406,
        }));
    }
}

fn groupedConnectionList(app: *App, palette: theme.Palette, controls_enabled: bool) void {
    const query = app.connectionSearchText();
    var rendered_any = false;

    for (app.profiles.items(), 0..) |item, idx| {
        const group = normalizedGroup(item.base().group);
        if (!isFirstVisibleGroup(app, group, idx, query)) continue;

        const count = groupMatchCount(app, group, query);
        if (count == 0) continue;
        rendered_any = true;

        const expanded = query.len > 0 or app.isGroupExpanded(group);
        groupHeader(app, group, idx, count, expanded, palette, controls_enabled);

        if (expanded) {
            for (app.profiles.items(), 0..) |child, child_idx| {
                if (!std.mem.eql(u8, normalizedGroup(child.base().group), group)) continue;
                if (!profileMatches(child, query)) continue;
                connectionRow(app, child, child_idx, palette, controls_enabled);
            }
        }
    }

    if (!rendered_any) {
        dvui.label(@src(), "No connections found", .{}, .{
            .font = theme.textFont("No connections found", 12),
            .color_text = palette.text_subtle,
            .gravity_x = 0.5,
            .margin = .{ .y = 16 },
            .id_extra = 406,
        });
    }
}

fn sectionLabel(label: []const u8, palette: theme.Palette, id_extra: usize) void {
    dvui.label(@src(), "{s}", .{label}, .{
        .font = theme.textFont(label, 10),
        .color_text = palette.text_subtle,
        .margin = .{ .y = 20, .h = 5 },
        .id_extra = id_extra,
    });
}

fn groupHeader(app: *App, group: []const u8, group_idx: usize, count: usize, expanded: bool, palette: theme.Palette, controls_enabled: bool) void {
    var label_buf: [160]u8 = undefined;
    const marker = if (expanded) "v" else ">";
    const label = std.fmt.bufPrint(&label_buf, "{s}  {s} ({d})", .{ marker, group, count }) catch group;
    if (maybeButton(@src(), label, .{
        .min_size_content = .{ .w = home_width, .h = 22 },
        .max_size_content = .width(home_width),
        .padding = .{ .x = 8, .y = 2, .w = 8, .h = 2 },
        .corner_radius = .all(5),
        .margin = .{ .y = 3 },
        .id_extra = 50_000 + group_idx,
    }, palette, .{
        .variant = .ghost,
        .font_size = 11,
        .text_align_x = 0.0,
    }, controls_enabled)) {
        app.toggleGroup(group);
    }
}

fn connectionRow(app: *App, item: profile.ConnectionProfile, row_idx: usize, palette: theme.Palette, controls_enabled: bool) void {
    const b = item.base();
    const settings_size: f32 = 26;
    const gap: f32 = 1;
    const label_width = home_width - settings_size - gap;

    var row = dvui.box(@src(), .{ .dir = .vertical }, .{
        .background = true,
        .color_fill = palette.surface_bg,
        .min_size_content = .width(home_width),
        .max_size_content = .width(home_width),
        .margin = .{ .y = 1 },
        .corner_radius = .all(5),
        .id_extra = 60_000 + row_idx,
    });
    defer row.deinit();

    var row_content = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .min_size_content = .{ .w = home_width, .h = connection_row_height },
        .max_size_content = .{ .w = home_width, .h = connection_row_height },
        .padding = .all(0),
        .margin = .all(0),
        .id_extra = 61_000 + row_idx,
    });
    defer row_content.deinit();
    const row_hovered = controls_enabled and row_content.data().rectScale().r.contains(dvui.currentWindow().mouse_pt);

    var label_buf: [160]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "{s} / {s}", .{ b.name, b.username }) catch b.name;
    const profile_button = maybeIconTextButton(@src(), server_icon_bytes, "server.png", label, .{
        .min_size_content = .{ .w = label_width, .h = connection_row_height },
        .max_size_content = .{ .w = label_width, .h = connection_row_height },
        .padding = .all(0),
        .margin = .all(0),
        .corner_radius = .all(5),
        .id_extra = 80_000 + row_idx,
    }, palette, .{
        .variant = .ghost,
        .font_size = theme.font_sizes.control,
        .text_align_x = 0.0,
    }, controls_enabled);
    if (profile_button.clicked) {
        app.profileClicked(b.id);
    }

    if (profile_button.hovered or row_hovered) {
        if (maybeIconButton(@src(), settings_icon_bytes, "settings.png", .{
            .gravity_x = 1,
            .gravity_y = 0.5,
            .min_size_content = .{ .w = settings_size, .h = connection_row_height },
            .max_size_content = .{ .w = settings_size, .h = connection_row_height },
            .padding = .all(0),
            .margin = .{ .x = gap },
            .corner_radius = .all(5),
            .id_extra = 70_000 + row_idx,
        }, palette, .{
            .variant = .ghost,
            .font_size = theme.font_sizes.tab,
        }, controls_enabled, 100_000 + row_idx * 10)) {
            app.editProfile(b.id);
        }
    } else {
        iconButtonPlaceholder(@src(), settings_size, connection_row_height, gap, 70_000 + row_idx);
    }
}

fn normalizedGroup(group_name: []const u8) []const u8 {
    return if (group_name.len == 0) "Default" else group_name;
}

fn isFirstVisibleGroup(app: *App, group: []const u8, current_idx: usize, query: []const u8) bool {
    _ = query;
    for (app.profiles.items()[0..current_idx]) |item| {
        if (!std.mem.eql(u8, normalizedGroup(item.base().group), group)) continue;
        return false;
    }
    return true;
}

fn groupMatchCount(app: *App, group: []const u8, query: []const u8) usize {
    var count: usize = 0;
    for (app.profiles.items()) |item| {
        if (!std.mem.eql(u8, normalizedGroup(item.base().group), group)) continue;
        if (profileMatches(item, query)) count += 1;
    }
    return count;
}

fn profileMatches(item: profile.ConnectionProfile, query: []const u8) bool {
    if (query.len == 0) return true;
    const b = item.base();
    return textContains(b.name, query) or
        textContains(b.username, query) or
        textContains(b.host, query) or
        textContains(normalizedGroup(b.group), query) or
        textContains(item.sessionType().label(), query);
}

fn textContains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (std.ascii.indexOfIgnoreCase(haystack, needle) != null) return true;
    return std.mem.indexOf(u8, haystack, needle) != null;
}
