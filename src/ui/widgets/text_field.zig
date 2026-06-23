const dvui = @import("dvui");
const std = @import("std");

const metrics = @import("../foundation/metrics.zig");
const palette_module = @import("../foundation/palette.zig");
const typography = @import("../foundation/typography.zig");

pub const Options = struct {
    id_extra: usize,
    expand: bool = true,
    field_height: f32 = metrics.defaults.control_height,
    font_size: f32 = 15,
};

pub const Entry = struct {
    theme: dvui.Theme,
    inner: *dvui.TextEntryWidget,

    pub fn init(
        self: *Entry,
        src: std.builtin.SourceLocation,
        init_opts: dvui.TextEntryWidget.InitOptions,
        layout: dvui.Options,
        palette: palette_module.Palette,
    ) void {
        self.theme = entryTheme();
        self.inner = dvui.textEntry(src, init_opts, entryOptions(layout, palette).override(.{ .theme = &self.theme }));
        drawFocusBorder(self.inner.data(), palette);
    }

    pub fn data(self: *Entry) *dvui.WidgetData {
        return self.inner.data();
    }

    pub fn enterPressed(self: *const Entry) bool {
        return self.inner.enter_pressed;
    }

    pub fn textChanged(self: *const Entry) bool {
        return self.inner.text_changed;
    }

    pub fn deinit(self: *Entry) void {
        self.inner.deinit();
    }
};

pub fn entryOptions(layout: dvui.Options, palette: palette_module.Palette) dvui.Options {
    return layout.override(.{
        .background = true,
        .color_fill = layout.color_fill orelse palette.surface_bg,
        .color_fill_hover = layout.color_fill orelse palette.surface_bg,
        .color_fill_press = layout.color_fill orelse palette.surface_bg,
        .color_text = layout.color_text orelse palette.text,
        .color_border = layout.color_border orelse palette.border,
        .border = layout.border orelse .all(metrics.defaults.control_border_width),
        .corner_radius = layout.corner_radius orelse .all(metrics.defaults.radius_small),
    });
}

pub fn number(
    src: std.builtin.SourceLocation,
    comptime T: type,
    init_opts: dvui.TextEntryNumberInitOptions(T),
    layout: dvui.Options,
    palette: palette_module.Palette,
) dvui.TextEntryNumberResult(T) {
    var entry_theme = entryTheme();
    return dvui.textEntryNumber(src, T, init_opts, entryOptions(layout, palette).override(.{ .theme = &entry_theme }));
}

pub fn entryTheme() dvui.Theme {
    var entry_theme = dvui.themeGet();
    entry_theme.focus = dvui.Color.transparent;
    return entry_theme;
}

pub fn drawFocusBorder(data: *const dvui.WidgetData, palette: palette_module.Palette) void {
    if (data.id != dvui.focusedWidgetId() or !data.visible()) return;
    const rs = data.borderRectScale();
    rs.r.stroke(
        data.options.corner_radiusGet().scale(rs.s, dvui.Rect.Physical),
        .{ .thickness = rs.s, .color = palette.border_selected, .after = true },
    );
}

pub fn show(
    src: std.builtin.SourceLocation,
    label: []const u8,
    buffer: []u8,
    palette: palette_module.Palette,
    opts: Options,
) void {
    var cell = dvui.box(src, .{ .dir = .vertical }, .{
        .expand = if (opts.expand) .horizontal else .none,
        .margin = .{ .y = 3, .h = 3 },
        .id_extra = opts.id_extra,
    });
    defer cell.deinit();

    dvui.label(@src(), "{s}", .{label}, .{
        .color_text = palette.muted_text,
        .font = typography.textFont(label, opts.font_size),
        .id_extra = opts.id_extra + 1,
    });
    var entry: Entry = undefined;
    entry.init(@src(), .{ .text = .{ .buffer = buffer } }, .{
        .expand = .horizontal,
        .min_size_content = .height(opts.field_height),
        .font = typography.cjkFont(opts.font_size),
        .corner_radius = .all(metrics.defaults.radius_small),
        .padding = .{ .x = 8, .w = 8, .y = 5, .h = 5 },
        .id_extra = opts.id_extra + 2,
    }, palette);
    entry.deinit();
}
