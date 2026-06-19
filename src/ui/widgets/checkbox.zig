const dvui = @import("dvui");
const std = @import("std");

const metrics = @import("../foundation/metrics.zig");
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
    const options = opts.layout.override(.{
        .name = "Shellow Checkbox",
        .role = .check_box,
        .id_extra = opts.id_extra,
        .color_text = palette.text,
        .color_fill = palette.surface_bg,
        .color_fill_hover = palette.surface_hover,
        .color_fill_press = palette.surface_hover,
        .color_border = palette.border,
        .corner_radius = .all(metrics.defaults.radius_small - 2),
        .padding = .all(6),
        .font = typography.textFont(label, opts.font_size),
    });

    var row = dvui.box(src, .{ .dir = .horizontal }, options);
    defer row.deinit();

    dvui.tabIndexSet(row.data().id, row.data().options.tab_index, row.data().rectScale().r);

    var hovered = false;
    const clicked = dvui.clicked(row.data(), .{ .hovered = &hovered });
    if (clicked) value.* = !value.*;

    const check_size = options.fontGet().textHeight();
    const marker = dvui.spacer(@src(), .{
        .min_size_content = dvui.Size.all(check_size),
        .gravity_y = 0.5,
    });
    const marker_rect = marker.borderRectScale();

    drawMarker(value.*, hovered, marker_rect, palette, options);

    _ = dvui.spacer(@src(), .{ .min_size_content = .width(6) });
    dvui.labelNoFmt(@src(), label, .{}, options.strip().override(.{ .gravity_y = 0.5 }));
    return clicked;
}

fn drawMarker(
    checked: bool,
    hovered: bool,
    rs: dvui.RectScale,
    palette: palette_module.Palette,
    options: dvui.Options,
) void {
    const corner_radius = options.corner_radiusGet().scale(rs.s, dvui.Rect.Physical);
    const border_color = if (hovered) palette.border_hover else palette.border;
    const fill_color = if (checked)
        palette.accent
    else if (hovered)
        palette.surface_hover
    else
        palette.surface_bg;

    rs.r.fill(corner_radius, .{ .color = border_color, .fade = 1 });
    rs.r.insetAll(rs.s).fill(corner_radius, .{ .color = fill_color, .fade = 1 });

    if (checked) {
        const thickness = @max(1, @round(1.5 * rs.s));
        const left = rs.r.x + rs.r.w * 0.25;
        const middle_x = rs.r.x + rs.r.w * 0.44;
        const middle_y = rs.r.y + rs.r.h * 0.68;
        const right = rs.r.x + rs.r.w * 0.78;
        const top = rs.r.y + rs.r.h * 0.31;
        const color = if (palette.text.r > 0x80) palette_module.rgb(0x0b, 0x0d, 0x12) else palette_module.rgb(0xff, 0xff, 0xff);
        dvui.Path.stroke(
            .{ .points = &.{
                .{ .x = left, .y = rs.r.y + rs.r.h * 0.52 },
                .{ .x = middle_x, .y = middle_y },
                .{ .x = right, .y = top },
            } },
            .{ .thickness = thickness, .color = color },
        );
    }
}
