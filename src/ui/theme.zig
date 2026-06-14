const dvui = @import("dvui");
const std = @import("std");

pub const zed_font_family = "Zed Mono Extended";
pub const cjk_font_family = "Noto Sans CJK SC";

pub const ThemeMode = enum {
    dark,
    light,

    pub fn label(self: ThemeMode) []const u8 {
        return switch (self) {
            .dark => "Dark",
            .light => "Light",
        };
    }
};

pub const Palette = struct {
    app_bg: dvui.Color,
    topbar_bg: dvui.Color,
    panel_bg: dvui.Color,
    panel_alt: dvui.Color,
    surface_bg: dvui.Color,
    surface_hover: dvui.Color,
    surface_active: dvui.Color,
    button_bg: dvui.Color,
    button_hover: dvui.Color,
    active_bg: dvui.Color,
    text: dvui.Color,
    muted_text: dvui.Color,
    text_subtle: dvui.Color,
    border: dvui.Color,
    border_subtle: dvui.Color,
    accent: dvui.Color,
    danger: dvui.Color,

    pub fn forMode(mode: ThemeMode) Palette {
        return switch (mode) {
            .dark => dark,
            .light => light,
        };
    }
};

pub const FontSizes = struct {
    body: f32 = 14,
    heading: f32 = 15,
    title: f32 = 22,
    control: f32 = 11,
    tab: f32 = 11,
    close: f32 = 10,
};

pub const font_sizes: FontSizes = .{};

pub fn textFont(text: []const u8, size: f32) dvui.Font {
    const family = if (needsCjkFont(text)) cjk_font_family else zed_font_family;
    return dvui.Font.theme(.body).withFamily(family).withSize(size);
}

pub fn cjkFont(size: f32) dvui.Font {
    return dvui.Font.theme(.body).withFamily(cjk_font_family).withSize(size);
}

pub fn needsCjkFont(text: []const u8) bool {
    for (text) |byte| {
        if (byte >= 0x80) return true;
    }
    return false;
}

pub fn topBarTextOffset(text: []const u8) f32 {
    return if (needsCjkFont(text)) 1 else 2;
}

pub const dark = Palette{
    .app_bg = c(0x0b, 0x0d, 0x12),
    .topbar_bg = c(0x10, 0x12, 0x18),
    .panel_bg = c(0x12, 0x15, 0x1c),
    .panel_alt = c(0x16, 0x1a, 0x23),
    .surface_bg = c(0x0f, 0x12, 0x18),
    .surface_hover = c(0x18, 0x1d, 0x27),
    .surface_active = c(0x22, 0x2a, 0x38),
    .button_bg = c(0x16, 0x1a, 0x23),
    .button_hover = c(0x1d, 0x24, 0x30),
    .active_bg = c(0x25, 0x2f, 0x3f),
    .text = c(0xdd, 0xe3, 0xec),
    .muted_text = c(0xa3, 0xaa, 0xb6),
    .text_subtle = c(0x6f, 0x78, 0x86),
    .border = c(0x2b, 0x32, 0x3d),
    .border_subtle = c(0x18, 0x1d, 0x25),
    .accent = c(0x93, 0xb7, 0xff),
    .danger = c(0xe0, 0x74, 0x74),
};

pub const light = Palette{
    .app_bg = c(0xf4, 0xf5, 0xf7),
    .topbar_bg = c(0xd7, 0xda, 0xde),
    .panel_bg = c(0xff, 0xff, 0xff),
    .panel_alt = c(0xe6, 0xe8, 0xeb),
    .surface_bg = c(0xff, 0xff, 0xff),
    .surface_hover = c(0xeb, 0xee, 0xf2),
    .surface_active = c(0xd9, 0xe3, 0xf0),
    .button_bg = c(0xd4, 0xd8, 0xdd),
    .button_hover = c(0xc6, 0xcc, 0xd3),
    .active_bg = c(0xb8, 0xc7, 0xd9),
    .text = c(0x1e, 0x23, 0x29),
    .muted_text = c(0x5b, 0x64, 0x70),
    .text_subtle = c(0x86, 0x90, 0x9d),
    .border = c(0x8e, 0x99, 0xa6),
    .border_subtle = c(0xd8, 0xdc, 0xe2),
    .accent = c(0x24, 0x66, 0xb8),
    .danger = c(0xb8, 0x34, 0x34),
};

pub fn c(r: u8, g: u8, b: u8) dvui.Color {
    return .{ .r = r, .g = g, .b = b };
}

pub fn app(opts: dvui.Options, p: Palette) dvui.Options {
    return opts.override(.{ .background = true, .color_fill = p.app_bg, .color_text = p.text });
}

pub fn panel(opts: dvui.Options, p: Palette) dvui.Options {
    return opts.override(.{ .background = true, .color_fill = p.panel_bg, .color_text = p.text, .color_border = p.border_subtle });
}

pub fn topbar(opts: dvui.Options, p: Palette) dvui.Options {
    return opts.override(.{ .background = true, .color_fill = p.topbar_bg, .color_text = p.text });
}

pub fn withFontSize(opts: dvui.Options, size: ?f32) dvui.Options {
    const value = size orelse return opts;
    return opts.override(.{ .font = opts.fontGet().withSize(value) });
}

pub fn withThemeFontSize(opts: dvui.Options, which: dvui.Font.ThemeFontName, size: f32) dvui.Options {
    return opts.override(.{ .font = dvui.Font.theme(which).withSize(size) });
}

pub const ButtonIntent = enum {
    neutral,
    primary,
    danger,
};

pub const ButtonState = enum {
    normal,
    selected,
};

pub const ButtonVariant = enum {
    solid,
    ghost,
    row,
    tab,
};

pub const ButtonStyle = struct {
    intent: ButtonIntent = .neutral,
    state: ButtonState = .normal,
    variant: ButtonVariant = .solid,
    font_size: ?f32 = null,
    text_align_x: ?f32 = null,
};

pub fn buttonFill(p: Palette, style: ButtonStyle) dvui.Color {
    return switch (style.state) {
        .selected => switch (style.variant) {
            .ghost, .row, .tab => p.surface_active,
            .solid => p.active_bg,
        },
        .normal => switch (style.variant) {
            .ghost, .tab => dvui.Color.transparent,
            .row => p.surface_bg,
            .solid => switch (style.intent) {
                .neutral => p.button_bg,
                .primary => p.accent,
                .danger => p.danger,
            },
        },
    };
}

pub fn buttonOptions(opts: dvui.Options, p: Palette, style: ButtonStyle) dvui.Options {
    const fill = buttonFill(p, style);
    const hover = switch (style.variant) {
        .solid => p.button_hover,
        .ghost, .row, .tab => p.surface_hover,
    };
    const press = switch (style.variant) {
        .solid => p.active_bg,
        .ghost, .row, .tab => p.surface_active,
    };
    return withFontSize(opts.override(.{
        .background = true,
        .color_fill = fill,
        .color_fill_hover = hover,
        .color_fill_press = press,
        .color_text = p.text,
        .color_text_hover = p.text,
        .color_text_press = p.text,
        .color_border = p.border,
    }), style.font_size);
}

pub fn button(src: std.builtin.SourceLocation, label: []const u8, opts: dvui.Options, p: Palette, style: ButtonStyle) bool {
    return buttonWidget(src, label, opts, p, style, .{});
}

pub fn buttonNoHoverAndPress(src: std.builtin.SourceLocation, label: []const u8, opts: dvui.Options, p: Palette, style: ButtonStyle) bool {
    const fill = buttonFill(p, style);
    return buttonWidget(src, label, opts, p, style, .{
        .fill_hover = fill,
        .fill_press = fill,
    });
}

const ButtonWidgetOptions = struct {
    fill_hover: ?dvui.Color = null,
    fill_press: ?dvui.Color = null,
};

fn buttonWidget(
    src: std.builtin.SourceLocation,
    label: []const u8,
    opts: dvui.Options,
    p: Palette,
    style: ButtonStyle,
    widget_opts: ButtonWidgetOptions,
) bool {
    var options = buttonOptions(opts, p, style).override(.{
        .font = textFont(label, style.font_size orelse opts.fontGet().size),
    });
    if (widget_opts.fill_hover) |fill| {
        options = options.override(.{ .color_fill_hover = fill });
    }
    if (widget_opts.fill_press) |fill| {
        options = options.override(.{ .color_fill_press = fill });
    }
    var bw: dvui.ButtonWidget = undefined;
    bw.init(src, .{ .draw_focus = false }, options);
    bw.processEvents();
    bw.drawBackground();

    const label_options = opts.strip().override(bw.style()).override(.{
        .expand = .both,
        .gravity_x = 0,
        .gravity_y = 0.5,
    });
    dvui.labelNoFmt(@src(), label, .{
        .align_x = style.text_align_x orelse 0.5,
        .align_y = 0.5,
    }, label_options);

    const click = bw.clicked();
    bw.drawFocus();
    bw.deinit();
    return click;
}
