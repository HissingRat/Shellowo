const std = @import("std");
const dvui = @import("dvui");

const remote_file = @import("../../../core/remote_file.zig");
const file_format = @import("file_format.zig");
const theme = @import("../../theme.zig");

const panel_width: f32 = 460;
const panel_height: f32 = 364;
const header_height: f32 = 30;
const footer_height: f32 = 48;
const footer_button_height: f32 = 24;
const label_width: f32 = 108;
const name_max_len: usize = 256;
const path_max_len: usize = 768;

pub const Action = union(enum) {
    edit_permissions: remote_file.RemoteFileEntry,
};

pub const State = struct {
    open: bool = false,
    name: [name_max_len]u8 = undefined,
    name_len: usize = 0,
    path: [path_max_len]u8 = undefined,
    path_len: usize = 0,
    kind: remote_file.RemoteFileKind = .other,
    size: ?u64 = null,
    permissions: ?u32 = null,
    modified_unix: ?i64 = null,
    uid: ?u64 = null,
    gid: ?u64 = null,

    pub fn show(self: *State, snapshot: remote_file.FilePaneSnapshot, item: remote_file.RemoteFileEntry) void {
        const name_len = @min(self.name.len, item.name.len);
        if (name_len > 0) @memcpy(self.name[0..name_len], item.name[0..name_len]);
        self.name_len = name_len;
        self.path_len = formatPath(self.path[0..], snapshot.path, item);
        self.kind = item.kind;
        self.size = item.size;
        self.permissions = item.permissions;
        self.modified_unix = item.modified_unix;
        self.uid = item.uid;
        self.gid = item.gid;
        self.open = true;
    }

    pub fn syncFromSnapshot(self: *State, snapshot: remote_file.FilePaneSnapshot) void {
        if (!self.open) return;
        var path_buf: [path_max_len]u8 = undefined;
        for (snapshot.entries) |item| {
            const path_len = formatPath(path_buf[0..], snapshot.path, item);
            if (!std.mem.eql(u8, self.pathText(), path_buf[0..path_len])) continue;
            self.kind = item.kind;
            self.size = item.size;
            self.permissions = item.permissions;
            self.modified_unix = item.modified_unix;
            self.uid = item.uid;
            self.gid = item.gid;
            return;
        }
    }

    pub fn applyPermissions(self: *State, path: []const u8, permissions: u32) void {
        if (!self.open or !std.mem.eql(u8, self.pathText(), path)) return;
        self.permissions = permissions;
    }

    fn entry(self: *const State) remote_file.RemoteFileEntry {
        return .{
            .name = self.nameText(),
            .kind = self.kind,
            .size = self.size,
            .permissions = self.permissions,
            .modified_unix = self.modified_unix,
            .uid = self.uid,
            .gid = self.gid,
            .full_path = self.pathText(),
        };
    }

    fn nameText(self: *const State) []const u8 {
        return self.name[0..self.name_len];
    }

    fn pathText(self: *const State) []const u8 {
        return self.path[0..self.path_len];
    }
};

pub fn show(state: *State, palette: theme.Palette, id_extra: usize) ?Action {
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
    panel.init(@src(), .{}, theme.panel(.{
        .rect = .cast(rect),
        .min_size_content = .{ .w = rect.w, .h = rect.h },
        .max_size_content = .{ .w = rect.w, .h = rect.h },
        .padding = .all(0),
        .border = .all(1),
        .corner_radius = .all(6),
        .id_extra = id_extra,
    }, palette).override(.{
        .color_fill = palette.panel_bg,
        .color_border = palette.border_subtle,
    }));
    defer panel.deinit();
    dvui.focusSubwindow(panel.data().id, null);

    header(state, palette, id_extra + 1);
    separator(palette, id_extra + 20);
    const content_height = @max(@as(f32, 120), rect.h - header_height - footer_height - 2);
    content(state, palette, content_height, id_extra + 30);
    separator(palette, id_extra + 80);
    return footer(state, palette, id_extra + 90);
}

fn header(state: *State, palette: theme.Palette, id_extra: usize) void {
    var box = dvui.box(@src(), .{ .dir = .horizontal }, theme.topbar(.{
        .expand = .horizontal,
        .min_size_content = .height(header_height),
        .max_size_content = .height(header_height),
        .padding = .{ .x = 12, .y = 0, .w = 8, .h = 0 },
        .corner_radius = .{ .x = 6, .y = 6, .w = 0, .h = 0 },
        .id_extra = id_extra,
    }, palette).override(.{
        .color_fill = palette.surface_bg,
    }));
    defer box.deinit();

    var title_buf: [320]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "{s}", .{state.nameText()}) catch "Details";
    dvui.label(@src(), "{s}", .{title}, .{
        .font = theme.textFont(title, 11),
        .color_text = palette.text,
        .expand = .horizontal,
        .gravity_y = 0.5,
        .id_extra = id_extra + 1,
    });
}

fn content(state: *const State, palette: theme.Palette, height: f32, id_extra: usize) void {
    var scroll = dvui.scrollArea(@src(), .{
        .vertical = .auto,
        .vertical_bar = .auto_overlay,
        .horizontal = .none,
    }, theme.panel(.{
        .expand = .horizontal,
        .min_size_content = .height(height),
        .max_size_content = .height(height),
        .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
        .margin = .all(0),
        .id_extra = id_extra,
    }, palette).override(.{
        .color_fill = palette.panel_bg,
        .color_border = palette.panel_bg,
    }));
    defer scroll.deinit();

    const item = state.entry();
    var size_buf: [96]u8 = undefined;
    var modified_buf: [32]u8 = undefined;
    var perm_buf: [48]u8 = undefined;
    var owner_buf: [40]u8 = undefined;
    var raw_mode_buf: [24]u8 = undefined;

    row("Name", item.name, palette, id_extra + 1);
    row("Path", item.full_path, palette, id_extra + 2);
    row("Type", item.kind.label(), palette, id_extra + 3);
    row("Size", detailSizeText(item, &size_buf), palette, id_extra + 4);
    row("Modified", file_format.modifiedText(item, &modified_buf), palette, id_extra + 5);
    row("Permissions", detailPermissionText(item, &perm_buf), palette, id_extra + 6);
    row("Mode", detailModeText(item, &raw_mode_buf), palette, id_extra + 7);
    row("User/Group", file_format.ownerText(item, &owner_buf), palette, id_extra + 8);
}

fn footer(state: *State, palette: theme.Palette, id_extra: usize) ?Action {
    var box = dvui.box(@src(), .{ .dir = .horizontal }, theme.panel(.{
        .expand = .horizontal,
        .min_size_content = .height(footer_height),
        .max_size_content = .height(footer_height),
        .padding = .all(0),
        .id_extra = id_extra,
    }, palette).override(.{
        .color_fill = palette.panel_bg,
        .color_border = palette.panel_bg,
    }));
    defer box.deinit();

    dvui.label(@src(), "", .{}, .{
        .expand = .horizontal,
        .id_extra = id_extra + 1,
    });

    if (theme.button(@src(), "Permissions", .{
        .min_size_content = .{ .w = 100, .h = footer_button_height },
        .max_size_content = .{ .w = 100, .h = footer_button_height },
        .padding = .all(0),
        .margin = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
        .id_extra = id_extra + 2,
        .gravity_y = 0,
    }, palette, .{ .variant = .ghost, .font_size = 10 })) {
        return .{ .edit_permissions = state.entry() };
    }

    if (theme.button(@src(), "Close", .{
        .min_size_content = .{ .w = 78, .h = footer_button_height },
        .max_size_content = .{ .w = 78, .h = footer_button_height },
        .padding = .all(0),
        .margin = .{ .y = 2, .w = 4, .h = 2 },
        .id_extra = id_extra + 3,
        .gravity_y = 0.5,
    }, palette, .{ .variant = .solid, .font_size = 10 })) {
        state.open = false;
    }
    return null;
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

fn row(label: []const u8, value: []const u8, palette: theme.Palette, id_extra: usize) void {
    var box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .height(24),
        .max_size_content = .height(24),
        .padding = .all(0),
        .id_extra = id_extra,
    });
    defer box.deinit();

    dvui.label(@src(), "{s}", .{label}, .{
        .font = theme.textFont(label, 10),
        .color_text = palette.text_subtle,
        .min_size_content = .{ .w = label_width, .h = 24 },
        .max_size_content = .{ .w = label_width, .h = 24 },
        .gravity_y = 0.5,
        .id_extra = id_extra + 20,
        .padding = .all(0),
        .margin = .all(0),
    });
    dvui.label(@src(), "{s}", .{value}, .{
        .font = theme.textFont(value, 10),
        .color_text = palette.text,
        .expand = .horizontal,
        .min_size_content = .height(24),
        .max_size_content = .height(24),
        .gravity_y = 0.5,
        .id_extra = id_extra + 21,
        .padding = .all(0),
        .margin = .all(0),
    });
}

fn renderThemedPng(bytes: []const u8, name: []const u8, rs: dvui.RectScale, color: dvui.Color) void {
    const source: dvui.ImageSource = .{ .imageFile = .{
        .bytes = bytes,
        .name = name,
        .interpolation = .linear,
    } };
    dvui.renderImage(source, rs, .{ .colormod = color }) catch {};
}

fn formatPath(buffer: []u8, parent_path: []const u8, entry: remote_file.RemoteFileEntry) usize {
    if (entry.full_path.len > 0) {
        const len = @min(buffer.len, entry.full_path.len);
        if (len > 0) @memcpy(buffer[0..len], entry.full_path[0..len]);
        return len;
    }
    const value = if (std.mem.eql(u8, parent_path, "/"))
        std.fmt.bufPrint(buffer, "/{s}", .{entry.name}) catch ""
    else
        std.fmt.bufPrint(buffer, "{s}/{s}", .{ trimRightSlash(parent_path), entry.name }) catch "";
    return value.len;
}

fn detailSizeText(entry: remote_file.RemoteFileEntry, buf: []u8) []const u8 {
    if (entry.kind == .directory) return "-";
    const size = entry.size orelse return "-";
    var human_buf: [32]u8 = undefined;
    const human = file_format.sizeText(entry, &human_buf);
    return std.fmt.bufPrint(buf, "{s} ({d} bytes)", .{ human, size }) catch human;
}

fn detailPermissionText(entry: remote_file.RemoteFileEntry, buf: []u8) []const u8 {
    const permissions = entry.permissions orelse return "-";
    var symbolic_buf: [12]u8 = undefined;
    const symbolic = file_format.permissionText(entry, &symbolic_buf);
    return std.fmt.bufPrint(buf, "{s} ({o:0>3})", .{ symbolic, permissions & 0o777 }) catch symbolic;
}

fn detailModeText(entry: remote_file.RemoteFileEntry, buf: []u8) []const u8 {
    const permissions = entry.permissions orelse return "-";
    return std.fmt.bufPrint(buf, "0{o:0>6}", .{permissions}) catch "-";
}

fn trimRightSlash(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    return path[0..end];
}
