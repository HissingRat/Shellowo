const dvui = @import("dvui");

const theme = @import("../theme.zig");

pub const Axis = enum {
    vertical,
    horizontal,
};

pub const Options = struct {
    axis: Axis,
    value: *f32,
    min: f32,
    max: f32,
    direction: f32 = 1,
    thickness: f32 = 5,
    sep_thickness: f32 = 1,
    id_extra: usize,
};

pub fn handle(palette: theme.Palette, opts: Options) void {
    const size = if (opts.axis == .vertical)
        dvui.Size{ .w = opts.sep_thickness, .h = 1 }
    else
        dvui.Size{ .w = 1, .h = opts.sep_thickness };

    var splitter = dvui.box(@src(), .{}, .{
        .background = opts.sep_thickness > 0,
        .color_fill = palette.border_subtle,
        .min_size_content = size,
        .max_size_content = if (opts.axis == .vertical) .width(opts.sep_thickness) else .height(opts.sep_thickness),
        .expand = if (opts.axis == .vertical) .vertical else .horizontal,
        .padding = .all(0),
        .margin = .all(0),
        .border = .all(0),
        .corner_radius = .all(0),
        .id_extra = opts.id_extra,
    });
    defer splitter.deinit();

    const hit_rect = hitRect(splitter.data().borderRectScale(), opts);
    for (dvui.events()) |*e| {
        if (!dvui.eventMatch(e, .{ .id = splitter.data().id, .r = hit_rect }))
            continue;

        switch (e.evt) {
            .mouse => |me| {
                const cursor: dvui.enums.Cursor = if (opts.axis == .vertical) .arrow_w_e else .arrow_n_s;
                if (me.action == .press and me.button.pointer()) {
                    e.handle(@src(), splitter.data());
                    dvui.captureMouse(splitter.data(), e.num);
                    dvui.dragPreStart(me.p, .{ .cursor = cursor });
                } else if (me.action == .release and me.button.pointer()) {
                    e.handle(@src(), splitter.data());
                    dvui.captureMouse(null, e.num);
                    dvui.dragEnd();
                } else if (me.action == .motion and dvui.captured(splitter.data().id)) {
                    e.handle(@src(), splitter.data());
                    if (dvui.dragging(me.p, null)) |delta| {
                        const scale = splitter.data().borderRectScale().s;
                        const amount = if (opts.axis == .vertical) delta.x / scale else delta.y / scale;
                        opts.value.* = clamp(opts.value.* + amount * opts.direction, opts.min, opts.max);
                        dvui.refresh(null, @src(), splitter.data().id);
                    }
                } else if (me.action == .position) {
                    dvui.cursorSet(cursor);
                }
            },
            else => {},
        }
    }
}

fn clamp(value: f32, min: f32, max: f32) f32 {
    return @min(@max(value, min), max);
}

fn hitRect(rs: dvui.RectScale, opts: Options) dvui.Rect.Physical {
    const extra = @max(0, (opts.thickness - opts.sep_thickness) * rs.s / 2);
    return switch (opts.axis) {
        .vertical => rs.r.outset(.{ .x = extra, .w = extra }),
        .horizontal => rs.r.outset(.{ .y = extra, .h = extra }),
    };
}
