const dvui = @import("dvui");

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

pub const dark = Palette{
    .app_bg = rgb(0x0b, 0x0d, 0x12),
    .topbar_bg = rgb(0x10, 0x12, 0x18),
    .panel_bg = rgb(0x12, 0x15, 0x1c),
    .panel_alt = rgb(0x16, 0x1a, 0x23),
    .surface_bg = rgb(0x0f, 0x12, 0x18),
    .surface_hover = rgb(0x18, 0x1d, 0x27),
    .surface_active = rgb(0x22, 0x2a, 0x38),
    .button_bg = rgb(0x16, 0x1a, 0x23),
    .button_hover = rgb(0x1d, 0x24, 0x30),
    .active_bg = rgb(0x25, 0x2f, 0x3f),
    .text = rgb(0xdd, 0xe3, 0xec),
    .muted_text = rgb(0xa3, 0xaa, 0xb6),
    .text_subtle = rgb(0x6f, 0x78, 0x86),
    .border = rgb(0x2b, 0x32, 0x3d),
    .border_subtle = rgb(0x18, 0x1d, 0x25),
    .accent = rgb(0x93, 0xb7, 0xff),
    .danger = rgb(0xe0, 0x74, 0x74),
};

pub const light = Palette{
    .app_bg = rgb(0xf4, 0xf5, 0xf7),
    .topbar_bg = rgb(0xd7, 0xda, 0xde),
    .panel_bg = rgb(0xff, 0xff, 0xff),
    .panel_alt = rgb(0xe6, 0xe8, 0xeb),
    .surface_bg = rgb(0xff, 0xff, 0xff),
    .surface_hover = rgb(0xeb, 0xee, 0xf2),
    .surface_active = rgb(0xd9, 0xe3, 0xf0),
    .button_bg = rgb(0xd4, 0xd8, 0xdd),
    .button_hover = rgb(0xc6, 0xcc, 0xd3),
    .active_bg = rgb(0xb8, 0xc7, 0xd9),
    .text = rgb(0x1e, 0x23, 0x29),
    .muted_text = rgb(0x5b, 0x64, 0x70),
    .text_subtle = rgb(0x86, 0x90, 0x9d),
    .border = rgb(0x8e, 0x99, 0xa6),
    .border_subtle = rgb(0xd8, 0xdc, 0xe2),
    .accent = rgb(0x24, 0x66, 0xb8),
    .danger = rgb(0xb8, 0x34, 0x34),
};

pub fn rgb(r: u8, g: u8, b: u8) dvui.Color {
    return .{ .r = r, .g = g, .b = b };
}
