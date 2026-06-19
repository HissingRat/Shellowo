const dvui = @import("dvui");
const std = @import("std");

const metrics = @import("../foundation/metrics.zig");

pub const Options = struct {
    id_extra: usize,
    gap: f32 = metrics.defaults.gap,
    expand: bool = true,
};

pub fn begin(src: std.builtin.SourceLocation, opts: Options) dvui.BoxWidget {
    return dvui.box(src, .{ .dir = .vertical }, .{
        .expand = if (opts.expand) .horizontal else .none,
        .margin = .{ .h = opts.gap },
        .id_extra = opts.id_extra,
    });
}

pub fn row(src: std.builtin.SourceLocation, id_extra: usize) dvui.BoxWidget {
    return dvui.box(src, .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .margin = .{ .w = metrics.defaults.gap },
        .id_extra = id_extra,
    });
}
