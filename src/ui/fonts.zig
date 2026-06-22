const std = @import("std");
const dvui = @import("dvui");

const sdl_ttf = @import("../backends/text/sdl_ttf.zig");
const theme = @import("theme.zig");

const zed_font_bytes = @embedFile("shellowo-zed-font");
const zed_font_italic_bytes = @embedFile("shellowo-zed-italic-font");
const zed_font_bold_bytes = @embedFile("shellowo-zed-bold-font");
const cjk_font_bytes = @embedFile("shellowo-cjk-font");

var system: ?sdl_ttf.System = null;

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

    system = sdl_ttf.System.init(window.gpa, window.backend.impl.renderer, .{
        .regular = zed_font_bytes,
        .bold = zed_font_bold_bytes,
        .italic = zed_font_italic_bytes,
        .cjk = cjk_font_bytes,
    }) catch return;
    _ = dvui.textEngineSet(system.?.dvuiEngine());
}

pub fn deinit() void {
    if (system) |*value| value.deinit();
    system = null;
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
