//! Compatibility facade for the Shellow UI system.
//!
//! New reusable visual behavior belongs in `foundation/`, `widgets/`, or
//! `layouts/`. Existing feature UI can keep importing this module while it is
//! migrated in small, buildable batches.

const dvui = @import("dvui");
const std = @import("std");

const button_widget = @import("widgets/button.zig");
const checkbox_widget = @import("widgets/checkbox.zig");
const menu_item_widget = @import("widgets/menu_item.zig");
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

pub const ButtonIntent = button_widget.Intent;
pub const ButtonState = button_widget.State;
pub const ButtonVariant = button_widget.Variant;
pub const ButtonStyle = button_widget.Style;
pub const buttonFill = button_widget.fill;
pub const buttonOptions = button_widget.options;
pub const CheckboxOptions = checkbox_widget.Options;
pub const MenuItemOptions = menu_item_widget.Options;

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

pub fn checkbox(src: std.builtin.SourceLocation, value: *bool, label: []const u8, palette: Palette, opts: CheckboxOptions) bool {
    return checkbox_widget.show(src, value, label, palette, opts);
}

pub fn menuItem(src: std.builtin.SourceLocation, label: []const u8, palette: Palette, opts: MenuItemOptions) ?dvui.Rect.Natural {
    return menu_item_widget.show(src, label, palette, opts);
}
