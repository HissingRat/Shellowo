const dvui = @import("dvui");
const std = @import("std");

const palette_module = @import("../foundation/palette.zig");

pub const Options = struct {
    id_extra: usize,
    height: f32 = 4,
    color: ?dvui.Color = null,
};

pub fn show(src: std.builtin.SourceLocation, value: f32, palette: palette_module.Palette, opts: Options) void {
    var track = dvui.box(src, .{}, .{
        .expand = .horizontal,
        .min_size_content = .height(opts.height),
        .max_size_content = .height(opts.height),
        .background = true,
        .color_fill = palette.surface_bg,
        .corner_radius = .all(opts.height / 2),
        .padding = .all(0),
        .id_extra = opts.id_extra,
    });
    defer track.deinit();

    var fill = dvui.box(@src(), .{}, .{
        .expand = .vertical,
        .min_size_content = .{ .w = @max(0, @min(1, value)), .h = 1 },
        .background = true,
        .color_fill = opts.color orelse palette.accent,
        .corner_radius = .all(opts.height / 2),
        .padding = .all(0),
        .id_extra = opts.id_extra + 1,
    });
    defer fill.deinit();
}
