//! Compatibility facade for the Shellow UI system.
//!
//! New reusable visual behavior belongs in `foundation/`, `widgets/`, or
//! `layouts/`. Existing feature UI can keep importing this module while it is
//! migrated in small, buildable batches.

const dvui = @import("dvui");
const std = @import("std");

const button_widget = @import("widgets/button.zig");
const checkbox_widget = @import("widgets/checkbox.zig");
const icon_button_widget = @import("widgets/icon_button.zig");
const menu_item_widget = @import("widgets/menu_item.zig");
const progress_widget = @import("widgets/progress.zig");
const text_field_widget = @import("widgets/text_field.zig");
const palette_module = @import("foundation/palette.zig");
const surface = @import("layouts/surface.zig");
const typography = @import("foundation/typography.zig");

pub const ThemeMode = palette_module.ThemeMode;
pub const Palette = palette_module.Palette;
pub const dark = palette_module.dark;
pub const light = palette_module.light;
pub const c = palette_module.rgb;

pub const zed_font_family = typography.zed_font_family;
pub const cjk_font_family = typography.cjk_font_family;
pub const FontSizes = typography.FontSizes;
pub const font_sizes = typography.font_sizes;
pub const textFont = typography.textFont;
pub const cjkFont = typography.cjkFont;
pub const needsCjkFont = typography.needsCjkFont;
pub const topBarTextOffset = typography.topBarTextOffset;
pub const withFontSize = typography.withFontSize;
pub const withThemeFontSize = typography.withThemeFontSize;

pub const ButtonStyle = button_widget.Style;
pub const ButtonWidget = button_widget.Widget;
pub const CheckboxOptions = checkbox_widget.Options;
pub const IconButtonOptions = icon_button_widget.Options;
pub const IconButtonResult = icon_button_widget.Result;
pub const MenuItemOptions = menu_item_widget.Options;
pub const ProgressOptions = progress_widget.Options;
pub const ProgressState = progress_widget.State;
pub const TextEntry = text_field_widget.Entry;
pub const TextFieldOptions = text_field_widget.Options;

pub fn app(opts: dvui.Options, palette: Palette) dvui.Options {
    return surface.app(opts, palette);
}

pub fn panel(opts: dvui.Options, palette: Palette) dvui.Options {
    return surface.panel(opts, palette);
}

pub fn topbar(opts: dvui.Options, palette: Palette) dvui.Options {
    return surface.topbar(opts, palette);
}

pub fn button(src: std.builtin.SourceLocation, label: []const u8, opts: dvui.Options, palette: Palette, style: ButtonStyle) bool {
    return button_widget.show(src, label, opts, palette, style);
}

pub fn buttonNoHoverAndPress(src: std.builtin.SourceLocation, label: []const u8, opts: dvui.Options, palette: Palette, style: ButtonStyle) bool {
    return button_widget.showStatic(src, label, opts, palette, style);
}

pub fn textEntry(
    src: std.builtin.SourceLocation,
    entry: *TextEntry,
    init_opts: dvui.TextEntryWidget.InitOptions,
    opts: dvui.Options,
    palette: Palette,
) void {
    entry.init(src, init_opts, opts, palette);
}

pub fn textEntryNumber(
    src: std.builtin.SourceLocation,
    comptime T: type,
    init_opts: dvui.TextEntryNumberInitOptions(T),
    opts: dvui.Options,
    palette: Palette,
) dvui.TextEntryNumberResult(T) {
    return text_field_widget.number(src, T, init_opts, opts, palette);
}

pub fn textField(src: std.builtin.SourceLocation, label: []const u8, buffer: []u8, palette: Palette, opts: TextFieldOptions) void {
    text_field_widget.show(src, label, buffer, palette, opts);
}

pub fn progress(src: std.builtin.SourceLocation, value: f32, palette: Palette, opts: ProgressOptions) void {
    progress_widget.show(src, value, palette, opts);
}

pub fn checkbox(src: std.builtin.SourceLocation, value: *bool, label: []const u8, palette: Palette, opts: CheckboxOptions) bool {
    return checkbox_widget.show(src, value, label, palette, opts);
}

pub fn iconButton(
    src: std.builtin.SourceLocation,
    bytes: []const u8,
    name: []const u8,
    opts: dvui.Options,
    palette: Palette,
    style: ButtonStyle,
    icon_opts: IconButtonOptions,
) IconButtonResult {
    return icon_button_widget.show(src, bytes, name, opts, palette, style, icon_opts);
}

pub fn iconButtonText(
    src: std.builtin.SourceLocation,
    bytes: []const u8,
    name: []const u8,
    label: []const u8,
    opts: dvui.Options,
    palette: Palette,
    style: ButtonStyle,
    icon_opts: IconButtonOptions,
) IconButtonResult {
    return icon_button_widget.showText(src, bytes, name, label, opts, palette, style, icon_opts);
}

pub fn renderPng(bytes: []const u8, name: []const u8, rs: dvui.RectScale, color: dvui.Color) void {
    icon_button_widget.renderPng(bytes, name, rs, color);
}

pub fn menuItem(src: std.builtin.SourceLocation, label: []const u8, palette: Palette, opts: MenuItemOptions) ?dvui.Rect.Natural {
    return menu_item_widget.show(src, label, palette, opts);
}
