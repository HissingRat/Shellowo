const std = @import("std");
const dvui = @import("dvui");

const keybindings = @import("../../../app/keybindings.zig");
const theme = @import("../../theme.zig");

const toggle_cooldown_ns: i128 = 500 * std.time.ns_per_ms;
const categories = [_][]const u8{
    "Editor",
    "Copy and Paste",
    "Tabs",
    "Window",
    "Search and Settings",
    "Terminal",
    "Session",
    "File Transfer",
};

pub const State = struct {
    open_flag: bool = false,
    scroll: dvui.ScrollInfo = .{ .vertical = .auto, .horizontal = .none },
    collapsed: [categories.len]bool = [_]bool{false} ** categories.len,
    last_toggle_ns: [categories.len]i128 = [_]i128{0} ** categories.len,

    pub fn open(self: *State) void {
        self.open_flag = true;
    }
};

pub fn show(state: *State, palette: theme.Palette, titlebar_height: f32) void {
    if (!state.open_flag) return;

    const window_rect = dvui.windowRect();
    const panel_w = @min(@as(f32, 680), @max(@as(f32, 320), window_rect.w - 48));
    const panel_h = @min(@as(f32, 540), @max(@as(f32, 280), window_rect.h - titlebar_height - 48));
    const rect: dvui.Rect.Natural = .{
        .x = @max(12, @round((window_rect.w - panel_w) / 2)),
        .y = @max(titlebar_height + 12, @round((window_rect.h - panel_h) / 2)),
        .w = panel_w,
        .h = panel_h,
    };

    var backdrop: dvui.FloatingWidget = undefined;
    backdrop.init(@src(), .{}, .{
        .rect = .cast(window_rect),
        .min_size_content = .{ .w = window_rect.w, .h = window_rect.h },
        .max_size_content = .{ .w = window_rect.w, .h = window_rect.h },
        .background = true,
        .color_fill = dvui.Color.black.opacity(0.62),
        .padding = .all(0),
        .margin = .all(0),
        .border = .all(0),
        .role = .none,
        .tab_index = 0,
        .id_extra = 939_999,
    });
    backdrop.deinit();

    var panel: dvui.FloatingWidget = undefined;
    panel.init(@src(), .{}, theme.popup(.{
        .rect = .cast(rect),
        .min_size_content = .{ .w = rect.w, .h = rect.h },
        .max_size_content = .{ .w = rect.w, .h = rect.h },
        .padding = .{ .x = 14, .y = 10, .w = 14, .h = 12 },
        .border = .all(1),
        .corner_radius = .all(7),
        .id_extra = 940_000,
    }, palette));
    defer panel.deinit();
    dvui.focusSubwindow(panel.data().id, null);
    handleKeys(state, panel.data());

    header(state, palette, 940_010);

    var scroll = dvui.scrollArea(@src(), .{
        .scroll_info = &state.scroll,
        .vertical = .auto,
        .vertical_bar = .auto_overlay,
        .horizontal = .none,
    }, .{
        .expand = .both,
        .padding = .all(0),
        .margin = .{ .y = 8 },
        .background = false,
        .color_fill = dvui.Color.transparent,
        .color_border = dvui.Color.transparent,
        .id_extra = 940_030,
    });
    defer scroll.deinit();

    content(state, palette, 940_100);
}

fn header(state: *State, palette: theme.Palette, id_extra: usize) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .height(26),
        .max_size_content = .height(26),
        .padding = .all(0),
        .margin = .all(0),
        .id_extra = id_extra,
    });
    defer row.deinit();

    dvui.label(@src(), "Key Map", .{}, .{
        .font = theme.textFont("Key Map", 14),
        .color_text = palette.text,
        .expand = .horizontal,
        .gravity_y = 0.5,
        .padding = .all(0),
        .margin = .all(0),
        .id_extra = id_extra + 1,
    });

    if (theme.button(@src(), "x", .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 24, .h = 22 },
        .max_size_content = .{ .w = 24, .h = 22 },
        .padding = .all(0),
        .margin = .all(0),
        .corner_radius = .all(4),
        .id_extra = id_extra + 2,
    }, palette, .{ .variant = .ghost, .font_size = 13 })) {
        state.open_flag = false;
    }
}

fn content(state: *State, palette: theme.Palette, id_extra: usize) void {
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .all(0),
        .margin = .all(0),
        .id_extra = id_extra,
    });
    defer col.deinit();

    for (categories, 0..) |category, idx| {
        if (!categoryHasImplementedShortcuts(category)) continue;
        categorySection(state, palette, category, idx, id_extra + 1 + idx * 120);
    }
}

fn categorySection(state: *State, palette: theme.Palette, category: []const u8, idx: usize, id_extra: usize) void {
    var heading_buf: [96]u8 = undefined;
    const heading = std.fmt.bufPrint(&heading_buf, "{s} {s}", .{ if (state.collapsed[idx]) ">" else "v", category }) catch category;
    if (theme.button(@src(), heading, .{
        .expand = .horizontal,
        .min_size_content = .height(28),
        .max_size_content = .height(28),
        .padding = .{ .x = 8, .y = 2, .w = 8, .h = 2 },
        .margin = .{ .y = 3 },
        .corner_radius = .all(4),
        .id_extra = id_extra,
    }, palette, .{ .variant = .row, .font_size = 14, .text_align_x = 0 })) {
        toggleCategory(state, idx);
    }

    if (state.collapsed[idx]) return;

    var row_idx: usize = 0;
    for (keybindings.all()) |shortcut| {
        if (!std.mem.eql(u8, shortcut.category, category)) continue;
        if (shortcut.status != .implemented) continue;
        shortcutRow(shortcut, palette, id_extra + 20 + row_idx);
        row_idx += 1;
    }
}

fn categoryHasImplementedShortcuts(category: []const u8) bool {
    for (keybindings.all()) |shortcut| {
        if (shortcut.status == .implemented and std.mem.eql(u8, shortcut.category, category)) return true;
    }
    return false;
}

fn shortcutRow(shortcut: keybindings.Shortcut, palette: theme.Palette, id_extra: usize) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .height(24),
        .max_size_content = .height(24),
        .padding = .all(0),
        .margin = .{ .x = 6 },
        .id_extra = id_extra,
    });
    defer row.deinit();

    dvui.label(@src(), "{s}", .{shortcut.label}, .{
        .font = theme.textFont(shortcut.label, 12),
        .color_text = palette.text,
        .expand = .horizontal,
        .gravity_y = 0.5,
        .padding = .{ .x = 8, .w = 8 },
        .id_extra = id_extra + 1,
    });

    const scope = scopeLabel(shortcut.scope);
    dvui.label(@src(), "{s}", .{scope}, .{
        .font = theme.textFont(scope, 12),
        .color_text = palette.muted_text,
        .gravity_y = 0.5,
        .min_size_content = .width(74),
        .max_size_content = .width(74),
        .padding = .all(0),
        .id_extra = id_extra + 2,
    });

    const binding = shortcutText(shortcut);
    dvui.label(@src(), "{s}", .{binding}, .{
        .font = theme.textFont(binding, 12),
        .color_text = palette.accent,
        .gravity_y = 0.5,
        .min_size_content = .width(210),
        .max_size_content = .width(210),
        .padding = .{ .x = 6 },
        .id_extra = id_extra + 3,
    });
}

fn toggleCategory(state: *State, idx: usize) void {
    const now = dvui.frameTimeNS();
    if (state.last_toggle_ns[idx] != 0 and now - state.last_toggle_ns[idx] < toggle_cooldown_ns) return;
    state.last_toggle_ns[idx] = now;
    state.collapsed[idx] = !state.collapsed[idx];
}

fn handleKeys(state: *State, data: *dvui.WidgetData) void {
    for (dvui.events()) |*event| {
        if (event.handled or event.evt != .key) continue;
        const key = event.evt.key;
        if (key.action != .down or key.code != .escape) continue;
        state.open_flag = false;
        event.handle(@src(), data);
        dvui.refresh(null, @src(), data.id);
        return;
    }
}

fn shortcutText(shortcut: keybindings.Shortcut) []const u8 {
    return switch (keybindings.currentPlatform()) {
        .macos => shortcut.macos,
        .windows, .linux => shortcut.windows_linux,
    };
}

fn scopeLabel(scope: keybindings.Scope) []const u8 {
    return switch (scope) {
        .app => "App",
        .editor => "Editor",
        .terminal => "Terminal",
    };
}
