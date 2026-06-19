const dvui = @import("dvui");
const std = @import("std");

const palette_module = @import("../foundation/palette.zig");

pub const State = enum {
    normal,
    complete,
    paused,
    failed,
};

pub const Options = struct {
    id_extra: usize,
    height: f32 = 3,
    color: ?dvui.Color = null,
    state: State = .normal,
};

pub fn show(src: std.builtin.SourceLocation, value: f32, palette: palette_module.Palette, opts: Options) void {
    const fill_color = opts.color orelse switch (opts.state) {
        .normal => palette.accent,
        .complete => palette.accent,
        .paused => palette.muted_text,
        .failed => palette.danger,
    };
    var track = dvui.box(src, .{}, .{
        .expand = .horizontal,
        .min_size_content = .height(opts.height),
        .max_size_content = .height(opts.height),
        .background = true,
        .color_fill = palette.border_subtle,
        .corner_radius = .all(opts.height / 2),
        .padding = .all(0),
        .id_extra = opts.id_extra,
    });
    defer track.deinit();

    var fill = dvui.box(@src(), .{}, .{
        .expand = .vertical,
        .min_size_content = .{ .w = @max(0, @min(1, value)), .h = 1 },
        .background = true,
        .color_fill = fill_color,
        .corner_radius = .all(opts.height / 2),
        .padding = .all(0),
        .id_extra = opts.id_extra + 1,
    });
    defer fill.deinit();
}
