const std = @import("std");
const dvui = @import("dvui");
const App = @import("../../../app/App.zig");
const window_chrome = @import("../../../platform/window_chrome.zig");
const predictive = @import("../../../core/terminal/predictive.zig");
const profile = @import("../../../core/profile.zig");
const workspace = @import("../../../core/workspace.zig");
const key_map_panel = @import("key_map_panel.zig");
const config_panel = @import("../profiles/config_panel.zig");
const master_password_popup = @import("../security/master_password_popup.zig");
const theme = @import("../../theme.zig");
const unlock_screen = @import("../security/unlock_screen.zig");
const workspace_view = @import("../workspace/view.zig");

const server_icon_bytes = @embedFile("shellowo-server-icon");
const settings_icon_bytes = @embedFile("shellowo-settings-icon");
const folder_icon_bytes = @embedFile("shellowo-folder-icon");
const sun_icon_bytes = @embedFile("shellowo-sun-icon");
const moon_icon_bytes = @embedFile("shellowo-moon-icon");

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

const IconButtonInfo = struct {
    clicked: bool,
    rect: dvui.Rect.Physical,
};

const TopBarState = struct {
    settings_open: bool = false,
    settings_opened_frame: u64 = 0,
    settings_button_rect: dvui.Rect.Physical = .{},
    keymap: key_map_panel.State = .{},
    tab_scroll: dvui.ScrollInfo = .{ .vertical = .none, .horizontal = .auto },
    last_active_tab_id: ?u64 = null,
    master_password_popup: master_password_popup.Mode = .none,
    master_switch_animating: bool = false,
    master_switch_from_enabled: bool = false,
    master_switch_to_enabled: bool = false,
    master_switch_started_ns: i128 = 0,
    theme_switch_animating: bool = false,
    theme_switch_from_light: bool = false,
    theme_switch_to_light: bool = false,
    theme_switch_started_ns: i128 = 0,
};

const theme_switch_anim_ns: i128 = 180 * std.time.ns_per_ms;
const connection_tab_font_size: f32 = 12.5;
const connection_tab_horizontal_padding: f32 = 6;
const connection_tab_status_size: f32 = 6;
const connection_tab_status_gap: f32 = 7;
const connection_tab_close_gap: f32 = 8;
const connection_tab_close_size: f32 = 13;
const connection_tab_max_title_width: f32 = 148;
const connection_tab_margin_width: f32 = 4;
const connection_tabs_drag_reserve: f32 = 28;
const connection_tabs_overflow_width: f32 = 24;

fn renderPng(bytes: []const u8, name: []const u8, rs: dvui.RectScale, color: dvui.Color) void {
    theme.renderPng(bytes, name, rs, color);
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
    window_chrome.clearTitlebarFrame();
    const window_rect = dvui.windowRect();
    app.observeWindowSize(window_rect.w, window_rect.h);
    const palette = theme.Palette.forMode(app.theme_mode);

    var root = dvui.box(@src(), .{ .dir = .vertical }, theme.app(.{
        .expand = .both,
        .padding = .all(0),
    }, palette));
    defer root.deinit();

    if (app.profilesLocked()) {
        unlock_screen.show(app, palette);
        drawWindowBorder(palette);
        return .ok;
    }

    topBar(app, palette);
    mainArea(app, palette);
    windowClosePrompt(app, palette);
    drawWindowBorder(palette);

    return .ok;
}

fn topBar(app: *App, palette: theme.Palette) void {
    const bar_height = window_chrome.titlebar_height;
    const button_height: f32 = 26;
    const close_size: f32 = 18;
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, theme.topbar(.{
        .expand = .horizontal,
        .min_size_content = .height(bar_height),
        .max_size_content = .height(bar_height),
        .padding = .all(0),
        .border = .{ .h = 1 },
        .color_border = palette.border_subtle,
    }, palette));
    defer bar.deinit();
    const state = dvui.dataGetPtrDefault(null, bar.data().id, "top-bar-state", TopBarState, .{});

    const leading_inset = window_chrome.leadingInset();
    if (leading_inset > 0) spacer(@src(), leading_inset, 90);

    if (window_chrome.drawsWindowControls()) {
        if (titlebarMenuButton(bar_height, palette)) {
            window_chrome.perform(.show_system_menu);
        }
    } else {
        spacer(@src(), 8, 91);
    }

    const title_button_width = @ceil(theme.textFont("Shellowo", 13).textSize("Shellowo").w) + 14;
    var home_slot = dvui.box(@src(), .{}, .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = title_button_width, .h = button_height },
        .max_size_content = .{ .w = title_button_width, .h = button_height },
        .padding = .all(0),
        .margin = .{ .y = 2, .w = 7 },
        .id_extra = 98,
    });
    const home_clicked = theme.textButton(@src(), "Shellowo", .{
        .expand = .both,
        .padding = .all(0),
        .margin = .all(0),
        .id_extra = 1,
    }, palette, .{
        .font_size = 13,
    });
    home_slot.deinit();
    if (home_clicked) {
        app.goHome();
    }

    if (app.sessions.tabs.items.len > 0) {
        workspaceTabSeparator(palette);
    }

    connectionTabs(app, state, button_height - 5, close_size - 5, palette);

    titlebarDragRegion(bar_height);

    const settings_button = topBarSettingsButton(settings_icon_bytes, "settings.png", .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 16, .h = 16 },
        .max_size_content = .{ .w = 16, .h = 16 },
        .padding = .all(0),
        .margin = .{ .w = 5 },
        .corner_radius = .all(4),
        .id_extra = 2,
    }, palette, 302);
    state.settings_button_rect = settings_button.rect;
    if (settings_button.clicked) {
        state.settings_open = !state.settings_open;
        state.settings_opened_frame = app.frame_index;
        if (!state.settings_open) {
            state.master_password_popup = .none;
            app.cancelMasterPasswordSetup();
        }
    }

    if (state.settings_open) {
        settingsPopup(app, state, palette, 900);
    }

    if (window_chrome.drawsWindowControls()) {
        windowCaptionButtons(bar_height, palette);
    } else {
        spacer(@src(), 6, 92);
    }
    key_map_panel.show(&state.keymap, palette, window_chrome.titlebar_height);
}

fn connectionTabs(app: *App, state: *TopBarState, height: f32, close_size: f32, palette: theme.Palette) void {
    const tabs = app.sessions.tabs.items;
    if (tabs.len == 0) {
        state.last_active_tab_id = null;
        state.tab_scroll.scrollToOffset(.horizontal, 0);
        return;
    }

    var content_width: f32 = 0;
    for (tabs) |tab| content_width += connectionTabWidth(tab.title, close_size) + connection_tab_margin_width;

    var position_probe = dvui.box(@src(), .{}, .{
        .min_size_content = .{ .w = 0, .h = height },
        .max_size_content = .{ .w = 0, .h = height },
        .padding = .all(0),
        .margin = .all(0),
        .role = .none,
        .tab_index = 0,
        .id_extra = 105,
    });
    const tabs_start_x = position_probe.data().rect.x;
    position_probe.deinit();

    const trailing_controls_width: f32 = if (window_chrome.drawsWindowControls()) 159 else 27;
    const available_width = @max(
        @as(f32, 96),
        dvui.windowRect().w - tabs_start_x - trailing_controls_width - connection_tabs_drag_reserve,
    );
    const overflowing = content_width > available_width;
    const viewport_width = @min(
        content_width,
        available_width - (if (overflowing) connection_tabs_overflow_width else 0),
    );
    const active_changed = state.last_active_tab_id != app.sessions.active_tab_id;

    var scroll = dvui.scrollArea(@src(), .{
        .scroll_info = &state.tab_scroll,
        .vertical = .none,
        .vertical_bar = .hide,
        .horizontal_bar = .hide,
    }, .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = viewport_width, .h = height },
        .max_size_content = .{ .w = viewport_width, .h = height },
        .padding = .all(0),
        .margin = .all(0),
        .background = false,
        .color_fill = dvui.Color.transparent,
        .color_border = dvui.Color.transparent,
        .corner_radius = .all(0),
        .id_extra = 103,
    });

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .min_size_content = .{ .w = content_width, .h = height },
        .max_size_content = .height(height),
        .padding = .all(0),
        .margin = .all(0),
        .id_extra = 104,
    });

    for (tabs) |tab| {
        const active = app.sessions.active_tab_id == tab.id;
        switch (connectionTab(tab, active, active and active_changed, height, close_size, palette)) {
            .none => {},
            .activate => app.sessions.activate(tab.id),
            .close => {
                app.closeTab(tab.id);
                break;
            },
        }
    }

    row.deinit();
    horizontalWheelScroll(scroll, &state.tab_scroll);
    scroll.deinit();

    if (overflowing) {
        tabOverflowIndicator(state, height, palette);
    }
    state.last_active_tab_id = app.sessions.active_tab_id;
}

fn tabOverflowIndicator(state: *TopBarState, height: f32, palette: theme.Palette) void {
    const can_scroll_right = state.tab_scroll.offsetFromMax(.horizontal) > 0.5;
    var slot = dvui.box(@src(), .{}, .{
        .gravity_y = 0.6,
        .min_size_content = .{ .w = connection_tabs_overflow_width, .h = height },
        .max_size_content = .{ .w = connection_tabs_overflow_width, .h = height },
        .padding = .all(0),
        .margin = .all(0),
        .id_extra = 107,
    });
    const clicked = theme.textButton(@src(), ">>", .{
        .expand = .both,
        .padding = .all(0),
        .margin = .all(0),
        .color_text = if (can_scroll_right) palette.muted_text else palette.text_subtle.opacity(0.45),
        .id_extra = 106,
    }, palette, .{
        .font_size = 11.5,
    });
    slot.deinit();
    if (clicked and can_scroll_right) {
        state.tab_scroll.scrollByOffset(.horizontal, @max(@as(f32, 120), state.tab_scroll.viewport.w * 0.72));
        dvui.refresh(null, @src(), dvui.parentGet().data().id);
    }
}

fn horizontalWheelScroll(scroll: *dvui.ScrollAreaWidget, info: *dvui.ScrollInfo) void {
    if (info.scrollMax(.horizontal) <= 0) return;
    const rect = scroll.data().borderRectScale().r;
    for (dvui.events()) |*event| {
        if (event.handled or event.evt != .mouse) continue;
        const mouse = event.evt.mouse;
        if (!rect.contains(mouse.p)) continue;
        switch (mouse.action) {
            .wheel_y => |ticks| {
                info.scrollByOffset(.horizontal, -ticks);
                event.handle(@src(), scroll.data());
                dvui.refresh(null, @src(), scroll.data().id);
            },
            else => {},
        }
    }
}

fn titlebarDragRegion(height: f32) void {
    var position_probe = dvui.box(@src(), .{}, .{
        .min_size_content = .{ .w = 0, .h = height },
        .max_size_content = .{ .w = 0, .h = height },
        .padding = .all(0),
        .margin = .all(0),
        .role = .none,
        .tab_index = 0,
        .id_extra = 108,
    });
    const drag_start_x = position_probe.data().rect.x;
    position_probe.deinit();

    const trailing_controls_width: f32 = if (window_chrome.drawsWindowControls()) 159 else 27;
    const drag_width = @max(@as(f32, 0), dvui.windowRect().w - drag_start_x - trailing_controls_width);
    var drag = dvui.box(@src(), .{}, .{
        .min_size_content = .{ .w = drag_width, .h = height },
        .max_size_content = .{ .w = drag_width, .h = height },
        .padding = .all(0),
        .margin = .all(0),
        .role = .none,
        .tab_index = 0,
        .id_extra = 93,
    });
    defer drag.deinit();
    window_chrome.addTitlebarDragRect(drag.data().rectScale());
}

fn titlebarMenuButton(height: f32, palette: theme.Palette) bool {
    var bw: theme.ButtonWidget = undefined;
    bw.init(@src(), .{
        .min_size_content = .{ .w = 40, .h = height },
        .max_size_content = .{ .w = 40, .h = height },
        .padding = .all(0),
        .margin = .all(0),
        .corner_radius = .all(0),
        .id_extra = 94,
    }, palette, .{ .variant = .ghost }, .{
        .interactive = false,
        .override = .{
            .color_fill = dvui.Color.transparent,
            .color_fill_hover = palette.surface_hover,
            .color_fill_press = palette.surface_active,
        },
    });
    bw.processEvents();
    bw.drawBackground();

    const rs = bw.data().contentRectScale();
    const line_w = 13 * rs.s;
    const line_h = @max(@as(f32, 1), rs.s);
    const left = rs.r.x + @round((rs.r.w - line_w) / 2);
    const top = rs.r.y + @round((rs.r.h - 9 * rs.s) / 2);
    for (0..3) |index| {
        const line: dvui.Rect.Physical = .{
            .x = left,
            .y = top + @as(f32, @floatFromInt(index)) * 4 * rs.s,
            .w = line_w,
            .h = line_h,
        };
        line.fill(.all(0), .{ .color = palette.muted_text, .fade = 1 });
    }
    const clicked = bw.clicked();
    bw.deinit();
    return clicked;
}

fn windowCaptionButtons(height: f32, palette: theme.Palette) void {
    if (captionButton(.minimize, height, palette, false, 95)) {
        window_chrome.perform(.minimize);
    }
    const maximize_glyph: CaptionGlyph = if (window_chrome.isMaximized()) .restore else .maximize;
    if (captionButton(maximize_glyph, height, palette, false, 96)) {
        window_chrome.perform(.toggle_maximize);
    }
    if (captionButton(.close, height, palette, true, 97)) {
        window_chrome.perform(.close);
    }
}

const CaptionGlyph = enum {
    minimize,
    maximize,
    restore,
    close,
};

fn captionButton(
    glyph: CaptionGlyph,
    height: f32,
    palette: theme.Palette,
    danger: bool,
    id_extra: usize,
) bool {
    const hover_fill = if (danger) theme.c(0xd7, 0x35, 0x35) else palette.surface_hover;
    const press_fill = if (danger) theme.c(0xb9, 0x25, 0x25) else palette.surface_active;
    var bw: theme.ButtonWidget = undefined;
    bw.init(@src(), .{
        .min_size_content = .{ .w = 46, .h = height },
        .max_size_content = .{ .w = 46, .h = height },
        .padding = .all(0),
        .margin = .all(0),
        .corner_radius = .all(0),
        .id_extra = id_extra,
    }, palette, .{ .variant = .ghost }, .{
        .interactive = false,
        .override = .{
            .color_fill = dvui.Color.transparent,
            .color_fill_hover = hover_fill,
            .color_fill_press = press_fill,
        },
    });
    bw.processEvents();
    bw.drawBackground();

    const rs = bw.data().contentRectScale();
    drawCaptionGlyph(glyph, rs, palette.text);

    const clicked = bw.clicked();
    bw.deinit();
    return clicked;
}

fn drawCaptionGlyph(glyph: CaptionGlyph, rs: dvui.RectScale, color: dvui.Color) void {
    var center = rs.r.center();
    if (glyph == .maximize or glyph == .restore) center.y += rs.s;
    const thickness = @max(@as(f32, 1), rs.s);
    switch (glyph) {
        .minimize => {
            dvui.Path.stroke(.{ .points = &.{
                .{ .x = center.x - 5 * rs.s, .y = center.y + 1.5 * rs.s },
                .{ .x = center.x + 5 * rs.s, .y = center.y + 1.5 * rs.s },
            } }, .{ .thickness = thickness, .color = color, .endcap_style = .square });
        },
        .maximize => {
            const rect: dvui.Rect.Physical = .{
                .x = center.x - 5.5 * rs.s,
                .y = center.y - 4 * rs.s,
                .w = 11 * rs.s,
                .h = 8 * rs.s,
            };
            rect.stroke(.all(0), .{ .thickness = thickness, .color = color });
        },
        .restore => {
            const front: dvui.Rect.Physical = .{
                .x = center.x - 5.5 * rs.s,
                .y = center.y - 2.5 * rs.s,
                .w = 9 * rs.s,
                .h = 7 * rs.s,
            };
            dvui.Path.stroke(.{ .points = &.{
                .{ .x = center.x - 3.5 * rs.s, .y = center.y - 5 * rs.s },
                .{ .x = center.x + 5.5 * rs.s, .y = center.y - 5 * rs.s },
                .{ .x = center.x + 5.5 * rs.s, .y = center.y + 2 * rs.s },
            } }, .{ .thickness = thickness, .color = color, .endcap_style = .square });
            front.stroke(.all(0), .{ .thickness = thickness, .color = color });
        },
        .close => {
            dvui.Path.stroke(.{ .points = &.{
                .{ .x = center.x - 4 * rs.s, .y = center.y - 4 * rs.s },
                .{ .x = center.x + 4 * rs.s, .y = center.y + 4 * rs.s },
            } }, .{ .thickness = thickness, .color = color, .endcap_style = .square });
            dvui.Path.stroke(.{ .points = &.{
                .{ .x = center.x + 4 * rs.s, .y = center.y - 4 * rs.s },
                .{ .x = center.x - 4 * rs.s, .y = center.y + 4 * rs.s },
            } }, .{ .thickness = thickness, .color = color, .endcap_style = .square });
        },
    }
}

fn topBarSettingsButton(bytes: []const u8, name: []const u8, opts: dvui.Options, palette: theme.Palette, id_base: usize) IconButtonInfo {
    const result = theme.iconButton(@src(), bytes, name, opts, palette, .{
        .variant = .ghost,
        .font_size = theme.font_sizes.tab,
    }, .{
        .icon_size = settings_icon_size,
        .id_extra = id_base,
    });
    return .{ .clicked = result.clicked, .rect = result.rect };
}

fn settingsPopup(app: *App, state: *TopBarState, palette: theme.Palette, id_extra: usize) void {
    const window_rect = dvui.windowRect();
    const popup_w: f32 = 430;
    const popup_h: f32 = 172;
    const right_inset: f32 = if (window_chrome.drawsWindowControls()) 146 else 12;
    const rect: dvui.Rect.Natural = .{
        .x = @max(12, window_rect.w - popup_w - right_inset),
        .y = window_chrome.titlebar_height + 8,
        .w = popup_w,
        .h = popup_h,
    };
    var win: dvui.FloatingWidget = undefined;
    win.init(@src(), .{}, theme.popup(.{
        .rect = .cast(rect),
        .min_size_content = .{ .w = rect.w, .h = rect.h },
        .max_size_content = .{ .w = rect.w, .h = rect.h },
        .padding = .{ .x = 10, .y = 5, .w = 10, .h = 5 },
        .border = .all(1),
        .corner_radius = .all(5),
        .id_extra = id_extra,
    }, palette));
    defer win.deinit();
    dvui.focusSubwindow(win.data().id, null);

    if (state.master_password_popup == .none and app.frame_index != state.settings_opened_frame and outsideSettingsPopupClick(win.data().rectScale().r, state.settings_button_rect)) {
        state.settings_open = false;
    }

    settingThemeRow(app, state, palette, id_extra + 10);
    settingPredictionRow(app, palette, id_extra + 40);
    settingDownloadRow(app, popup_w, palette, id_extra + 80);
    settingKeyMapRow(state, palette, id_extra + 120);
    settingMasterPasswordRow(app, state, palette, id_extra + 150);

    if (state.master_password_popup != .none) {
        const before_enabled = app.masterPasswordEnabled();
        switch (master_password_popup.show(app, state.master_password_popup, palette, id_extra + 190)) {
            .none => {},
            .close => state.master_password_popup = .none,
            .enabled => {
                masterSwitchAnimate(state, before_enabled, true);
                state.master_password_popup = .none;
            },
            .disabled => {
                masterSwitchAnimate(state, before_enabled, false);
                state.master_password_popup = .none;
            },
        }
    }
}

fn settingKeyMapRow(state: *TopBarState, palette: theme.Palette, id_extra: usize) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .height(24),
        .max_size_content = .height(24),
        .padding = .all(0),
        .margin = .{ .y = 7 },
        .id_extra = id_extra,
    });
    defer row.deinit();

    settingLabel("Shortcut", 86, palette, id_extra + 1);
    if (theme.button(@src(), "Key Map", .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 84, .h = 22 },
        .max_size_content = .{ .w = 84, .h = 22 },
        .padding = .{ .x = 6, .y = 0, .w = 6, .h = 0 },
        .corner_radius = .all(4),
        .id_extra = id_extra + 2,
    }, palette, .{ .variant = .ghost, .font_size = 13 })) {
        state.keymap.open();
        state.settings_open = false;
        state.master_password_popup = .none;
    }
}

fn settingPredictionRow(app: *App, palette: theme.Palette, id_extra: usize) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .height(24),
        .max_size_content = .height(24),
        .padding = .all(0),
        .margin = .{ .y = 7 },
        .id_extra = id_extra,
    });
    defer row.deinit();

    settingLabel("Prediction", 86, palette, id_extra + 1);
    predictionModeButton(app, "Off", .off, 44, palette, id_extra + 2);
    spacer(@src(), 5, id_extra + 3);
    predictionModeButton(app, "Auto", .auto, 50, palette, id_extra + 4);
}

fn predictionModeButton(app: *App, label: []const u8, mode: predictive.PredictionMode, width: f32, palette: theme.Palette, id_extra: usize) void {
    const active = app.config.terminal_prediction.mode == mode;
    if (theme.button(@src(), label, .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = width, .h = 22 },
        .max_size_content = .{ .w = width, .h = 22 },
        .padding = .{ .x = 6, .y = 0, .w = 6, .h = 0 },
        .corner_radius = .all(4),
        .id_extra = id_extra,
    }, palette, .{
        .variant = if (active) .solid else .ghost,
        .intent = if (active) .primary else .neutral,
        .state = if (active) .selected else .normal,
        .font_size = 13,
    })) {
        app.setTerminalPredictionMode(mode);
    }
}

fn settingThemeRow(app: *App, state: *TopBarState, palette: theme.Palette, id_extra: usize) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .height(24),
        .max_size_content = .height(24),
        .padding = .all(0),
        .id_extra = id_extra,
    });
    defer row.deinit();

    settingLabel("Theme", 86, palette, id_extra + 1);
    themeToggleSwitch(app, state, palette, id_extra + 2);
}

fn settingDownloadRow(app: *App, max_width: f32, palette: theme.Palette, id_extra: usize) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .height(26),
        .max_size_content = .height(26),
        .padding = .all(0),
        .margin = .{ .y = 7 },
        .id_extra = id_extra,
    });
    defer row.deinit();

    if (folderPathButton(palette, id_extra + 2)) {
        const arena = dvui.currentWindow().arena();
        const selected = dvui.dialogNativeFolderSelect(arena, .{ .title = "Download Folder" }) catch null;
        if (selected) |path| app.setDownloadPath(path);
    }

    pathValue(app.config.download_path, max_width - 50, palette, id_extra + 4);
}

fn settingMasterPasswordRow(app: *App, state: *TopBarState, palette: theme.Palette, id_extra: usize) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .height(24),
        .max_size_content = .height(24),
        .padding = .all(0),
        .margin = .{ .y = 7 },
        .id_extra = id_extra,
    });
    defer row.deinit();

    settingLabel("Password", 86, palette, id_extra + 1);
    masterPasswordToggleSwitch(app, state, palette, id_extra + 2);
}

fn masterPasswordToggleSwitch(app: *App, state: *TopBarState, palette: theme.Palette, id_extra: usize) void {
    const switch_w: f32 = 46;
    const switch_h: f32 = 22;
    const knob_d: f32 = 21;
    const active = app.masterPasswordEnabled();

    var bw: theme.ButtonWidget = undefined;
    bw.init(@src(), .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = switch_w, .h = switch_h },
        .max_size_content = .{ .w = switch_w, .h = switch_h },
        .padding = .all(0),
        .margin = .all(0),
        .corner_radius = .all(switch_h / 2),
        .id_extra = id_extra,
    }, palette, .{ .variant = .ghost, .font_size = 12 }, .{
        .interactive = false,
        .override = .{
            .color_fill = dvui.Color.transparent,
            .color_fill_hover = dvui.Color.transparent,
            .color_fill_press = dvui.Color.transparent,
            .color_border = dvui.Color.transparent,
        },
    });
    bw.processEvents();

    if (bw.clicked()) {
        if (active) {
            state.master_password_popup = .disable;
        } else {
            state.master_password_popup = .enable;
        }
    }

    const crs = bw.data().contentRectScale();
    const track_rect = crs.r;
    const radius = dvui.Rect.Physical.all(track_rect.h / 2);
    const visual_enabled = app.masterPasswordEnabled();
    const track_color = if (visual_enabled) palette.active_bg else palette.surface_active;
    const border_color = if (visual_enabled) palette.border_selected else palette.border;
    track_rect.fill(radius, .{ .color = track_color, .fade = 1.0 });
    track_rect.stroke(radius, .{ .thickness = 1 * crs.s, .color = border_color });

    const knob_margin = 0.5 * crs.s;
    const knob_size = knob_d * crs.s;
    const t = masterSwitchProgress(state);
    const knob_pos = if (state.master_switch_animating)
        std.math.lerp(if (state.master_switch_from_enabled) @as(f32, 1) else @as(f32, 0), if (state.master_switch_to_enabled) @as(f32, 1) else @as(f32, 0), t)
    else if (visual_enabled) @as(f32, 1) else @as(f32, 0);
    const knob_left = track_rect.x + knob_margin;
    const knob_right = track_rect.x + track_rect.w - knob_size - knob_margin;
    const knob_x = std.math.lerp(knob_left, knob_right, knob_pos);
    const knob_rect: dvui.Rect.Physical = .{
        .x = knob_x,
        .y = track_rect.y + @round((track_rect.h - knob_size) / 2),
        .w = knob_size,
        .h = knob_size,
    };
    knob_rect.fill(dvui.Rect.Physical.all(knob_size / 2), .{ .color = theme.c(0xf2, 0xf4, 0xf7), .fade = 1.0 });
    knob_rect.stroke(dvui.Rect.Physical.all(knob_size / 2), .{ .thickness = 1 * crs.s, .color = palette.border });

    bw.deinit();
}

fn masterSwitchProgress(state: *TopBarState) f32 {
    if (!state.master_switch_animating) return 1;
    const elapsed = dvui.frameTimeNS() - state.master_switch_started_ns;
    if (elapsed >= theme_switch_anim_ns) {
        state.master_switch_animating = false;
        return 1;
    }
    dvui.refresh(null, @src(), dvui.currentWindow().data().id.update("master_switch_animation"));
    const raw = @as(f32, @floatFromInt(@max(0, elapsed))) / @as(f32, @floatFromInt(theme_switch_anim_ns));
    return smoothStep(@min(1, raw));
}

fn masterSwitchAnimate(state: *TopBarState, from_enabled: bool, to_enabled: bool) void {
    if (from_enabled == to_enabled) return;
    state.master_switch_from_enabled = from_enabled;
    state.master_switch_to_enabled = to_enabled;
    state.master_switch_started_ns = dvui.frameTimeNS();
    state.master_switch_animating = true;
}

fn folderPathButton(palette: theme.Palette, id_extra: usize) bool {
    const button_w: f32 = 28;
    const button_h: f32 = 28;
    const icon_size: f32 = 18;
    var bw: theme.ButtonWidget = undefined;
    bw.init(@src(), .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = button_w, .h = button_h },
        .max_size_content = .{ .w = button_w, .h = button_h },
        .padding = .all(0),
        .corner_radius = .all(4),
        .id_extra = id_extra,
        .margin = .all(0),
    }, palette, .{ .variant = .ghost, .font_size = 12 }, .{
        .override = .{ .color_fill = palette.surface_hover },
    });
    bw.processEvents();
    bw.drawBackground();

    const crs = bw.data().contentRectScale();
    const size = icon_size * crs.s;
    const icon_rect: dvui.Rect.Physical = .{
        .x = crs.r.x + @round((crs.r.w - size) / 2),
        .y = crs.r.y + @round((crs.r.h - size) / 2),
        .w = size,
        .h = size,
    };
    renderPng(folder_icon_bytes, "folder.png", .{ .r = icon_rect, .s = crs.s }, palette.folder_icon);

    const clicked = bw.clicked();
    bw.deinit();
    return clicked;
}

fn settingLabel(text: []const u8, width: f32, palette: theme.Palette, id_extra: usize) void {
    dvui.label(@src(), "{s}:", .{text}, .{
        .font = theme.textFont(text, 14),
        .color_text = palette.text,
        .gravity_y = 0.5,
        .min_size_content = .width(width),
        .max_size_content = .width(width),
        .padding = .all(0),
        .id_extra = id_extra,
    });
}

fn themeToggleSwitch(app: *App, state: *TopBarState, palette: theme.Palette, id_extra: usize) void {
    const switch_w: f32 = 46;
    const switch_h: f32 = 22;
    const knob_d: f32 = 21;
    const icon_d: f32 = 15;

    var bw: theme.ButtonWidget = undefined;
    bw.init(@src(), .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = switch_w, .h = switch_h },
        .max_size_content = .{ .w = switch_w, .h = switch_h },
        .padding = .all(0),
        .margin = .all(0),
        .corner_radius = .all(switch_h / 2),
        .id_extra = id_extra,
    }, palette, .{ .variant = .ghost, .font_size = 12 }, .{
        .interactive = false,
        .override = .{
            .color_fill = dvui.Color.transparent,
            .color_fill_hover = dvui.Color.transparent,
            .color_fill_press = dvui.Color.transparent,
            .color_border = dvui.Color.transparent,
        },
    });
    bw.processEvents();

    if (bw.clicked()) {
        const from_light = app.theme_mode == .light;
        const to_light = !from_light;
        state.theme_switch_from_light = from_light;
        state.theme_switch_to_light = to_light;
        state.theme_switch_started_ns = dvui.frameTimeNS();
        state.theme_switch_animating = true;
        app.setThemeMode(if (to_light) .light else .dark);
    }

    const crs = bw.data().contentRectScale();
    const track_rect = crs.r;
    const radius = dvui.Rect.Physical.all(track_rect.h / 2);
    const active = app.theme_mode == .light;
    const t = themeSwitchProgress(state);
    const knob_pos = if (state.theme_switch_animating)
        std.math.lerp(if (state.theme_switch_from_light) @as(f32, 1) else @as(f32, 0), if (state.theme_switch_to_light) @as(f32, 1) else @as(f32, 0), t)
    else if (active) @as(f32, 1) else @as(f32, 0);
    const track_color = if (active) palette.active_bg else palette.surface_active;
    const border_color = if (active) palette.border_selected else palette.border;
    track_rect.fill(radius, .{ .color = track_color, .fade = 1.0 });
    track_rect.stroke(radius, .{ .thickness = 1 * crs.s, .color = border_color });

    const knob_margin = 0.5 * crs.s;
    const knob_size = knob_d * crs.s;
    const knob_left = track_rect.x + knob_margin;
    const knob_right = track_rect.x + track_rect.w - knob_size - knob_margin;
    const knob_x = std.math.lerp(knob_left, knob_right, knob_pos);
    const knob_rect: dvui.Rect.Physical = .{
        .x = knob_x,
        .y = track_rect.y + @round((track_rect.h - knob_size) / 2),
        .w = knob_size,
        .h = knob_size,
    };
    knob_rect.fill(dvui.Rect.Physical.all(knob_size / 2), .{ .color = theme.c(0xf2, 0xf4, 0xf7), .fade = 1.0 });
    knob_rect.stroke(dvui.Rect.Physical.all(knob_size / 2), .{ .thickness = 1 * crs.s, .color = palette.border });
    renderThemeSwitchIcons(state, active, knob_rect, icon_d * crs.s);

    bw.deinit();
}

fn themeSwitchProgress(state: *TopBarState) f32 {
    if (!state.theme_switch_animating) return 1;
    const elapsed = dvui.frameTimeNS() - state.theme_switch_started_ns;
    if (elapsed >= theme_switch_anim_ns) {
        state.theme_switch_animating = false;
        return 1;
    }
    dvui.refresh(null, @src(), dvui.currentWindow().data().id.update("theme_switch_animation"));
    const raw = @as(f32, @floatFromInt(@max(0, elapsed))) / @as(f32, @floatFromInt(theme_switch_anim_ns));
    return smoothStep(@min(1, raw));
}

fn renderThemeSwitchIcons(state: *const TopBarState, active_light: bool, knob_rect: dvui.Rect.Physical, icon_size: f32) void {
    const icon_rect: dvui.Rect.Physical = .{
        .x = knob_rect.x + @round((knob_rect.w - icon_size) / 2),
        .y = knob_rect.y + @round((knob_rect.h - icon_size) / 2),
        .w = icon_size,
        .h = icon_size,
    };
    const icon_rs: dvui.RectScale = .{ .r = icon_rect, .s = dvui.windowRectScale().s };

    if (state.theme_switch_animating) {
        const t = themeSwitchProgressConst(state);
        const from_sun = state.theme_switch_from_light;
        const to_sun = state.theme_switch_to_light;
        renderSwitchIcon(if (from_sun) sun_icon_bytes else moon_icon_bytes, if (from_sun) "sun.png" else "moon.png", icon_rs, switchIconColor(from_sun).opacity(1 - t));
        renderSwitchIcon(if (to_sun) sun_icon_bytes else moon_icon_bytes, if (to_sun) "sun.png" else "moon.png", icon_rs, switchIconColor(to_sun).opacity(t));
        return;
    }

    renderSwitchIcon(if (active_light) sun_icon_bytes else moon_icon_bytes, if (active_light) "sun.png" else "moon.png", icon_rs, switchIconColor(active_light));
}

fn switchIconColor(sun: bool) dvui.Color {
    return if (sun) theme.c(0xf3, 0xa9, 0x16) else theme.c(0x2b, 0x2b, 0x2e);
}

fn themeSwitchProgressConst(state: *const TopBarState) f32 {
    if (!state.theme_switch_animating) return 1;
    const elapsed = dvui.frameTimeNS() - state.theme_switch_started_ns;
    const raw = @as(f32, @floatFromInt(@max(0, elapsed))) / @as(f32, @floatFromInt(theme_switch_anim_ns));
    return smoothStep(@min(1, raw));
}

fn renderSwitchIcon(bytes: []const u8, name: []const u8, rs: dvui.RectScale, color: dvui.Color) void {
    const source: dvui.ImageSource = .{ .imageFile = .{
        .bytes = bytes,
        .name = name,
        .interpolation = .linear,
    } };
    dvui.renderImage(source, rs, .{ .colormod = color }) catch {};
}

fn smoothStep(t: f32) f32 {
    return t * t * (3 - 2 * t);
}

fn outsideSettingsPopupClick(menu_rect: dvui.Rect.Physical, settings_button_rect: dvui.Rect.Physical) bool {
    for (dvui.events()) |*event| {
        if (event.evt != .mouse or event.evt.mouse.action != .press) continue;
        if (settings_button_rect.contains(event.evt.mouse.p)) return false;
        if (!menu_rect.contains(event.evt.mouse.p)) return true;
    }
    return false;
}

fn pathValue(path: []const u8, width: f32, palette: theme.Palette, id_extra: usize) void {
    var slot = dvui.box(@src(), .{}, .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = width, .h = 26 },
        .max_size_content = .{ .w = width, .h = 26 },
        .padding = .{ .x = 8, .y = 0, .w = 0, .h = 0 },
        .id_extra = id_extra,
    });
    defer slot.deinit();

    const crs = slot.data().contentRectScale();
    var path_buf: [160]u8 = undefined;
    const font = theme.textFont(path, 12);
    const display_path = foldedPathForWidth(path, &path_buf, width - 8, font);
    const text_size = font.textSize(display_path);
    const text_height = text_size.h * crs.s;
    const old_clip = dvui.clip(crs.r);
    defer dvui.clipSet(old_clip);
    dvui.renderText(.{
        .font = font,
        .text = display_path,
        .rs = crs,
        .p = .{
            .x = crs.r.x,
            .y = crs.r.y + @round((crs.r.h - text_height) / 2),
        },
        .color = palette.muted_text,
    }) catch {};
}

fn foldedPathForWidth(path: []const u8, buf: []u8, width: f32, font: dvui.Font) []const u8 {
    if (font.textSize(path).w <= width) return path;
    const tail = std.fs.path.basename(path);
    if (tail.len == 0) return path;

    var prefix_len: usize = @min(path.len, 28);
    var tail_len: usize = @min(tail.len, 40);
    const min_prefix_len: usize = @min(path.len, 6);
    const min_tail_len: usize = @min(tail.len, 8);

    while (prefix_len >= min_prefix_len or tail_len >= min_tail_len) {
        const candidate = std.fmt.bufPrint(buf, "{s}..../{s}", .{
            path[0..prefix_len],
            tail[tail.len - tail_len ..],
        }) catch return path;
        if (font.textSize(candidate).w <= width) return candidate;

        if (prefix_len > min_prefix_len) {
            prefix_len -= 1;
        } else if (tail_len > min_tail_len) {
            tail_len -= 1;
        } else {
            break;
        }
    }

    return std.fmt.bufPrint(buf, ".../{s}", .{tail[tail.len - min_tail_len ..]}) catch path;
}

fn connectionTab(tab: workspace.WorkspaceTab, active: bool, ensure_visible: bool, height: f32, close_size: f32, palette: theme.Palette) TabAction {
    const title_width = @min(tabTitleWidth(tab.title, connection_tab_font_size), connection_tab_max_title_width);
    const tab_width = connectionTabWidth(tab.title, close_size);

    var button: theme.ButtonWidget = undefined;
    button.init(@src(), .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = tab_width, .h = height },
        .max_size_content = .{ .w = tab_width, .h = height },
        .padding = .all(0),
        .margin = .{ .x = 2, .y = 1 },
        .corner_radius = .all(4),
        .id_extra = tab.id,
    }, palette, .{
        .variant = .ghost,
        .font_size = connection_tab_font_size,
    }, .{
        .interactive = false,
        .override = .{
            .background = false,
            .color_fill = dvui.Color.transparent,
            .color_fill_hover = dvui.Color.transparent,
            .color_fill_press = dvui.Color.transparent,
            .color_border = dvui.Color.transparent,
        },
    });
    button.processEvents();
    defer button.deinit();

    const rs = button.data().contentRectScale();
    if (ensure_visible) dvui.scrollTo(.{ .screen_rect = rs.r });
    const hovered = button.hovered();
    if (active) {
        rs.r.fill(
            dvui.Rect.Physical.all(4 * rs.s),
            .{ .color = palette.surface_active.opacity(0.42), .fade = 1 },
        );
        const underline: dvui.Rect.Physical = .{
            .x = rs.r.x,
            .y = rs.r.y + rs.r.h - 2 * rs.s,
            .w = rs.r.w,
            .h = 2 * rs.s,
        };
        underline.fill(.all(1 * rs.s), .{ .color = palette.accent.opacity(0.78), .fade = 1 });
    }

    const status_diameter = connection_tab_status_size * rs.s;
    const status_rect: dvui.Rect.Physical = .{
        .x = rs.r.x + connection_tab_horizontal_padding * rs.s,
        .y = rs.r.y + @round((rs.r.h - status_diameter) / 2),
        .w = status_diameter,
        .h = status_diameter,
    };
    status_rect.fill(
        dvui.Rect.Physical.all(status_diameter / 2),
        .{ .color = tabStatusColor(tab.status, palette), .fade = 1 },
    );

    const title_font = theme.textFont(tab.title, connection_tab_font_size);
    const title_rect: dvui.Rect.Physical = .{
        .x = status_rect.x + status_rect.w + connection_tab_status_gap * rs.s,
        .y = rs.r.y,
        .w = title_width * rs.s,
        .h = rs.r.h,
    };
    const title_size = title_font.textSize(tab.title).scale(rs.s, dvui.Size.Physical);
    const old_clip = dvui.clip(title_rect);
    dvui.renderText(.{
        .font = title_font,
        .text = tab.title,
        .rs = rs,
        .p = .{
            .x = title_rect.x,
            .y = title_rect.y + @round((title_rect.h - title_size.h) / 2 + (theme.topBarTextOffset(tab.title) - 1.5) * rs.s),
        },
        .color = if (active or hovered) palette.text else palette.muted_text,
    }) catch {};
    dvui.clipSet(old_clip);

    const close_rect: dvui.Rect.Physical = .{
        .x = rs.r.x + rs.r.w - (connection_tab_horizontal_padding + close_size) * rs.s,
        .y = rs.r.y + @round((rs.r.h - close_size * rs.s) / 2),
        .w = close_size * rs.s,
        .h = close_size * rs.s,
    };
    const close_visible = active or hovered;
    if (close_visible) {
        const close_hovered = close_rect.contains(dvui.currentWindow().mouse_pt);
        const close_font = theme.textFont("×", theme.font_sizes.close - 1);
        const close_text_size = close_font.textSize("×").scale(rs.s, dvui.Size.Physical);
        dvui.renderText(.{
            .font = close_font,
            .text = "×",
            .rs = rs,
            .p = .{
                .x = close_rect.x + @round((close_rect.w - close_text_size.w) / 2),
                .y = close_rect.y + @round((close_rect.h - close_text_size.h) / 2),
            },
            .color = if (close_hovered) palette.danger else palette.muted_text,
        }) catch {};
    }

    if (button.clicked()) {
        if (close_visible and close_rect.contains(dvui.currentWindow().mouse_pt)) return .close;
        return .activate;
    }

    return .none;
}

fn drawWindowBorder(palette: theme.Palette) void {
    if (!window_chrome.drawsWindowControls()) return;
    const rs = dvui.currentWindow().data().rectScale();
    rs.r.insetAll(0.5 * rs.s).stroke(.all(0), .{
        .thickness = rs.s,
        .color = palette.border,
        .after = true,
    });
}

fn connectionTabWidth(title: []const u8, close_size: f32) f32 {
    const title_width = @min(tabTitleWidth(title, connection_tab_font_size), connection_tab_max_title_width);
    return connection_tab_horizontal_padding * 2 +
        connection_tab_status_size +
        connection_tab_status_gap +
        title_width +
        connection_tab_close_gap +
        close_size;
}

fn tabTitleWidth(title: []const u8, font_size: f32) f32 {
    const font = theme.textFont(title, font_size);
    return @ceil(font.textSize(title).w);
}

fn workspaceTabSeparator(palette: theme.Palette) void {
    dvui.label(@src(), "›", .{}, .{
        .font = theme.textFont("›", 13),
        .color_text = palette.text_subtle,
        .gravity_y = 0.5,
        .padding = .all(0),
        .margin = .{ .x = 1, .w = 4 },
        .id_extra = 102,
    });
}

fn tabStatusColor(status: workspace.TabStatus, palette: theme.Palette) dvui.Color {
    return switch (status) {
        .connected => palette.network_rx,
        .resolving, .connecting, .verifying_host_key, .authenticating, .opening_shell => palette.warning,
        .failed => palette.danger,
        .idle, .closed => palette.text_subtle,
    };
}

fn mainArea(app: *App, palette: theme.Palette) void {
    var body = dvui.box(@src(), .{ .dir = .vertical }, theme.app(.{
        .expand = .both,
        .padding = .all(0),
    }, palette));
    defer body.deinit();

    if (app.sessions.activeTab()) |tab| {
        workspace_view.show(app, tab, palette);
    } else {
        homeStage(app, palette);
    }

    if (app.configVisible()) {
        config_panel.show(app, palette);
    }
    hostKeyPrompt(app, palette);
}

fn windowClosePrompt(app: *App, palette: theme.Palette) void {
    if (!app.windowClosePending()) return;

    const blockers = app.closeBlockers();
    const window_rect = dvui.windowRect();
    const blocker_count = closeBlockerRowCount(blockers);
    const popup_w: f32 = 290;
    const popup_h: f32 = 100 + @as(f32, @floatFromInt(blocker_count)) * 21;
    const rect: dvui.Rect.Natural = .{
        .x = @max(12, @round((window_rect.w - popup_w) / 2)),
        .y = @max(window_chrome.titlebar_height + 12, @round((window_rect.h - popup_h) / 2)),
        .w = @min(popup_w, window_rect.w - 24),
        .h = popup_h,
    };

    var backdrop: dvui.FloatingWidget = undefined;
    backdrop.init(@src(), .{}, .{
        .rect = .cast(window_rect),
        .min_size_content = .{ .w = window_rect.w, .h = window_rect.h },
        .max_size_content = .{ .w = window_rect.w, .h = window_rect.h },
        .background = true,
        .color_fill = palette.app_bg.opacity(0.72),
        .padding = .all(0),
        .margin = .all(0),
        .border = .all(0),
        .role = .none,
        .tab_index = 0,
        .id_extra = 929_999,
    });
    backdrop.deinit();

    var panel: dvui.FloatingWidget = undefined;
    panel.init(@src(), .{}, theme.popup(.{
        .rect = .cast(rect),
        .min_size_content = .{ .w = rect.w, .h = rect.h },
        .max_size_content = .{ .w = rect.w, .h = rect.h },
        .padding = .{ .x = 16, .y = 12, .w = 16, .h = 12 },
        .border = .all(1),
        .corner_radius = .all(7),
        .id_extra = 930_000,
    }, palette));
    defer panel.deinit();
    dvui.focusSubwindow(panel.data().id, null);
    handleWindowClosePromptKeys(app, panel.data());

    var content = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .all(0),
        .margin = .all(0),
        .id_extra = 930_001,
    });
    defer content.deinit();

    var heading = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .height(24),
        .max_size_content = .height(24),
        .padding = .all(0),
        .margin = .all(0),
        .id_extra = 930_002,
    });

    var warning_mark = dvui.box(@src(), .{}, .{
        .min_size_content = .{ .w = 20, .h = 20 },
        .max_size_content = .{ .w = 20, .h = 20 },
        .gravity_y = 0.5,
        .background = true,
        .color_fill = palette.danger.opacity(0.14),
        .corner_radius = .all(5),
        .padding = .all(0),
        .margin = .{ .w = 9 },
        .id_extra = 930_003,
    });
    dvui.label(@src(), "!", .{}, .{
        .expand = .both,
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .font = theme.textFont("!", 13),
        .color_text = palette.danger,
        .padding = .{ .x = 6, .y = 2.5 },
        .margin = .all(0),
        .id_extra = 930_004,
    });
    warning_mark.deinit();

    dvui.label(@src(), "Quit Shellowo?", .{}, .{
        .gravity_y = 0.5,
        .font = theme.textFont("Quit Shellowo?", 15),
        .color_text = palette.text,
        .padding = .all(0),
        .margin = .all(0),
        .id_extra = 930_005,
    });
    heading.deinit();

    dvui.label(@src(), "Active work will be interrupted.", .{}, .{
        .font = theme.textFont("Active work will be interrupted.", 12),
        .color_text = palette.muted_text,
        .margin = .{ .y = 7, .h = 8 },
        .padding = .all(0),
        .id_extra = 930_006,
    });

    var actions = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .gravity_x = 0,
        .margin = .{ .y = 10 },
        .id_extra = 930_050,
    });
    defer actions.deinit();

    if (theme.button(@src(), "Cancel", .{
        .min_size_content = .{ .w = 56, .h = 18 },
        .max_size_content = .height(22),
        .margin = .{ .x = 3 },
        .id_extra = 930_051,
    }, palette, .{ .variant = .ghost, .font_size = 12.5 })) {
        app.cancelWindowClose();
    }
    if (theme.button(@src(), "Quit", .{
        .min_size_content = .{ .w = 56, .h = 18 },
        .max_size_content = .height(22),
        .margin = .{ .x = 3 },
        .id_extra = 930_052,
    }, palette, .{ .variant = .solid, .intent = .danger, .font_size = 12.5 })) {
        app.confirmWindowClose();
    }
}

fn closeBlockerRowCount(blockers: App.CloseBlockers) usize {
    var count: usize = 0;
    if (blockers.active_sessions > 0) count += 1;
    if (blockers.active_transfers > 0) count += 1;
    if (blockers.dirty_editors > 0) count += 1;
    return count;
}

test "window close blocker row count handles multiple blockers" {
    try std.testing.expectEqual(@as(usize, 0), closeBlockerRowCount(.{}));
    try std.testing.expectEqual(@as(usize, 3), closeBlockerRowCount(.{
        .active_sessions = 2,
        .active_transfers = 1,
        .dirty_editors = 1,
    }));
}

fn handleWindowClosePromptKeys(app: *App, data: *dvui.WidgetData) void {
    for (dvui.events()) |*event| {
        if (event.handled or event.evt != .key) continue;
        const key = event.evt.key;
        if (key.action != .down or key.code != .escape) continue;
        app.cancelWindowClose();
        event.handle(@src(), data);
        dvui.refresh(null, @src(), data.id);
        return;
    }
}

fn hostKeyPrompt(app: *App, palette: theme.Palette) void {
    const arena = dvui.currentWindow().arena();
    const pending = app.pendingHostKey(arena) orelse return;
    defer pending.deinit(arena);
    var fingerprint_buf: [64]u8 = undefined;
    const fingerprint_len = std.base64.standard_no_pad.Encoder.calcSize(pending.host_key.sha256.len);
    const fingerprint = std.base64.standard_no_pad.Encoder.encode(fingerprint_buf[0..fingerprint_len], &pending.host_key.sha256);

    const window_rect = dvui.windowRect();
    const popup_w = @min(@as(f32, 560), @max(@as(f32, 360), window_rect.w - 48));
    const popup_h: f32 = 174;
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
        .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
        .border = .all(1),
        .corner_radius = .all(8),
        .id_extra = 920_001,
    }, palette));
    defer panel.deinit();

    dvui.label(@src(), "Trust SSH Host Key", .{}, .{
        .font = theme.textFont("Trust SSH Host Key", 17),
        .color_text = palette.text,
        .margin = .{ .h = 3 },
        .id_extra = 920_002,
    });

    hostKeyRow("Host", pending.host, palette, 920_010);
    var port_buf: [16]u8 = undefined;
    hostKeyRow("Port", std.fmt.bufPrint(&port_buf, "{d}", .{pending.port}) catch "?", palette, 920_020);
    hostKeyRow("Algorithm", pending.host_key.algorithm.label(), palette, 920_030);
    hostKeyRow("SHA256", fingerprint, palette, 920_040);

    var prompt_spacer = dvui.box(@src(), .{}, .{ .expand = .vertical, .id_extra = 920_050 });
    defer prompt_spacer.deinit();

    var actions = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .gravity_x = 0,
        .id_extra = 920_060,
    });
    defer actions.deinit();

    if (theme.button(@src(), "Cancel", .{
        .min_size_content = .{ .w = 64, .h = 18 },
        .margin = .{ .x = 4, .y = 5 },
        .id_extra = 920_061,
    }, palette, .{
        .variant = .ghost,
        .font_size = 14,
    })) {
        app.rejectPendingHostKey();
    }
    if (theme.button(@src(), "Trust", .{
        .min_size_content = .{ .w = 64, .h = 18 },
        .margin = .{ .x = 4, .y = 5 },
        .id_extra = 920_062,
    }, palette, .{
        .variant = .ghost,
        .font_size = 14,
    })) {
        app.trustPendingHostKey();
    }
}

fn hostKeyRow(label: []const u8, value: []const u8, palette: theme.Palette, id_extra: usize) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .height(17),
        .max_size_content = .height(17),
        .id_extra = id_extra,
        .margin = .{ .h = 3 },
    });
    defer row.deinit();

    dvui.label(@src(), "{s}", .{label}, .{
        .min_size_content = .width(78),
        .font = theme.textFont(label, 13),
        .color_text = palette.muted_text,
        .id_extra = id_extra + 1,
        .margin = .all(0),
        .padding = .all(0),
    });
    dvui.label(@src(), "{s}", .{value}, .{
        .expand = .horizontal,
        .font = theme.textFont(value, 13),
        .color_text = palette.text,
        .id_extra = id_extra + 2,
        .margin = .all(0),
        .padding = .all(0),
    });
}

fn homeStage(app: *App, palette: theme.Palette) void {
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
        .font = theme.textFont("Shellowo", 27),
        .color_text = palette.text,
        .gravity_x = 0.5,
        .margin = .{ .h = 4 },
    });

    dvui.label(@src(), "Remote workspace for who loves owo", .{}, .{
        .font = theme.textFont("Remote workspace for who loves owo", 15),
        .color_text = palette.muted_text,
        .gravity_x = 0.5,
        .margin = .{ .h = 28 },
    });

    sectionLabel("GET STARTED", palette, 410);

    if (theme.button(@src(), "+  New Connection", .{
        .min_size_content = .{ .w = home_width, .h = 28 },
        .max_size_content = .width(home_width),
        .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
        .corner_radius = .all(5),
        .margin = .{ .y = 4 },
        .id_extra = 401,
    }, palette, .{ .variant = .row, .font_size = 15 })) {
        app.newProfile();
    }

    connectionsHeader(app, palette);

    connectionList(app, palette);
}

fn connectionList(app: *App, palette: theme.Palette) void {
    const opts = theme.app(.{
        .min_size_content = .{ .w = home_width, .h = connection_list_height },
        .max_size_content = .{ .w = home_width, .h = connection_list_height },
        .padding = .all(0),
        .margin = .{ .y = 4 },
        .id_extra = 402,
    }, palette);

    var scroll = dvui.scrollArea(@src(), .{
        .vertical = .auto,
        .vertical_bar = .auto_overlay,
        .horizontal = .none,
    }, opts);
    defer scroll.deinit();

    connectionListBody(app, palette);
}

fn connectionListBody(app: *App, palette: theme.Palette) void {
    var list = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .id_extra = 404,
    });
    defer list.deinit();

    groupedConnectionList(app, palette);
}

fn connectionsHeader(app: *App, palette: theme.Palette) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .min_size_content = .width(home_width),
        .max_size_content = .width(home_width),
        .margin = .{ .y = 20, .h = 5 },
        .id_extra = 411,
    });
    defer row.deinit();

    dvui.label(@src(), "CONNECTIONS", .{}, .{
        .font = theme.textFont("CONNECTIONS", 13),
        .color_text = palette.text_subtle,
        .gravity_y = 0.5,
        .id_extra = 412,
    });

    searchBox(app, palette);
}

fn searchBox(app: *App, palette: theme.Palette) void {
    const opts = theme.panel(.{
        .gravity_x = 1,
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 120, .h = 20 },
        .max_size_content = .{ .w = 120, .h = 20 },
        .font = theme.cjkFont(13),
        .corner_radius = .all(5),
        .padding = .{ .x = 8, .y = 2, .w = 8, .h = 2 },
        .id_extra = 405,
    }, palette).override(.{
        .color_fill = palette.surface_bg,
        .color_border = palette.border_subtle,
    });

    var te: theme.TextEntry = undefined;
    theme.textEntry(@src(), &te, .{ .text = .{ .buffer = &app.connection_search } }, opts, palette);
    te.deinit();
}

fn groupedConnectionList(app: *App, palette: theme.Palette) void {
    const query = app.connectionSearchText();
    var rendered_any = false;

    for (app.profiles.items(), 0..) |item, idx| {
        const group = normalizedGroup(item.base.group);
        if (!isFirstVisibleGroup(app, group, idx)) continue;

        const count = groupMatchCount(app, group, query);
        if (count == 0) continue;
        rendered_any = true;

        const expanded = query.len > 0 or app.isGroupExpanded(group);
        groupHeader(app, group, idx, count, expanded, palette);

        if (expanded) {
            for (app.profiles.items(), 0..) |child, child_idx| {
                if (!std.mem.eql(u8, normalizedGroup(child.base.group), group)) continue;
                if (!profileMatches(child, query)) continue;
                connectionRow(app, child, child_idx, palette);
            }
        }
    }

    if (!rendered_any) {
        dvui.label(@src(), "No connections found", .{}, .{
            .font = theme.textFont("No connections found", 15),
            .color_text = palette.text_subtle,
            .gravity_x = 0.5,
            .margin = .{ .y = 16 },
            .id_extra = 406,
        });
    }
}

fn sectionLabel(label: []const u8, palette: theme.Palette, id_extra: usize) void {
    dvui.label(@src(), "{s}", .{label}, .{
        .font = theme.textFont(label, 13),
        .color_text = palette.text_subtle,
        .margin = .{ .y = 20, .h = 5 },
        .id_extra = id_extra,
    });
}

fn groupHeader(app: *App, group: []const u8, group_idx: usize, count: usize, expanded: bool, palette: theme.Palette) void {
    var label_buf: [160]u8 = undefined;
    const marker = if (expanded) "v" else ">";
    const label = std.fmt.bufPrint(&label_buf, "{s}  {s} ({d})", .{ marker, group, count }) catch group;
    if (theme.button(@src(), label, .{
        .min_size_content = .{ .w = home_width, .h = 22 },
        .max_size_content = .width(home_width),
        .padding = .{ .x = 8, .y = 2, .w = 8, .h = 2 },
        .corner_radius = .all(5),
        .margin = .{ .y = 3 },
        .id_extra = 50_000 + group_idx,
    }, palette, .{
        .variant = .ghost,
        .font_size = 14,
        .text_align_x = 0.0,
    })) {
        app.toggleGroup(group);
    }
}

fn connectionRow(app: *App, item: profile.ConnectionProfile, row_idx: usize, palette: theme.Palette) void {
    const b = item.base;
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
    const row_hovered = row_content.data().rectScale().r.contains(dvui.currentWindow().mouse_pt);

    var label_buf: [160]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "{s} / {s}", .{ b.name, b.username }) catch b.name;
    const profile_button = theme.iconButtonText(@src(), server_icon_bytes, "server.png", label, .{
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
    }, .{
        .icon_size = server_icon_size,
        .id_extra = 80_000 + row_idx,
    });
    if (profile_button.clicked) {
        app.profileClicked(b.id);
    }

    if (profile_button.hovered or row_hovered) {
        if (theme.iconButton(@src(), settings_icon_bytes, "settings.png", .{
            .gravity_x = 1,
            .gravity_y = 0.5,
            .min_size_content = .{ .w = settings_size, .h = settings_size },
            .max_size_content = .{ .w = settings_size, .h = settings_size },
            .padding = .all(0),
            .margin = .{ .x = gap },
            .corner_radius = .all(5),
            .id_extra = 70_000 + row_idx,
        }, palette, .{
            .variant = .ghost,
            .font_size = theme.font_sizes.tab,
        }, .{
            .icon_size = settings_icon_size,
            .id_extra = 100_000 + row_idx * 10,
        }).clicked) {
            app.editProfile(b.id);
        }
    } else {
        iconButtonPlaceholder(@src(), settings_size, settings_size, gap, 70_000 + row_idx);
    }
}

fn normalizedGroup(group_name: []const u8) []const u8 {
    return if (group_name.len == 0) "Default" else group_name;
}

fn isFirstVisibleGroup(app: *App, group: []const u8, current_idx: usize) bool {
    for (app.profiles.items()[0..current_idx]) |item| {
        if (!std.mem.eql(u8, normalizedGroup(item.base.group), group)) continue;
        return false;
    }
    return true;
}

fn groupMatchCount(app: *App, group: []const u8, query: []const u8) usize {
    var count: usize = 0;
    for (app.profiles.items()) |item| {
        if (!std.mem.eql(u8, normalizedGroup(item.base.group), group)) continue;
        if (profileMatches(item, query)) count += 1;
    }
    return count;
}

fn profileMatches(item: profile.ConnectionProfile, query: []const u8) bool {
    if (query.len == 0) return true;
    const b = item.base;
    return textContains(b.name, query) or
        textContains(b.username, query) or
        textContains(b.host, query) or
        textContains(normalizedGroup(b.group), query);
}

fn textContains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (std.ascii.indexOfIgnoreCase(haystack, needle) != null) return true;
    return std.mem.indexOf(u8, haystack, needle) != null;
}
