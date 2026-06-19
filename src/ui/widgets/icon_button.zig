const dvui = @import("dvui");
const std = @import("std");

const button = @import("button.zig");
const palette_module = @import("../foundation/palette.zig");
const typography = @import("../foundation/typography.zig");

pub const Result = struct {
    clicked: bool,
    hovered: bool,
    rect: dvui.Rect.Physical,
};

pub const Options = struct {
    icon_size: f32,
    id_extra: usize,
    gap: f32 = 8,
    left_padding: f32 = 10,
    right_padding: f32 = 10,
};

pub fn show(
    src: std.builtin.SourceLocation,
    bytes: []const u8,
    name: []const u8,
    layout: dvui.Options,
    palette: palette_module.Palette,
    style: button.Style,
    opts: Options,
) Result {
    return showWithLabel(src, bytes, name, null, layout, palette, style, opts);
}

pub fn showText(
    src: std.builtin.SourceLocation,
    bytes: []const u8,
    name: []const u8,
    label: []const u8,
    layout: dvui.Options,
    palette: palette_module.Palette,
    style: button.Style,
    opts: Options,
) Result {
    return showWithLabel(src, bytes, name, label, layout, palette, style, opts);
}

fn showWithLabel(
    src: std.builtin.SourceLocation,
    bytes: []const u8,
    name: []const u8,
    label: ?[]const u8,
    layout: dvui.Options,
    palette: palette_module.Palette,
    style: button.Style,
    opts: Options,
) Result {
    var widget: dvui.ButtonWidget = undefined;
    var styled = button.options(layout, palette, style);
    if (label) |text| {
        styled = styled.override(.{ .font = typography.textFont(text, style.font_size orelse layout.fontGet().size) });
    }
    widget.init(src, .{ .draw_focus = false }, styled);
    widget.processEvents();
    widget.drawBackground();

    const crs = widget.data().contentRectScale();
    const icon_size = opts.icon_size * crs.s;
    const text = label orelse "";
    const icon_rect: dvui.Rect.Physical = .{
        .x = if (label == null) crs.r.x + @round((crs.r.w - icon_size) / 2) else crs.r.x + opts.left_padding * crs.s,
        .y = crs.r.y + @round((crs.r.h - icon_size) / 2),
        .w = icon_size,
        .h = icon_size,
    };
    renderPng(bytes, name, .{ .r = icon_rect, .s = crs.s }, widget.style().color(.text));

    if (label != null) {
        const font = typography.textFont(text, style.font_size orelse layout.fontGet().size);
        const text_x = icon_rect.x + icon_rect.w + opts.gap * crs.s;
        const text_rect: dvui.Rect.Physical = .{
            .x = text_x,
            .y = crs.r.y,
            .w = @max(0, crs.r.x + crs.r.w - opts.right_padding * crs.s - text_x),
            .h = crs.r.h,
        };
        const old_clip = dvui.clip(text_rect);
        defer dvui.clipSet(old_clip);
        const text_height = font.textSize(text).h * crs.s;
        dvui.renderText(.{
            .font = font,
            .text = text,
            .rs = .{ .r = text_rect, .s = crs.s },
            .p = .{ .x = text_rect.x, .y = text_rect.y + @round((text_rect.h - text_height) / 2) },
            .color = widget.style().color(.text),
        }) catch {};
    }

    const result: Result = .{
        .clicked = widget.clicked(),
        .hovered = widget.hovered(),
        .rect = widget.data().rectScale().r,
    };
    widget.drawFocus();
    widget.deinit();
    return result;
}

pub fn renderPng(bytes: []const u8, name: []const u8, rs: dvui.RectScale, color: dvui.Color) void {
    const source: dvui.ImageSource = .{ .imageFile = .{
        .bytes = bytes,
        .name = name,
        .interpolation = .linear,
    } };
    dvui.renderImage(source, rs, .{ .colormod = color }) catch {};
}
