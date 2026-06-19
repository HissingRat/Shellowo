const dvui = @import("dvui");
const std = @import("std");

const metrics = @import("../foundation/metrics.zig");
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

pub const WidgetOptions = struct {
    interactive: bool = true,
    touch_drag: bool = false,
    override: dvui.Options = .{},
};

pub const Widget = struct {
    inner: dvui.ButtonWidget,
    palette: palette_module.Palette,
    interactive: bool,

    pub fn init(
        self: *Widget,
        src: std.builtin.SourceLocation,
        layout: dvui.Options,
        palette: palette_module.Palette,
        button_style: Style,
        widget_opts: WidgetOptions,
    ) void {
        self.palette = palette;
        self.interactive = widget_opts.interactive;
        self.inner.init(src, .{
            .draw_focus = false,
            .touch_drag = widget_opts.touch_drag,
        }, options(layout, palette, button_style).override(widget_opts.override));
    }

    pub fn processEvents(self: *Widget) void {
        self.inner.processEvents();
    }

    pub fn processEventsEx(self: *Widget) ?dvui.Event.EventTypes {
        return dvui.clickedEx(self.inner.data(), .{ .hovered = &self.inner.hover });
    }

    pub fn drawBackground(self: *Widget) void {
        drawButtonBackground(&self.inner, self.palette, self.interactive);
    }

    pub fn data(self: *Widget) *dvui.WidgetData {
        return self.inner.data();
    }

    pub fn style(self: *Widget) dvui.Options {
        return self.inner.style();
    }

    pub fn clicked(self: *Widget) bool {
        return self.inner.clicked();
    }

    pub fn hovered(self: *Widget) bool {
        return self.inner.hovered();
    }

    pub fn setHovered(self: *Widget, value: bool) void {
        self.inner.hover = value;
    }

    pub fn deinit(self: *Widget) void {
        self.inner.deinit();
    }
};

pub fn fill(palette: palette_module.Palette, style: Style) dvui.Color {
    return switch (style.state) {
        .selected => switch (style.variant) {
            .ghost, .row, .tab => palette.surface_active.opacity(0.72),
            .solid => switch (style.intent) {
                .neutral => palette.active_bg,
                .primary => palette.accent.opacity(0.22),
                .danger => palette.danger.opacity(0.18),
            },
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
    return typography.withFontSize(opts.override(.{
        .background = true,
        .color_fill = background,
        .color_fill_hover = background,
        .color_fill_press = background,
        .color_text = palette.text,
        .color_text_hover = palette.text,
        .color_text_press = palette.text,
        .color_border = dvui.Color.transparent,
        .border = .all(metrics.defaults.control_border_width),
        .corner_radius = .all(metrics.defaults.radius_small),
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

const LabelWidgetOptions = struct {
    fill_hover: ?dvui.Color = null,
    fill_press: ?dvui.Color = null,
};

fn buttonWidget(
    src: std.builtin.SourceLocation,
    label: []const u8,
    opts: dvui.Options,
    palette: palette_module.Palette,
    style: Style,
    widget_opts: LabelWidgetOptions,
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

    var widget: Widget = undefined;
    widget.init(src, styled_options, palette, style, .{
        .interactive = widget_opts.fill_hover == null,
        .override = styled_options,
    });
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
    widget.deinit();
    return clicked;
}

fn drawButtonBackground(widget: *dvui.ButtonWidget, palette: palette_module.Palette, interactive: bool) void {
    widget.drawBackground();
    if (!interactive) return;

    const opacity: ?f32 = if (dvui.captured(widget.data().id))
        0.24
    else if (widget.hovered())
        0.15
    else
        null;
    const alpha = opacity orelse return;
    const rs = widget.data().backgroundRectScale();
    rs.r.fill(
        widget.data().options.corner_radiusGet().scale(rs.s, dvui.Rect.Physical),
        .{ .color = palette.interaction_overlay.opacity(alpha), .fade = 1 },
    );
}
