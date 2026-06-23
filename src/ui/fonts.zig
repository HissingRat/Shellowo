const std = @import("std");
const dvui = @import("dvui");

const sdl_ttf = @import("../backends/text/sdl_ttf.zig");
const theme = @import("theme.zig");

const zed_font_bytes = @embedFile("shellowo-zed-font");
const zed_font_italic_bytes = @embedFile("shellowo-zed-italic-font");
const zed_font_bold_bytes = @embedFile("shellowo-zed-bold-font");
const cjk_font_bytes = @embedFile("shellowo-cjk-font");

var systems: std.AutoHashMapUnmanaged(*dvui.Window, *sdl_ttf.System) = .empty;
var systems_allocator: ?std.mem.Allocator = null;

pub fn loadEmbedded(window: *dvui.Window) void {
    var zed_loaded = true;
    window.addFont(theme.cjk_font_family, cjk_font_bytes, null) catch return;
    window.addFont(theme.zed_font_family, zed_font_bytes, null) catch {
        zed_loaded = false;
    };
    addFontSource(window, theme.zed_font_family, zed_font_bold_bytes, .bold, .normal) catch {};
    addFontSource(window, theme.zed_font_family, zed_font_italic_bytes, .normal, .italic) catch {};

    var current_theme = window.theme;
    const primary_family = if (zed_loaded) theme.zed_font_family else theme.cjk_font_family;
    current_theme.font_body = current_theme.font_body.withFamily(primary_family).withSize(theme.font_sizes.body);
    current_theme.font_heading = current_theme.font_heading.withFamily(primary_family).withWeight(.normal).withSize(theme.font_sizes.heading);
    current_theme.font_title = current_theme.font_title.withFamily(primary_family).withWeight(.normal).withSize(theme.font_sizes.title);
    current_theme.font_mono = current_theme.font_mono.withFamily(primary_family).withSize(theme.font_sizes.body);
    window.themeSet(current_theme);

    const system = systemFor(window) catch return;
    window.text_engine = system.dvuiEngine();
}

pub fn unloadEmbedded(window: *dvui.Window) void {
    const removed = systems.fetchRemove(window) orelse return;
    const system = removed.value;
    if (window.text_engine) |engine| {
        if (engine.context == @as(*anyopaque, @ptrCast(system))) {
            window.text_engine = null;
        }
    }
    const allocator = system.allocator;
    system.deinit();
    allocator.destroy(system);
}

pub fn deinit() void {
    var it = systems.valueIterator();
    while (it.next()) |entry| {
        const system = entry.*;
        const allocator = system.allocator;
        system.deinit();
        allocator.destroy(system);
    }
    if (systems_allocator) |allocator| {
        systems.deinit(allocator);
    }
    systems = .empty;
    systems_allocator = null;
}

fn systemFor(window: *dvui.Window) !*sdl_ttf.System {
    if (systems.get(window)) |system| return system;

    const allocator = window.gpa;
    if (systems_allocator == null) {
        systems_allocator = allocator;
    }

    const system = try allocator.create(sdl_ttf.System);
    errdefer allocator.destroy(system);
    system.* = try sdl_ttf.System.init(allocator, window.backend.impl.renderer, .{
        .regular = zed_font_bytes,
        .bold = zed_font_bold_bytes,
        .italic = zed_font_italic_bytes,
        .cjk = cjk_font_bytes,
    });
    errdefer system.deinit();

    try systems.put(allocator, window, system);
    return system;
}

fn addFontSource(
    window: *dvui.Window,
    family: []const u8,
    ttf_bytes: []const u8,
    weight: dvui.Font.Weight,
    style: dvui.Font.Style,
) std.mem.Allocator.Error!void {
    try window.fonts.database.append(window.gpa, .{
        .family = dvui.Font.array(family),
        .weight = weight,
        .style = style,
        .bytes = ttf_bytes,
    });
}
