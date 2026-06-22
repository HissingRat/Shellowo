const dvui = @import("dvui");

pub const zed_font_family = "Zed Mono Extended";
pub const cjk_font_family = "Noto Sans CJK SC";

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
    _ = text;
    return dvui.Font.theme(.body).withFamily(zed_font_family).withSize(size);
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

pub fn withFontSize(opts: dvui.Options, size: ?f32) dvui.Options {
    const value = size orelse return opts;
    return opts.override(.{ .font = opts.fontGet().withSize(value) });
}

pub fn withThemeFontSize(opts: dvui.Options, which: dvui.Font.ThemeFontName, size: f32) dvui.Options {
    return opts.override(.{ .font = dvui.Font.theme(which).withSize(size) });
}
