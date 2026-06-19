const dvui = @import("dvui");
const std = @import("std");

const metrics = @import("../foundation/metrics.zig");
const palette_module = @import("../foundation/palette.zig");
const surface = @import("surface.zig");

pub const Options = struct {
    id_extra: usize,
    height: f32 = metrics.defaults.toolbar_height,
    padding_x: f32 = 8,
    gap: f32 = metrics.defaults.gap_small,
    topbar: bool = false,
};

pub fn begin(src: std.builtin.SourceLocation, palette: palette_module.Palette, opts: Options) dvui.BoxWidget {
    const base: dvui.Options = .{
        .expand = .horizontal,
        .min_size_content = .height(opts.height),
        .max_size_content = .height(opts.height),
        .padding = .{ .x = opts.padding_x, .w = opts.padding_x },
        .margin = .{ .w = opts.gap },
        .id_extra = opts.id_extra,
    };
    return dvui.box(src, .{ .dir = .horizontal }, if (opts.topbar) surface.topbar(base, palette) else surface.panel(base, palette));
}
