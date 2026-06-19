const dvui = @import("dvui");

const palette_module = @import("../foundation/palette.zig");

pub fn app(opts: dvui.Options, palette: palette_module.Palette) dvui.Options {
    return opts.override(.{
        .background = true,
        .color_fill = palette.app_bg,
        .color_text = palette.text,
    });
}

pub fn panel(opts: dvui.Options, palette: palette_module.Palette) dvui.Options {
    return opts.override(.{
        .background = true,
        .color_fill = palette.panel_bg,
        .color_text = palette.text,
        .color_border = palette.border_subtle,
    });
}

pub fn topbar(opts: dvui.Options, palette: palette_module.Palette) dvui.Options {
    return opts.override(.{
        .background = true,
        .color_fill = palette.topbar_bg,
        .color_text = palette.text,
    });
}
