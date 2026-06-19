const dvui = @import("dvui");
const std = @import("std");

const metrics = @import("../foundation/metrics.zig");
const palette_module = @import("../foundation/palette.zig");
const typography = @import("../foundation/typography.zig");

pub const Options = struct {
    id_extra: usize,
    expand: bool = true,
    field_height: f32 = metrics.defaults.control_height,
    font_size: f32 = 12,
};

pub fn show(
    src: std.builtin.SourceLocation,
    label: []const u8,
    buffer: []u8,
    palette: palette_module.Palette,
    opts: Options,
) void {
    var cell = dvui.box(src, .{ .dir = .vertical }, .{
        .expand = if (opts.expand) .horizontal else .none,
        .margin = .{ .y = 3, .h = 3 },
        .id_extra = opts.id_extra,
    });
    defer cell.deinit();

    dvui.label(@src(), "{s}", .{label}, .{
        .color_text = palette.muted_text,
        .font = typography.textFont(label, opts.font_size),
        .id_extra = opts.id_extra + 1,
    });
    var entry = dvui.textEntry(@src(), .{ .text = .{ .buffer = buffer } }, .{
        .expand = .horizontal,
        .min_size_content = .height(opts.field_height),
        .font = typography.cjkFont(opts.font_size),
        .background = true,
        .color_fill = palette.surface_bg,
        .color_text = palette.text,
        .color_border = palette.border,
        .corner_radius = .all(metrics.defaults.radius_small),
        .id_extra = opts.id_extra + 2,
    });
    entry.deinit();
}
