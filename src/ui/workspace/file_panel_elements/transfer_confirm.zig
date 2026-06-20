const std = @import("std");
const dvui = @import("dvui");

const remote_file = @import("../../../core/remote_file.zig");
const theme = @import("../../theme.zig");

const max_entries: usize = 48;
const max_name_len: usize = 256;
const max_path_len: usize = 1024;
const max_message_len: usize = 160;
const panel_width: f32 = 420;
const panel_height: f32 = 125;

pub const Action = enum {
    none,
    cancel,
    overwrite,
};

const PendingKind = enum {
    upload,
    upload_many,
    download,
    download_many,
};

pub const State = struct {
    open: bool = false,
    kind: PendingKind = .upload,
    local_path: [max_path_len]u8 = undefined,
    local_path_len: usize = 0,
    remote_path: [max_path_len]u8 = undefined,
    remote_path_len: usize = 0,
    name: [max_name_len]u8 = undefined,
    name_len: usize = 0,
    entries: [max_entries]remote_file.FileBatchEntry = undefined,
    entry_names: [max_entries][max_name_len]u8 = undefined,
    entry_name_lens: [max_entries]usize = [_]usize{0} ** max_entries,
    entry_count: usize = 0,
    message: [max_message_len]u8 = undefined,
    message_len: usize = 0,

    pub fn clear(self: *State) void {
        self.open = false;
        self.local_path_len = 0;
        self.remote_path_len = 0;
        self.name_len = 0;
        self.entry_count = 0;
        self.message_len = 0;
    }

    pub fn set(self: *State, panel_intent: remote_file.FilePanelIntent, message_text: []const u8) void {
        self.clear();
        self.message_len = copyBounded(&self.message, message_text);
        switch (panel_intent) {
            .upload => |item| {
                self.kind = .upload;
                self.copyTransfer(item);
            },
            .download => |item| {
                self.kind = .download;
                self.copyTransfer(item);
            },
            .upload_many => |item| {
                self.kind = .upload_many;
                self.copyBatch(item);
            },
            .download_many => |item| {
                self.kind = .download_many;
                self.copyBatch(item);
            },
            else => return,
        }
        self.open = true;
    }

    pub fn intent(self: *State) remote_file.FilePanelIntent {
        return switch (self.kind) {
            .upload => .{ .upload = self.transferIntent() },
            .download => .{ .download = self.transferIntent() },
            .upload_many => .{ .upload_many = self.batchIntent() },
            .download_many => .{ .download_many = self.batchIntent() },
        };
    }

    fn copyTransfer(self: *State, item: remote_file.FileTransferIntent) void {
        self.local_path_len = copyBounded(&self.local_path, item.local_path);
        self.remote_path_len = copyBounded(&self.remote_path, item.remote_path);
        self.name_len = copyBounded(&self.name, item.name);
    }

    fn copyBatch(self: *State, item: remote_file.FileBatchTransferIntent) void {
        self.local_path_len = copyBounded(&self.local_path, item.local_path);
        self.remote_path_len = copyBounded(&self.remote_path, item.remote_path);
        self.entry_count = @min(item.entries.len, max_entries);
        for (item.entries[0..self.entry_count], 0..) |entry, idx| {
            self.entry_name_lens[idx] = copyBounded(&self.entry_names[idx], entry.name);
            self.entries[idx] = .{
                .name = self.entryName(idx),
                .kind = entry.kind,
            };
        }
    }

    fn transferIntent(self: *const State) remote_file.FileTransferIntent {
        return .{
            .local_path = self.localPath(),
            .remote_path = self.remotePath(),
            .name = self.nameText(),
        };
    }

    fn batchIntent(self: *State) remote_file.FileBatchTransferIntent {
        for (0..self.entry_count) |idx| {
            self.entries[idx].name = self.entryName(idx);
        }
        return .{
            .local_path = self.localPath(),
            .remote_path = self.remotePath(),
            .entries = self.entries[0..self.entry_count],
        };
    }

    fn localPath(self: *const State) []const u8 {
        return self.local_path[0..self.local_path_len];
    }

    fn remotePath(self: *const State) []const u8 {
        return self.remote_path[0..self.remote_path_len];
    }

    fn nameText(self: *const State) []const u8 {
        return self.name[0..self.name_len];
    }

    fn entryName(self: *const State, idx: usize) []const u8 {
        return self.entry_names[idx][0..self.entry_name_lens[idx]];
    }

    fn messageText(self: *const State) []const u8 {
        return self.message[0..self.message_len];
    }
};

pub fn show(state: *State, palette: theme.Palette, id_extra: usize) Action {
    if (!state.open) return .none;

    const window_rect = dvui.windowRect();
    const popup_w = @min(panel_width, @max(@as(f32, 300), window_rect.w - 32));
    const popup_h = panel_height;
    const rect: dvui.Rect.Natural = .{
        .x = @max(12, @round((window_rect.w - popup_w) / 2)),
        .y = @max(40, @round((window_rect.h - popup_h) / 2)),
        .w = popup_w,
        .h = popup_h,
    };

    var panel: dvui.FloatingWidget = undefined;
    panel.init(@src(), .{}, theme.popup(.{
        .rect = .cast(rect),
        .min_size_content = .{ .w = rect.w, .h = rect.h },
        .max_size_content = .{ .w = rect.w, .h = rect.h },
        .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
        .border = .all(1),
        .corner_radius = .all(8),
        .id_extra = id_extra,
    }, palette));
    defer panel.deinit();
    dvui.focusSubwindow(panel.data().id, null);

    dvui.label(@src(), "Overwrite Existing Item?", .{}, .{
        .font = theme.textFont("Overwrite Existing Item?", 12),
        .color_text = palette.text,
        .margin = .all(0),
        .id_extra = id_extra + 1,
    });
    dvui.label(@src(), "{s}", .{state.messageText()}, .{
        .font = theme.textFont(state.messageText(), 9),
        .color_text = palette.text_subtle,
        .expand = .horizontal,
        .min_size_content = .height(20),
        .id_extra = id_extra + 2,
    });

    var spacer = dvui.box(@src(), .{}, .{ .expand = .vertical, .id_extra = id_extra + 3 });
    defer spacer.deinit();

    var actions = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .gravity_x = 1,
        .id_extra = id_extra + 4,
    });
    defer actions.deinit();

    if (theme.button(@src(), "Cancel", .{
        .min_size_content = .{ .w = 72, .h = 19 },
        .margin = .{ .x = 4, .y = 4 },
        .id_extra = id_extra + 5,
    }, palette, .{ .variant = .ghost, .font_size = 10 })) return .cancel;

    if (theme.button(@src(), "Overwrite", .{
        .min_size_content = .{ .w = 88, .h = 19 },
        .margin = .{ .x = 4, .y = 4 },
        .id_extra = id_extra + 6,
    }, palette, .{ .variant = .solid, .font_size = 10 })) return .overwrite;

    return .none;
}

fn copyBounded(dest: []u8, src: []const u8) usize {
    const len = @min(dest.len, src.len);
    if (len > 0) @memcpy(dest[0..len], src[0..len]);
    return len;
}
