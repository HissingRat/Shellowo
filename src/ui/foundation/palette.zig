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
    popup_bg: dvui.Color,
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
    border_hover: dvui.Color,
    border_selected: dvui.Color,
    interaction_overlay: dvui.Color,
    accent: dvui.Color,
    network_tx: dvui.Color,
    network_rx: dvui.Color,
    folder_icon: dvui.Color,
    file_icon: dvui.Color,
    terminal_bg: dvui.Color,
    terminal_text: dvui.Color,
    terminal_selection: dvui.Color,
    warning: dvui.Color,
    danger: dvui.Color,

    pub fn forMode(mode: ThemeMode) Palette {
        return switch (mode) {
            .dark => dark,
            .light => light,
        };
    }
};

pub const dark = Palette{
    .app_bg = rgb(0x0f, 0x0f, 0x10),
    .topbar_bg = rgb(0x12, 0x12, 0x13),
    .panel_bg = rgb(0x16, 0x16, 0x18),
    .panel_alt = rgb(0x1b, 0x1b, 0x1e),
    .popup_bg = rgb(0x20, 0x20, 0x23),
    .surface_bg = rgb(0x12, 0x12, 0x14),
    .surface_hover = rgb(0x27, 0x27, 0x2a),
    .surface_active = rgb(0x31, 0x31, 0x35),
    .button_bg = rgb(0x24, 0x24, 0x27),
    .button_hover = rgb(0x30, 0x30, 0x34),
    .active_bg = rgb(0x38, 0x38, 0x3d),
    .text = rgb(0xe5, 0xe5, 0xe7),
    .muted_text = rgb(0xa5, 0xa5, 0xaa),
    .text_subtle = rgb(0x75, 0x75, 0x7c),
    .border = rgb(0x3a, 0x3a, 0x3f),
    .border_subtle = rgb(0x25, 0x25, 0x28),
    .border_hover = rgb(0x55, 0x55, 0x5c),
    .border_selected = rgb(0x82, 0xa7, 0xed),
    .interaction_overlay = rgb(0xff, 0xff, 0xff),
    .accent = rgb(0x82, 0xa7, 0xed),
    .network_tx = rgb(0x82, 0xa7, 0xed),
    .network_rx = rgb(0x58, 0xc4, 0xa4),
    .folder_icon = rgb(0x86, 0xa9, 0xeb),
    .file_icon = rgb(0xb0, 0xb7, 0xc3),
    .terminal_bg = rgb(0x0f, 0x0f, 0x10),
    .terminal_text = rgb(0xe5, 0xe5, 0xe7),
    .terminal_selection = rgb(0x31, 0x31, 0x35),
    .warning = rgb(0xd6, 0xa8, 0x5f),
    .danger = rgb(0xd9, 0x6c, 0x75),
};

pub const light = Palette{
    .app_bg = rgb(0xf1, 0xf2, 0xf4),
    .topbar_bg = rgb(0xe2, 0xe4, 0xe7),
    .panel_bg = rgb(0xf8, 0xf8, 0xf9),
    .panel_alt = rgb(0xea, 0xec, 0xf0),
    .popup_bg = rgb(0xf7, 0xf7, 0xf8),
    .surface_bg = rgb(0xff, 0xff, 0xff),
    .surface_hover = rgb(0xec, 0xee, 0xf1),
    .surface_active = rgb(0xdf, 0xe6, 0xf2),
    .button_bg = rgb(0xe5, 0xe7, 0xea),
    .button_hover = rgb(0xd9, 0xdc, 0xe1),
    .active_bg = rgb(0xcd, 0xd8, 0xe8),
    .text = rgb(0x25, 0x27, 0x2b),
    .muted_text = rgb(0x62, 0x68, 0x73),
    .text_subtle = rgb(0x8b, 0x92, 0x9d),
    .border = rgb(0xbe, 0xc3, 0xca),
    .border_subtle = rgb(0xd9, 0xdc, 0xe1),
    .border_hover = rgb(0x96, 0x9d, 0xa7),
    .border_selected = rgb(0x4f, 0x79, 0xbd),
    .interaction_overlay = rgb(0x4f, 0x79, 0xbd),
    .accent = rgb(0x4f, 0x79, 0xbd),
    .network_tx = rgb(0x47, 0x76, 0xc5),
    .network_rx = rgb(0x27, 0x8a, 0x75),
    .folder_icon = rgb(0x4b, 0x78, 0xbd),
    .file_icon = rgb(0x70, 0x77, 0x82),
    .terminal_bg = rgb(0x1E, 0x23, 0x2B),
    .terminal_text = rgb(0xe4, 0xe6, 0xe9),
    .terminal_selection = rgb(0x34, 0x43, 0x5c),
    .warning = rgb(0x9a, 0x62, 0x08),
    .danger = rgb(0xb2, 0x3b, 0x43),
};

pub fn rgb(r: u8, g: u8, b: u8) dvui.Color {
    return .{ .r = r, .g = g, .b = b };
}
