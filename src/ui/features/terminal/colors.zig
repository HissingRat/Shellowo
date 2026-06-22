const dvui = @import("dvui");
const std = @import("std");
const terminal = @import("../../../contracts/terminal_emulator.zig");
const metrics = @import("metrics.zig");
const theme = @import("../../theme.zig");

const selection_background_mix: f32 = 0.42;
const selection_background_darken: f32 = 0.72;

pub fn font(text: []const u8, style: terminal.Style) dvui.Font {
    var result = theme.textFont(text, metrics.font_size);
    if (style.bold) result = result.withWeight(.bold);
    if (style.italic) result = result.withStyle(.italic);
    if (style.underline) result = result.withUnderline(.{});
    if (style.strike) result = result.withStrike(.{});
    return result;
}

pub fn foreground(style: terminal.Style, palette: theme.Palette) dvui.Color {
    if (style.reverse) return backgroundValue(style, palette) orelse palette.terminal_bg;
    return resolve(style.fg, palette.terminal_text);
}

pub fn background(style: terminal.Style, palette: theme.Palette) ?dvui.Color {
    if (style.reverse) return resolve(style.fg, palette.terminal_text);
    return backgroundValue(style, palette);
}

pub fn selectedBackground(background_color: dvui.Color, palette: theme.Palette) dvui.Color {
    return darken(blend(background_color, palette.terminal_selection, selection_background_mix), selection_background_darken);
}

fn backgroundValue(style: terminal.Style, palette: theme.Palette) ?dvui.Color {
    return switch (style.bg) {
        .default => null,
        else => resolve(style.bg, palette.terminal_bg),
    };
}

pub fn blend(a: dvui.Color, b: dvui.Color, t: f32) dvui.Color {
    return .{
        .r = blendChannel(a.r, b.r, t),
        .g = blendChannel(a.g, b.g, t),
        .b = blendChannel(a.b, b.b, t),
        .a = blendChannel(a.a, b.a, t),
    };
}

fn blendChannel(a: u8, b: u8, t: f32) u8 {
    const af = @as(f32, @floatFromInt(a));
    const bf = @as(f32, @floatFromInt(b));
    return @intFromFloat(std.math.clamp(af + (bf - af) * t, 0, 255));
}

fn darken(color: dvui.Color, factor: f32) dvui.Color {
    return .{
        .r = darkenChannel(color.r, factor),
        .g = darkenChannel(color.g, factor),
        .b = darkenChannel(color.b, factor),
        .a = color.a,
    };
}

fn darkenChannel(value: u8, factor: f32) u8 {
    return @intFromFloat(std.math.clamp(@as(f32, @floatFromInt(value)) * factor, 0, 255));
}

fn resolve(color: terminal.Color, default_color: dvui.Color) dvui.Color {
    return switch (color) {
        .default => default_color,
        .rgb => |rgb| .{ .r = rgb.r, .g = rgb.g, .b = rgb.b },
        .indexed => |index| indexed(index),
    };
}

fn indexed(index: u8) dvui.Color {
    if (index < 16) return ansi16[index];
    if (index <= 231) {
        const n = index - 16;
        return .{
            .r = colorCubeValue(n / 36),
            .g = colorCubeValue((n / 6) % 6),
            .b = colorCubeValue(n % 6),
        };
    }
    const value: u8 = 8 + (index - 232) * 10;
    return .{ .r = value, .g = value, .b = value };
}

fn colorCubeValue(component: u8) u8 {
    return if (component == 0) 0 else 55 + component * 40;
}

const ansi16 = [_]dvui.Color{
    .{ .r = 0x1e, .g = 0x1e, .b = 0x1e }, .{ .r = 0xcd, .g = 0x31, .b = 0x31 },
    .{ .r = 0x0d, .g = 0xa7, .b = 0x0d }, .{ .r = 0xe5, .g = 0xe5, .b = 0x10 },
    .{ .r = 0x24, .g = 0x71, .b = 0xc8 }, .{ .r = 0xbc, .g = 0x3f, .b = 0xbc },
    .{ .r = 0x11, .g = 0xa8, .b = 0xcd }, .{ .r = 0xe5, .g = 0xe5, .b = 0xe5 },
    .{ .r = 0x66, .g = 0x66, .b = 0x66 }, .{ .r = 0xf1, .g = 0x4c, .b = 0x4c },
    .{ .r = 0x23, .g = 0xd1, .b = 0x8b }, .{ .r = 0xf5, .g = 0xf5, .b = 0x43 },
    .{ .r = 0x3b, .g = 0x8e, .b = 0xde }, .{ .r = 0xd6, .g = 0x70, .b = 0xd6 },
    .{ .r = 0x29, .g = 0xb8, .b = 0xdb }, .{ .r = 0xff, .g = 0xff, .b = 0xff },
};
