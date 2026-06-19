const dvui = @import("dvui");
const std = @import("std");

const palette_module = @import("../foundation/palette.zig");
const typography = @import("../foundation/typography.zig");

pub const Intent = enum {
    neutral,
    primary,
    danger,
};

pub const State = enum {
    normal,
    selected,
};

pub const Variant = enum {
    solid,
    ghost,
    row,
    tab,
};

pub const Style = struct {
    intent: Intent = .neutral,
    state: State = .normal,
    variant: Variant = .solid,
    font_size: ?f32 = null,
    text_align_x: ?f32 = null,
};

pub fn fill(palette: palette_module.Palette, style: Style) dvui.Color {
    return switch (style.state) {
        .selected => switch (style.variant) {
            .ghost, .row, .tab => palette.surface_active,
            .solid => palette.active_bg,
        },
        .normal => switch (style.variant) {
            .ghost, .tab => dvui.Color.transparent,
            .row => palette.surface_bg,
            .solid => switch (style.intent) {
                .neutral => palette.button_bg,
                .primary => palette.accent,
                .danger => palette.danger,
            },
        },
    };
}

pub fn options(opts: dvui.Options, palette: palette_module.Palette, style: Style) dvui.Options {
    const background = fill(palette, style);
    const hover = switch (style.variant) {
        .solid => palette.button_hover,
        .ghost, .row, .tab => palette.surface_hover,
    };
    const press = switch (style.variant) {
        .solid => palette.active_bg,
        .ghost, .row, .tab => palette.surface_active,
    };
    return typography.withFontSize(opts.override(.{
        .background = true,
        .color_fill = background,
        .color_fill_hover = hover,
        .color_fill_press = press,
        .color_text = palette.text,
        .color_text_hover = palette.text,
        .color_text_press = palette.text,
        .color_border = palette.border,
    }), style.font_size);
}

pub fn show(src: std.builtin.SourceLocation, label: []const u8, opts: dvui.Options, palette: palette_module.Palette, style: Style) bool {
    return buttonWidget(src, label, opts, palette, style, .{});
}

pub fn showStatic(src: std.builtin.SourceLocation, label: []const u8, opts: dvui.Options, palette: palette_module.Palette, style: Style) bool {
    const background = fill(palette, style);
    return buttonWidget(src, label, opts, palette, style, .{
        .fill_hover = background,
        .fill_press = background,
    });
}

const WidgetOptions = struct {
    fill_hover: ?dvui.Color = null,
    fill_press: ?dvui.Color = null,
};

fn buttonWidget(
    src: std.builtin.SourceLocation,
    label: []const u8,
    opts: dvui.Options,
    palette: palette_module.Palette,
    style: Style,
    widget_opts: WidgetOptions,
) bool {
    var styled_options = options(opts, palette, style).override(.{
        .font = typography.textFont(label, style.font_size orelse opts.fontGet().size),
    });
    if (widget_opts.fill_hover) |hover| {
        styled_options = styled_options.override(.{ .color_fill_hover = hover });
    }
    if (widget_opts.fill_press) |press| {
        styled_options = styled_options.override(.{ .color_fill_press = press });
    }

    var widget: dvui.ButtonWidget = undefined;
    widget.init(src, .{ .draw_focus = false }, styled_options);
    widget.processEvents();
    widget.drawBackground();

    const label_options = opts.strip().override(widget.style()).override(.{
        .expand = .both,
        .gravity_x = 0,
        .gravity_y = 0.5,
    });
    dvui.labelNoFmt(@src(), label, .{
        .align_x = style.text_align_x orelse 0.5,
        .align_y = 0.5,
    }, label_options);

    const clicked = widget.clicked();
    widget.drawFocus();
    widget.deinit();
    return clicked;
}
