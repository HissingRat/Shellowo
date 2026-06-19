const dvui = @import("dvui");
const std = @import("std");

const metrics = @import("../foundation/metrics.zig");
const palette_module = @import("../foundation/palette.zig");
const typography = @import("../foundation/typography.zig");

pub const Options = struct {
    id_extra: usize,
    font_size: f32 = typography.font_sizes.control,
    danger: bool = false,
    enabled: bool = true,
    layout: dvui.Options = .{},
};

pub fn show(
    src: std.builtin.SourceLocation,
    label: []const u8,
    palette: palette_module.Palette,
    opts: Options,
) ?dvui.Rect.Natural {
    const text_color = if (!opts.enabled) palette.text_subtle else if (opts.danger) palette.danger else palette.text;
    const result = dvui.menuItemLabel(src, label, .{}, opts.layout.override(.{
        .id_extra = opts.id_extra,
        .background = true,
        .color_fill = dvui.Color.transparent,
        .color_fill_hover = if (opts.enabled) palette.surface_hover else dvui.Color.transparent,
        .color_fill_press = if (opts.enabled) palette.surface_active else dvui.Color.transparent,
        .color_text = text_color,
        .color_text_hover = text_color,
        .color_text_press = text_color,
        .color_border = dvui.Color.transparent,
        .border = .all(metrics.defaults.control_border_width),
        .corner_radius = .all(metrics.defaults.radius_small),
        .font = typography.textFont(label, opts.font_size),
    }));
    return if (opts.enabled) result else null;
}
