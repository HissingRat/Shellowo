const dvui = @import("dvui");
const std = @import("std");

const palette_module = @import("../foundation/palette.zig");
const typography = @import("../foundation/typography.zig");

pub const Options = struct {
    id_extra: usize,
    font_size: f32 = typography.font_sizes.control,
    layout: dvui.Options = .{},
};

pub fn show(
    src: std.builtin.SourceLocation,
    value: *bool,
    label: []const u8,
    palette: palette_module.Palette,
    opts: Options,
) bool {
    return dvui.checkbox(src, value, label, opts.layout.override(.{
        .id_extra = opts.id_extra,
        .color_text = palette.text,
        .color_fill = palette.surface_bg,
        .color_fill_hover = palette.surface_hover,
        .color_fill_press = palette.surface_active,
        .color_border = palette.border,
        .font = typography.textFont(label, opts.font_size),
    }));
}
