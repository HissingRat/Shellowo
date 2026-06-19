const metrics_module = @import("metrics.zig");
const palette_module = @import("palette.zig");
const typography_module = @import("typography.zig");

pub const Theme = struct {
    palette: palette_module.Palette,
    metrics: metrics_module.Metrics = metrics_module.defaults,
    font_sizes: typography_module.FontSizes = typography_module.font_sizes,

    pub fn forMode(mode: palette_module.ThemeMode) Theme {
        return .{ .palette = palette_module.Palette.forMode(mode) };
    }
};
