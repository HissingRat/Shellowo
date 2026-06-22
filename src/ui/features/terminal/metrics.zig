const dvui = @import("dvui");
const std = @import("std");
const terminal = @import("../../../contracts/terminal_emulator.zig");
const theme = @import("../../theme.zig");

pub const font_size: f32 = 10;
pub const default_line_height: f32 = 18;
pub const default_cjk_baseline_lift: f32 = 2;
pub const cursor_underline_height: f32 = 2;
pub const cursor_underline_lift: f32 = 2;

pub const Metrics = struct {
    cell_width: f32,
    line_height: f32 = default_line_height,
    glyph_height: f32,
    cjk_baseline_lift: f32 = default_cjk_baseline_lift,

    pub fn current() Metrics {
        const font = theme.textFont("M", font_size);
        const measured = font.textSize("M");
        return .{
            .cell_width = @max(measured.w, font_size * 0.6),
            .glyph_height = measured.h,
        };
    }

    pub fn gridSize(self: Metrics, width: f32, height: f32, min_cols: u16, min_rows: u16) terminal.Size {
        return .{
            .cols = dimensionToCells(width / self.cell_width, min_cols),
            .rows = dimensionToCells(height / self.line_height, min_rows),
        };
    }

    pub fn textRect(self: Metrics, crs: dvui.RectScale, row: f32) dvui.Rect.Physical {
        return .{
            .x = crs.r.x,
            .y = crs.r.y + row * self.line_height * crs.s,
            .w = crs.r.w,
            .h = self.line_height * crs.s,
        };
    }

    pub fn cellRect(self: Metrics, crs: dvui.RectScale, row: f32, col: u16, width: u16) dvui.Rect.Physical {
        const text_rect = self.textRect(crs, row);
        return .{
            .x = text_rect.x + @as(f32, @floatFromInt(col)) * self.cell_width * crs.s,
            .y = text_rect.y,
            .w = @as(f32, @floatFromInt(width)) * self.cell_width * crs.s,
            .h = text_rect.h,
        };
    }

    pub fn pointToCell(self: Metrics, rel_x: f32, rel_y: f32, scale: f32, rows: usize, cols: u16) struct { row: usize, col: u16 } {
        const safe_scale = if (scale > 0) scale else 1;
        const row: usize = if (rows == 0)
            0
        else
            @intFromFloat(@min(
                @floor(@max(0, rel_y) / (self.line_height * safe_scale)),
                @as(f32, @floatFromInt(rows - 1)),
            ));
        const col: u16 = if (cols == 0)
            0
        else
            @intFromFloat(@min(
                @floor(@max(0, rel_x) / (self.cell_width * safe_scale)),
                @as(f32, @floatFromInt(cols)),
            ));
        return .{ .row = row, .col = col };
    }

    pub fn cursorRect(self: Metrics, crs: dvui.RectScale, row: usize, col: u16) dvui.Rect.Physical {
        const cell = self.cellRect(crs, @floatFromInt(row), col, 1);
        return .{
            .x = cell.x,
            .y = cell.y + self.glyph_height * crs.s - (cursor_underline_height + cursor_underline_lift) * crs.s,
            .w = @max(1, self.cell_width * crs.s * 0.8),
            .h = @max(1, cursor_underline_height * crs.s),
        };
    }
};

fn dimensionToCells(value: f32, min: u16) u16 {
    if (value <= @as(f32, @floatFromInt(min))) return min;
    const floored = @floor(value);
    const max_u16_float = @as(f32, @floatFromInt(std.math.maxInt(u16)));
    return @intFromFloat(@min(floored, max_u16_float));
}

test "terminal metrics keep grid and hit testing consistent" {
    const metrics = Metrics{ .cell_width = 8, .line_height = 16, .glyph_height = 10 };
    try std.testing.expectEqual(terminal.Size{ .cols = 10, .rows = 5 }, metrics.gridSize(80, 80, 1, 1));
    const point = metrics.pointToCell(17, 33, 1, 5, 10);
    try std.testing.expectEqual(@as(usize, 2), point.row);
    try std.testing.expectEqual(@as(u16, 2), point.col);
}

test "terminal metrics clamp grid to product minimums" {
    const metrics = Metrics{ .cell_width = 8, .line_height = 16, .glyph_height = 10 };
    try std.testing.expectEqual(terminal.Size{ .cols = 20, .rows = 5 }, metrics.gridSize(4, 4, 20, 5));
}
