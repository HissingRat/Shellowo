const std = @import("std");
const dvui = @import("dvui");

const remote_file = @import("../../../core/remote_file.zig");
const theme = @import("../../theme.zig");

const panel_width: f32 = 420;
const panel_height: f32 = 270;
const header_height: f32 = 30;
const footer_height: f32 = 42;
const row_height: f32 = 26;
const label_width: f32 = 92;
const path_max_len: usize = 768;
const name_max_len: usize = 256;

pub const State = struct {
    open: bool = false,
    path: [path_max_len]u8 = undefined,
    path_len: usize = 0,
    name: [name_max_len]u8 = undefined,
    name_len: usize = 0,
    mode_text: [8]u8 = std.mem.zeroes([8]u8),
    bits: [9]bool = [_]bool{false} ** 9,
    error_text: [64]u8 = undefined,
    error_len: usize = 0,

    pub fn openFor(self: *State, entry: remote_file.RemoteFileEntry) void {
        const path_len = @min(self.path.len, entry.full_path.len);
        if (path_len > 0) @memcpy(self.path[0..path_len], entry.full_path[0..path_len]);
        self.path_len = path_len;
        const name_len = @min(self.name.len, entry.name.len);
        if (name_len > 0) @memcpy(self.name[0..name_len], entry.name[0..name_len]);
        self.name_len = name_len;
        self.setMode(entry.permissions orelse 0o644);
        self.error_len = 0;
        self.open = true;
    }

    fn pathText(self: *const State) []const u8 {
        return self.path[0..self.path_len];
    }

    fn nameText(self: *const State) []const u8 {
        return self.name[0..self.name_len];
    }

    fn setMode(self: *State, mode: u32) void {
        self.writeModeText(mode);
        self.bitsFromMode(mode);
    }

    fn writeModeText(self: *State, mode: u32) void {
        self.mode_text = std.mem.zeroes([8]u8);
        const text = std.fmt.bufPrint(self.mode_text[0..], "{o:0>3}", .{mode & 0o777}) catch return;
        if (text.len < self.mode_text.len) self.mode_text[text.len] = 0;
    }

    fn bitsFromMode(self: *State, mode: u32) void {
        const masked = mode & 0o777;
        for (0..9) |idx| {
            const bit: u32 = @as(u32, 1) << @intCast(8 - idx);
            self.bits[idx] = (masked & bit) != 0;
        }
    }

    fn modeFromBits(self: *const State) u32 {
        var mode: u32 = 0;
        for (0..9) |idx| {
            if (!self.bits[idx]) continue;
            mode |= @as(u32, 1) << @intCast(8 - idx);
        }
        return mode;
    }

    fn parseMode(self: *const State) ?u32 {
        const text = modeText(self.mode_text[0..]);
        if (text.len != 3 and text.len != 4) return null;
        var mode: u32 = 0;
        for (text) |ch| {
            if (ch < '0' or ch > '7') return null;
            mode = mode * 8 + @as(u32, ch - '0');
        }
        return mode & 0o777;
    }

    fn setError(self: *State, message: []const u8) void {
        const len = @min(self.error_text.len, message.len);
        if (len > 0) @memcpy(self.error_text[0..len], message[0..len]);
        self.error_len = len;
    }

    fn errorText(self: *const State) []const u8 {
        return self.error_text[0..self.error_len];
    }
};

pub fn show(state: *State, palette: theme.Palette, id_extra: usize) ?remote_file.FilePanelIntent {
    if (!state.open) return null;

    const window_rect = dvui.windowRect();
    const popup_w = @min(panel_width, @max(@as(f32, 320), window_rect.w - 32));
    const popup_h = @min(panel_height, @max(@as(f32, 220), window_rect.h - 32));
    const rect: dvui.Rect.Natural = .{
        .x = @max(12, @round((window_rect.w - popup_w) / 2)),
        .y = @max(12, @round((window_rect.h - popup_h) / 2)),
        .w = popup_w,
        .h = popup_h,
    };

    var panel: dvui.FloatingWidget = undefined;
    panel.init(@src(), .{}, theme.popup(.{
        .rect = .cast(rect),
        .min_size_content = .{ .w = rect.w, .h = rect.h },
        .max_size_content = .{ .w = rect.w, .h = rect.h },
        .padding = .all(0),
        .border = .all(1),
        .corner_radius = .all(6),
        .id_extra = id_extra,
    }, palette));
    defer panel.deinit();
    dvui.focusSubwindow(panel.data().id, null);

    header(state, palette, id_extra + 1);
    separator(palette, id_extra + 10);
    content(state, palette, @max(@as(f32, 116), rect.h - header_height - footer_height - 2), id_extra + 20);
    separator(palette, id_extra + 90);
    return footer(state, palette, id_extra + 100);
}

fn header(state: *const State, palette: theme.Palette, id_extra: usize) void {
    var box = dvui.box(@src(), .{ .dir = .horizontal }, theme.topbar(.{
        .expand = .horizontal,
        .min_size_content = .height(header_height),
        .max_size_content = .height(header_height),
        .padding = .{ .x = 12, .y = 0, .w = 12, .h = 0 },
        .corner_radius = .{ .x = 6, .y = 6, .w = 0, .h = 0 },
        .id_extra = id_extra,
    }, palette).override(.{ .color_fill = palette.surface_bg }));
    defer box.deinit();

    var title_buf: [320]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "Permissions: {s}", .{state.nameText()}) catch "Permissions";
    dvui.label(@src(), "{s}", .{title}, .{
        .font = theme.textFont(title, 14),
        .color_text = palette.text,
        .gravity_y = 0.5,
        .id_extra = id_extra + 1,
    });
}

fn content(state: *State, palette: theme.Palette, height: f32, id_extra: usize) void {
    var box = dvui.box(@src(), .{ .dir = .vertical }, theme.panel(.{
        .expand = .horizontal,
        .min_size_content = .height(height),
        .max_size_content = .height(height),
        .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
        .id_extra = id_extra,
    }, palette).override(.{
        .color_fill = palette.popup_bg,
        .color_border = palette.popup_bg,
    }));
    defer box.deinit();

    textRow("Path", state.pathText(), palette, id_extra + 1);
    modeRow(state, palette, id_extra + 10);
    permissionGrid(state, palette, id_extra + 30);

    if (state.error_len > 0) {
        dvui.label(@src(), "{s}", .{state.errorText()}, .{
            .font = theme.textFont(state.errorText(), 12),
            .color_text = palette.danger,
            .min_size_content = .height(18),
            .id_extra = id_extra + 70,
        });
    }
}

fn textRow(label: []const u8, value: []const u8, palette: theme.Palette, id_extra: usize) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .height(row_height),
        .max_size_content = .height(row_height),
        .padding = .all(0),
        .id_extra = id_extra,
    });
    defer row.deinit();

    fieldLabel(label, palette, id_extra + 1);
    dvui.label(@src(), "{s}", .{value}, .{
        .font = theme.textFont(value, 13),
        .color_text = palette.text,
        .expand = .horizontal,
        .gravity_y = 0.5,
        .id_extra = id_extra + 2,
    });
}

fn modeRow(state: *State, palette: theme.Palette, id_extra: usize) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .height(row_height),
        .max_size_content = .height(row_height),
        .padding = .all(0),
        .id_extra = id_extra,
    });
    defer row.deinit();

    fieldLabel("Mode", palette, id_extra + 1);
    var entry_theme = theme.textEntryTheme();
    var te: dvui.TextEntryWidget = undefined;
    te.init(@src(), .{ .text = .{ .buffer = &state.mode_text } }, theme.panel(.{
        .min_size_content = .{ .w = 72, .h = 22 },
        .max_size_content = .{ .w = 72, .h = 22 },
        .font = theme.textFont("000", 13),
        .padding = .{ .x = 4, .y = 0, .w = 4, .h = 0 },
        .corner_radius = .all(4),
        .id_extra = id_extra + 2,
    }, palette).override(.{
        .color_fill = palette.surface_bg,
        .color_border = palette.border,
        .theme = &entry_theme,
    }));
    te.processEvents();
    te.draw();
    theme.drawTextEntryFocus(te.data(), palette);
    te.deinit();

    if (state.parseMode()) |mode| state.bitsFromMode(mode);
}

fn permissionGrid(state: *State, palette: theme.Palette, id_extra: usize) void {
    const labels = [_][]const u8{ "Owner", "Group", "Other" };
    const bit_labels = [_][]const u8{ "Read", "Write", "Exec" };

    var grid = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 6, .w = 0, .h = 0 },
        .id_extra = id_extra,
    });
    defer grid.deinit();

    for (labels, 0..) |label, row_idx| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .min_size_content = .height(24),
            .max_size_content = .height(24),
            .padding = .all(0),
            .id_extra = id_extra + 1 + row_idx * 10,
        });
        defer row.deinit();

        fieldLabel(label, palette, id_extra + 2 + row_idx * 10);
        for (0..3) |col_idx| {
            const bit_idx = row_idx * 3 + col_idx;
            if (theme.checkbox(@src(), &state.bits[bit_idx], bit_labels[col_idx], palette, .{
                .id_extra = id_extra + 3 + row_idx * 10 + col_idx,
                .font_size = 12,
                .layout = .{
                    .min_size_content = .{ .w = 78, .h = 22 },
                    .max_size_content = .{ .w = 78, .h = 22 },
                    .padding = .all(0),
                },
            })) {
                state.writeModeText(state.modeFromBits());
                state.error_len = 0;
            }
        }
    }
}

fn footer(state: *State, palette: theme.Palette, id_extra: usize) ?remote_file.FilePanelIntent {
    var box = dvui.box(@src(), .{ .dir = .horizontal }, theme.panel(.{
        .expand = .horizontal,
        .min_size_content = .height(footer_height),
        .max_size_content = .height(footer_height),
        .padding = .all(0),
        .id_extra = id_extra,
    }, palette).override(.{
        .color_fill = palette.popup_bg,
        .color_border = palette.popup_bg,
    }));
    defer box.deinit();

    dvui.label(@src(), "", .{}, .{ .expand = .horizontal, .id_extra = id_extra + 1 });

    if (theme.button(@src(), "Cancel", .{
        .min_size_content = .{ .w = 72, .h = 24 },
        .max_size_content = .{ .w = 72, .h = 24 },
        .margin = .{ .y = 2, .w = 4, .h = 2 },
        .padding = .all(0),
        .id_extra = id_extra + 2,
    }, palette, .{ .variant = .ghost, .font_size = 13 })) {
        state.open = false;
        return null;
    }

    if (theme.button(@src(), "Apply", .{
        .min_size_content = .{ .w = 72, .h = 24 },
        .max_size_content = .{ .w = 72, .h = 24 },
        .margin = .{ .y = 2, .w = 10, .h = 2 },
        .padding = .all(0),
        .id_extra = id_extra + 3,
    }, palette, .{ .variant = .solid, .font_size = 13 })) {
        const mode = state.parseMode() orelse {
            state.setError("Mode must be octal, e.g. 755");
            return null;
        };
        state.open = false;
        return .{ .chmod = .{
            .pane = .remote,
            .path = state.pathText(),
            .permissions = mode,
        } };
    }
    return null;
}

fn fieldLabel(label: []const u8, palette: theme.Palette, id_extra: usize) void {
    dvui.label(@src(), "{s}", .{label}, .{
        .font = theme.textFont(label, 13),
        .color_text = palette.text_subtle,
        .min_size_content = .{ .w = label_width, .h = row_height },
        .max_size_content = .{ .w = label_width, .h = row_height },
        .gravity_y = 0.5,
        .padding = .all(0),
        .id_extra = id_extra,
    });
}

fn separator(palette: theme.Palette, id_extra: usize) void {
    var line = dvui.box(@src(), .{}, theme.panel(.{
        .expand = .horizontal,
        .min_size_content = .height(1),
        .max_size_content = .height(1),
        .padding = .all(0),
        .margin = .all(0),
        .id_extra = id_extra,
    }, palette).override(.{
        .color_fill = palette.border_subtle,
        .color_border = palette.border_subtle,
    }));
    defer line.deinit();
}

fn modeText(buffer: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len;
    return std.mem.trim(u8, buffer[0..end], " \t\r\n");
}
