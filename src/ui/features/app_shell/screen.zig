const std = @import("std");
const dvui = @import("dvui");
const App = @import("../../../app/App.zig");
const predictive = @import("../../../core/terminal/predictive.zig");
const profile = @import("../../../core/profile.zig");
const workspace = @import("../../../core/workspace.zig");
const config_panel = @import("../profiles/config_panel.zig");
const master_password_popup = @import("../security/master_password_popup.zig");
const theme = @import("../../theme.zig");
const icon_button = @import("../../widgets/icon_button.zig");
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

fn renderPng(bytes: []const u8, name: []const u8, rs: dvui.RectScale, color: dvui.Color) void {
    icon_button.renderPng(bytes, name, rs, color);
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
        return .ok;
    }

    topBar(app, palette);
    mainArea(app, palette);

    return .ok;
}

fn topBar(app: *App, palette: theme.Palette) void {
    const bar_height: f32 = 32;
    const button_height: f32 = 26;
    const close_size: f32 = 18;
    const settings_button_size: f32 = 28;
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, theme.topbar(.{
        .expand = .horizontal,
        .min_size_content = .height(bar_height),
        .max_size_content = .height(bar_height),
        .padding = .{ .x = 12, .y = 0, .w = 12, .h = 0 },
    }, palette));
    defer bar.deinit();
    const state = dvui.dataGetPtrDefault(null, bar.data().id, "top-bar-state", TopBarState, .{});

    topBarTitle(app.currentTitle(), bar_height, palette);

    separator(palette);

    if (theme.button(@src(), "Home", .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 50, .h = button_height },
        .padding = .{ .x = 6, .y = 0, .w = 6, .h = 0 },
        .corner_radius = .all(5),
        .id_extra = 1,
    }, palette, .{ .variant = .tab, .font_size = 12 })) {
        app.goHome();
    }

    for (app.sessions.tabs.items) |tab| {
        const active = app.sessions.active_tab_id == tab.id;
        switch (connectionTab(tab, active, button_height - 2, close_size - 2, palette)) {
            .none => {},
            .activate => app.sessions.activate(tab.id),
            .close => {
                app.closeTab(tab.id);
                break;
            },
        }
    }

    const settings_button = topBarSettingsButton(settings_icon_bytes, "settings.png", .{
        .gravity_x = 1,
        .gravity_y = 0.5,
        .min_size_content = .{ .w = settings_button_size, .h = button_height },
        .max_size_content = .{ .w = settings_button_size, .h = button_height },
        .padding = .{ .x = 4, .y = 3, .w = 4, .h = 3 },
        .corner_radius = .all(5),
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
}

fn topBarSettingsButton(bytes: []const u8, name: []const u8, opts: dvui.Options, palette: theme.Palette, id_base: usize) IconButtonInfo {
    const result = icon_button.show(@src(), bytes, name, opts, palette, .{
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
    const popup_h: f32 = 205;
    const rect: dvui.Rect.Natural = .{
        .x = @max(12, window_rect.w - popup_w - 12),
        .y = 40,
        .w = popup_w,
        .h = popup_h,
    };
    var win: dvui.FloatingWidget = undefined;
    win.init(@src(), .{}, theme.panel(.{
        .rect = .cast(rect),
        .min_size_content = .{ .w = rect.w, .h = rect.h },
        .max_size_content = .{ .w = rect.w, .h = rect.h },
        .padding = .{ .x = 10, .y = 5, .w = 10, .h = 5 },
        .border = .all(1),
        .corner_radius = .all(5),
        .id_extra = id_extra,
    }, palette).override(.{
        .color_fill = palette.surface_bg,
        .color_border = palette.border,
    }));
    defer win.deinit();
    dvui.focusSubwindow(win.data().id, null);

    if (state.master_password_popup == .none and app.frame_index != state.settings_opened_frame and outsideSettingsPopupClick(win.data().rectScale().r, state.settings_button_rect)) {
        state.settings_open = false;
    }

    settingThemeRow(app, state, palette, id_extra + 10);
    settingPredictionRow(app, palette, id_extra + 40);
    settingPredictionOptionsRow(app, palette, id_extra + 80);
    settingPredictionTuningRow(app, palette, id_extra + 120);
    settingDownloadRow(app, popup_w, palette, id_extra + 160);
    settingMasterPasswordRow(app, state, palette, id_extra + 200);

    if (state.master_password_popup != .none) {
        const before_enabled = app.masterPasswordEnabled();
        switch (master_password_popup.show(app, state.master_password_popup, palette, id_extra + 240)) {
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
    predictionModeButton(app, "Safe", .safe, 48, palette, id_extra + 4);
    spacer(@src(), 5, id_extra + 5);
    predictionModeButton(app, "Auto", .auto, 50, palette, id_extra + 6);
    spacer(@src(), 5, id_extra + 7);
    predictionModeButton(app, "Aggressive", .aggressive, 88, palette, id_extra + 8);
}

fn settingPredictionTuningRow(app: *App, palette: theme.Palette, id_extra: usize) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .height(24),
        .max_size_content = .height(24),
        .padding = .all(0),
        .margin = .{ .y = 1 },
        .id_extra = id_extra,
    });
    defer row.deinit();

    settingLabel("Tuning", 86, palette, id_extra + 1);
    var cooldown_buf: [24]u8 = undefined;
    var gate_buf: [24]u8 = undefined;
    var burst_buf: [24]u8 = undefined;
    var rollback_buf: [24]u8 = undefined;
    const cooldown = std.fmt.bufPrint(&cooldown_buf, "CD {d}ms", .{app.config.terminal_prediction.cooldown_ms}) catch "Cooldown";
    const gate = std.fmt.bufPrint(&gate_buf, "Gate {d}ms", .{app.config.terminal_prediction.output_pause_ms}) catch "Gate";
    const burst = std.fmt.bufPrint(&burst_buf, "Diff {d}", .{app.config.terminal_prediction.output_change_threshold}) catch "Diff";
    const rollback = std.fmt.bufPrint(&rollback_buf, "RB {d}", .{app.config.terminal_prediction.rollback_threshold}) catch "Rollback";

    var changed = false;
    if (predictionTuningButton(cooldown, 76, palette, id_extra + 2)) {
        app.config.terminal_prediction.cooldown_ms = nextU64Preset(app.config.terminal_prediction.cooldown_ms, &.{ 250, 500, 1000, 2000 });
        changed = true;
    }
    if (predictionTuningButton(gate, 80, palette, id_extra + 3)) {
        app.config.terminal_prediction.output_pause_ms = nextU64Preset(app.config.terminal_prediction.output_pause_ms, &.{ 150, 350, 700, 1200 });
        changed = true;
    }
    if (predictionTuningButton(burst, 72, palette, id_extra + 4)) {
        app.config.terminal_prediction.output_change_threshold = nextU32Preset(app.config.terminal_prediction.output_change_threshold, &.{ 48, 96, 192, 384 });
        changed = true;
    }
    if (predictionTuningButton(rollback, 68, palette, id_extra + 5)) {
        const threshold = nextU32Preset(app.config.terminal_prediction.rollback_threshold, &.{ 32, 64, 128, 256 });
        app.config.terminal_prediction.rollback_threshold = threshold;
        app.config.terminal_prediction.disable_threshold = threshold * 4;
        changed = true;
    }
    if (changed) app.applyTerminalPredictionConfig();
}

fn predictionTuningButton(label: []const u8, width: f32, palette: theme.Palette, id_extra: usize) bool {
    return theme.button(@src(), label, .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = width, .h = 20 },
        .max_size_content = .{ .w = width, .h = 20 },
        .padding = .{ .x = 3, .y = 1, .w = 3, .h = 1 },
        .margin = .{ .w = 3 },
        .corner_radius = .all(3),
        .id_extra = id_extra,
    }, palette, .{ .variant = .ghost, .font_size = 8 });
}

fn nextU64Preset(current: u64, presets: []const u64) u64 {
    for (presets, 0..) |value, idx| {
        if (current <= value) return presets[(idx + 1) % presets.len];
    }
    return presets[0];
}

fn nextU32Preset(current: u32, presets: []const u32) u32 {
    for (presets, 0..) |value, idx| {
        if (current <= value) return presets[(idx + 1) % presets.len];
    }
    return presets[0];
}

fn settingPredictionOptionsRow(app: *App, palette: theme.Palette, id_extra: usize) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .height(24),
        .max_size_content = .height(24),
        .padding = .all(0),
        .margin = .{ .y = 1 },
        .id_extra = id_extra,
    });
    defer row.deinit();

    settingLabel("Predict", 86, palette, id_extra + 1);
    const before_tab = app.config.terminal_prediction.predict_tab;
    const before_arrows = app.config.terminal_prediction.predict_arrow_keys;
    const before_alt = app.config.terminal_prediction.predict_in_alt_screen;
    _ = theme.checkbox(@src(), &app.config.terminal_prediction.predict_tab, "Tab", palette, .{
        .id_extra = id_extra + 2,
        .layout = predictionCheckboxOptions(palette, id_extra + 2),
    });
    _ = theme.checkbox(@src(), &app.config.terminal_prediction.predict_arrow_keys, "Arrows", palette, .{
        .id_extra = id_extra + 3,
        .layout = predictionCheckboxOptions(palette, id_extra + 3),
    });
    _ = theme.checkbox(@src(), &app.config.terminal_prediction.predict_in_alt_screen, "Alt screen", palette, .{
        .id_extra = id_extra + 4,
        .layout = predictionCheckboxOptions(palette, id_extra + 4),
    });
    if (before_tab != app.config.terminal_prediction.predict_tab or
        before_arrows != app.config.terminal_prediction.predict_arrow_keys or
        before_alt != app.config.terminal_prediction.predict_in_alt_screen)
    {
        app.applyTerminalPredictionConfig();
    }
}

fn predictionCheckboxOptions(palette: theme.Palette, id_extra: usize) dvui.Options {
    return .{
        .id_extra = id_extra,
        .gravity_y = 0.5,
        .color_text = palette.text,
        .font = theme.textFont("Alt screen", 9),
        .padding = .{ .x = 3, .y = 1, .w = 6, .h = 1 },
    };
}

fn predictionModeButton(app: *App, label: []const u8, mode: predictive.PredictionMode, width: f32, palette: theme.Palette, id_extra: usize) void {
    const active = (app.config.terminal_prediction.enabled and app.config.terminal_prediction.mode == mode) or (mode == .off and !app.config.terminal_prediction.enabled);
    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{ .draw_focus = false }, theme.buttonOptions(.{
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
        .font_size = 10,
    }));
    bw.processEvents();
    bw.drawBackground();
    dvui.labelNoFmt(@src(), label, .{ .align_x = 0.5, .align_y = 0.5 }, bw.data().options.strip().override(bw.style()).override(.{
        .expand = .both,
        .gravity_x = 0.5,
        .gravity_y = 0.5,
    }));
    if (bw.clicked()) {
        app.setTerminalPredictionMode(mode);
    }
    bw.drawFocus();
    bw.deinit();
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

    // settingLabel("Download", 86, palette, id_extra + 1);
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

    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{ .draw_focus = false }, theme.buttonOptions(.{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = switch_w, .h = switch_h },
        .max_size_content = .{ .w = switch_w, .h = switch_h },
        .padding = .all(0),
        .margin = .all(0),
        .corner_radius = .all(switch_h / 2),
        .id_extra = id_extra,
    }, palette, .{ .variant = .ghost, .font_size = 9 }).override(.{
        .color_fill = dvui.Color.transparent,
        .color_fill_hover = dvui.Color.transparent,
        .color_fill_press = dvui.Color.transparent,
        .color_border = dvui.Color.transparent,
    }));
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
    const track_color = if (visual_enabled) theme.c(0x2f, 0x7d, 0xff) else palette.surface_active;
    const border_color = if (visual_enabled) theme.c(0x75, 0xa8, 0xff) else palette.border;
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

    bw.drawFocus();
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
    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{ .draw_focus = false }, theme.buttonOptions(.{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = button_w, .h = button_h },
        .max_size_content = .{ .w = button_w, .h = button_h },
        .padding = .all(0),
        .corner_radius = .all(4),
        .id_extra = id_extra,
        .margin = .all(0),
    }, palette, .{ .variant = .ghost, .font_size = 9 }).override(.{
        .color_fill = palette.surface_hover,
        .color_fill_hover = palette.surface_active,
        .color_fill_press = palette.active_bg,
    }));
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
    renderPng(folder_icon_bytes, "folder.png", .{ .r = icon_rect, .s = crs.s }, palette.accent);

    const clicked = bw.clicked();
    bw.drawFocus();
    bw.deinit();
    return clicked;
}

fn settingLabel(text: []const u8, width: f32, palette: theme.Palette, id_extra: usize) void {
    dvui.label(@src(), "{s}:", .{text}, .{
        .font = theme.textFont(text, 11),
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

    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{ .draw_focus = false }, theme.buttonOptions(.{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = switch_w, .h = switch_h },
        .max_size_content = .{ .w = switch_w, .h = switch_h },
        .padding = .all(0),
        .margin = .all(0),
        .corner_radius = .all(switch_h / 2),
        .id_extra = id_extra,
    }, palette, .{ .variant = .ghost, .font_size = 9 }).override(.{
        .color_fill = dvui.Color.transparent,
        .color_fill_hover = dvui.Color.transparent,
        .color_fill_press = dvui.Color.transparent,
        .color_border = dvui.Color.transparent,
    }));
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
    const track_color = if (active) theme.c(0x2f, 0x7d, 0xff) else palette.surface_active;
    const border_color = if (active) theme.c(0x75, 0xa8, 0xff) else palette.border;
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

    bw.drawFocus();
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
    return if (sun) theme.c(0xf3, 0xa9, 0x16) else theme.c(0x1f, 0x2b, 0x3a);
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
    const font = theme.textFont(path, 9);
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

fn connectionTab(tab: workspace.WorkspaceTab, active: bool, height: f32, close_size: f32, palette: theme.Palette) TabAction {
    const style: theme.ButtonStyle = .{
        .state = if (active) .selected else .normal,
        .variant = .tab,
        .font_size = theme.font_sizes.tab,
    };
    const title_width = tabTitleWidth(tab.title);
    var bg: dvui.ButtonWidget = undefined;
    bg.init(@src(), .{ .draw_focus = false }, theme.buttonOptions(.{
        .gravity_y = 0.5,
        .min_size_content = .height(height),
        .max_size_content = .height(height),
        .padding = .{ .x = 0, .y = 0, .w = 2, .h = 0 },
        .margin = .{ .x = 4 },
        .corner_radius = .all(5),
        .id_extra = tab.id,
    }, palette, style));
    bg.drawBackground();
    defer bg.deinit();

    var content = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .padding = .all(0),
        .margin = .all(0),
        .id_extra = tab.id + 1_000,
    });
    defer content.deinit();

    if (theme.buttonNoHoverAndPress(@src(), tab.title, .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = title_width, .h = height },
        .max_size_content = .{ .w = title_width, .h = height },
        .padding = .{ .x = 5, .y = 2, .w = 5, .h = 0 },
        .margin = .all(0),
        .corner_radius = .all(0),
        .id_extra = tab.id + 10_000,
    }, palette, .{
        .variant = .ghost,
        .font_size = style.font_size,
    })) {
        return .activate;
    }

    if (theme.button(@src(), "x", .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = close_size, .h = close_size },
        .padding = .{ .x = 0.5, .y = 2, .w = 0, .h = 2 },
        .margin = .all(0),
        .corner_radius = .all(5),
        .id_extra = tab.id + 20_000,
    }, palette, .{
        .state = style.state,
        .variant = .ghost,
        .font_size = theme.font_sizes.close,
    })) {
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
        workspace_view.show(app, tab, palette);
    } else {
        homeStage(app, palette);
    }

    if (app.configVisible()) {
        config_panel.show(app, palette);
    }
    hostKeyPrompt(app, palette);
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
    panel.init(@src(), .{}, theme.panel(.{
        .rect = .cast(rect),
        .min_size_content = .{ .w = rect.w, .h = rect.h },
        .max_size_content = .{ .w = rect.w, .h = rect.h },
        .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
        .border = .all(1),
        .corner_radius = .all(8),
        .id_extra = 920_001,
    }, palette).override(.{
        .color_fill = palette.panel_bg,
        .color_border = palette.border,
    }));
    defer panel.deinit();

    dvui.label(@src(), "Trust SSH Host Key", .{}, .{
        .font = theme.textFont("Trust SSH Host Key", 14),
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
        .font_size = 11,
    })) {
        app.rejectPendingHostKey();
    }
    if (theme.button(@src(), "Trust", .{
        .min_size_content = .{ .w = 64, .h = 18 },
        .margin = .{ .x = 4, .y = 5 },
        .id_extra = 920_062,
    }, palette, .{
        .variant = .ghost,
        .font_size = 11,
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
        .font = theme.textFont(label, 10),
        .color_text = palette.muted_text,
        .id_extra = id_extra + 1,
        .margin = .all(0),
        .padding = .all(0),
    });
    dvui.label(@src(), "{s}", .{value}, .{
        .expand = .horizontal,
        .font = theme.textFont(value, 10),
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

    if (theme.button(@src(), "+  New Connection", .{
        .min_size_content = .{ .w = home_width, .h = 28 },
        .max_size_content = .width(home_width),
        .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
        .corner_radius = .all(5),
        .margin = .{ .y = 4 },
        .id_extra = 401,
    }, palette, .{ .variant = .row, .font_size = 12 })) {
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
        .font = theme.textFont("CONNECTIONS", 10),
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
        .font = theme.cjkFont(10),
        .corner_radius = .all(5),
        .padding = .{ .x = 8, .y = 2, .w = 8, .h = 2 },
        .id_extra = 405,
    }, palette).override(.{
        .color_fill = palette.surface_bg,
        .color_border = palette.border_subtle,
    });

    var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &app.connection_search } }, opts);
    te.deinit();
}

fn groupedConnectionList(app: *App, palette: theme.Palette) void {
    const query = app.connectionSearchText();
    var rendered_any = false;

    for (app.profiles.items(), 0..) |item, idx| {
        const group = normalizedGroup(item.base.group);
        if (!isFirstVisibleGroup(app, group, idx, query)) continue;

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
        .font_size = 11,
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
    const profile_button = icon_button.showText(@src(), server_icon_bytes, "server.png", label, .{
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
        if (icon_button.show(@src(), settings_icon_bytes, "settings.png", .{
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

fn isFirstVisibleGroup(app: *App, group: []const u8, current_idx: usize, query: []const u8) bool {
    _ = query;
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
