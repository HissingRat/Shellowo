const std = @import("std");
const dvui = @import("dvui");

const app_config = @import("../../../app/config.zig");
const remote_file = @import("../../../core/remote_file.zig");
const details_panel = @import("../../workspace/file_panel_elements/details_panel.zig");
const permissions_panel = @import("../../workspace/file_panel_elements/permissions_panel.zig");
const remote_editor = @import("../../workspace/file_panel_elements/remote_editor.zig");
const transfer_confirm = @import("../../workspace/file_panel_elements/transfer_confirm.zig");

pub const max_selected_entries: usize = 48;
pub const max_selected_name_len: usize = 256;
pub const edit_name_max_len: usize = 256;
pub const path_entry_max_len: usize = 512;

pub const ColumnWidths = app_config.FileColumnWidths;

pub const PaneKind = enum {
    tree,
    remote,
};

pub const EditMode = enum {
    none,
    new_file,
    new_folder,
    rename,
};

pub const PathBar = struct {
    editing: bool = false,
    focus_requested: bool = false,
    buffer: [path_entry_max_len]u8 = std.mem.zeroes([path_entry_max_len]u8),
    observed_path: [path_entry_max_len]u8 = undefined,
    observed_path_len: usize = 0,

    pub fn observePath(self: *PathBar, path: []const u8) void {
        if (self.editing or std.mem.eql(u8, self.observedPath(), path)) return;
        self.setBuffer(path);
        const len = @min(self.observed_path.len, path.len);
        if (len > 0) @memcpy(self.observed_path[0..len], path[0..len]);
        self.observed_path_len = len;
    }

    pub fn beginEdit(self: *PathBar, path: []const u8) void {
        self.setBuffer(path);
        self.editing = true;
        self.focus_requested = true;
    }

    pub fn cancelEdit(self: *PathBar) void {
        self.editing = false;
        self.focus_requested = false;
    }

    pub fn text(self: *const PathBar) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.buffer, 0) orelse self.buffer.len;
        return self.buffer[0..end];
    }

    fn observedPath(self: *const PathBar) []const u8 {
        return self.observed_path[0..self.observed_path_len];
    }

    fn setBuffer(self: *PathBar, path: []const u8) void {
        self.buffer = std.mem.zeroes([path_entry_max_len]u8);
        const len = @min(path_entry_max_len - 1, path.len);
        if (len > 0) @memcpy(self.buffer[0..len], path[0..len]);
    }
};

pub const PaneLayout = struct {
    columns: ColumnWidths = .{},
    columns_initialized: bool = false,
    last_click_pane: PaneKind = .remote,
    last_click_name: [256]u8 = undefined,
    last_click_name_len: usize = 0,
    last_click_ns: i128 = 0,
    selected_names: [max_selected_entries][max_selected_name_len]u8 = undefined,
    selected_name_lens: [max_selected_entries]usize = [_]usize{0} ** max_selected_entries,
    selected_count: usize = 0,
    action_entries: [max_selected_entries]remote_file.FileBatchEntry = undefined,
    edit_mode: EditMode = .none,
    edit_buffer: [edit_name_max_len]u8 = std.mem.zeroes([edit_name_max_len]u8),
    edit_target_name: [edit_name_max_len]u8 = undefined,
    edit_target_name_len: usize = 0,
    edit_focus_requested: bool = false,
    edit_select_requested: bool = false,
    edit_was_focused: bool = false,
    delete_pending: bool = false,
    delete_name: [edit_name_max_len]u8 = undefined,
    delete_name_len: usize = 0,
    delete_kind: remote_file.RemoteFileKind = .file,
    delete_anchor: dvui.Point.Natural = .{},
    details: details_panel.State = .{},
    permissions: permissions_panel.State = .{},
    editor: remote_editor.State = .{},
    transfer_confirm: transfer_confirm.State = .{},
    toast_message: [96]u8 = undefined,
    toast_message_len: usize = 0,
    toast_started_ns: i128 = 0,
    dismissed_toast: [96]u8 = undefined,
    dismissed_toast_len: usize = 0,

    pub fn isSelected(self: *const PaneLayout, name: []const u8) bool {
        for (0..self.selected_count) |idx| {
            if (std.mem.eql(u8, self.selectedName(idx), name)) return true;
        }
        return false;
    }

    pub fn applySelection(self: *PaneLayout, name: []const u8, additive: bool) void {
        if (additive) {
            if (self.removeSelection(name)) return;
            self.addSelection(name);
            return;
        }
        self.selected_count = 0;
        self.addSelection(name);
    }

    pub fn selectedName(self: *const PaneLayout, idx: usize) []const u8 {
        return self.selected_names[idx][0..self.selected_name_lens[idx]];
    }

    pub fn startCreate(self: *PaneLayout, mode: EditMode) void {
        self.edit_mode = mode;
        self.edit_buffer = std.mem.zeroes([edit_name_max_len]u8);
        self.edit_target_name_len = 0;
        self.edit_focus_requested = true;
        self.edit_select_requested = false;
        self.edit_was_focused = false;
    }

    pub fn startRename(self: *PaneLayout, name: []const u8) void {
        self.edit_mode = .rename;
        self.edit_buffer = std.mem.zeroes([edit_name_max_len]u8);
        const len = @min(name.len, edit_name_max_len - 1);
        if (len > 0) {
            @memcpy(self.edit_buffer[0..len], name[0..len]);
            @memcpy(self.edit_target_name[0..len], name[0..len]);
        }
        self.edit_target_name_len = len;
        self.edit_focus_requested = true;
        self.edit_select_requested = true;
        self.edit_was_focused = false;
    }

    pub fn editingTargetName(self: *const PaneLayout) []const u8 {
        return self.edit_target_name[0..self.edit_target_name_len];
    }

    pub fn cancelEdit(self: *PaneLayout) void {
        self.edit_mode = .none;
        self.edit_focus_requested = false;
        self.edit_select_requested = false;
        self.edit_was_focused = false;
    }

    pub fn setDeletePending(self: *PaneLayout, name: []const u8, kind: remote_file.RemoteFileKind, anchor: dvui.Point.Natural) void {
        const len = @min(name.len, edit_name_max_len);
        if (len > 0) @memcpy(self.delete_name[0..len], name[0..len]);
        self.delete_name_len = len;
        self.delete_kind = kind;
        self.delete_anchor = anchor;
        self.delete_pending = true;
    }

    pub fn deleteName(self: *const PaneLayout) []const u8 {
        return self.delete_name[0..self.delete_name_len];
    }

    pub fn observeToast(self: *PaneLayout, message: ?[]const u8) void {
        const value = message orelse {
            self.clearToastGate();
            return;
        };
        if (value.len == 0) {
            self.clearToastGate();
            return;
        }
        if (std.mem.eql(u8, self.dismissedToast(), value) or std.mem.eql(u8, self.toastMessage(), value)) return;
        const len = @min(self.toast_message.len, value.len);
        if (len > 0) @memcpy(self.toast_message[0..len], value[0..len]);
        self.toast_message_len = len;
        self.toast_started_ns = dvui.frameTimeNS();
    }

    pub fn dismissToast(self: *PaneLayout) void {
        const message = self.toastMessage();
        const len = @min(self.dismissed_toast.len, message.len);
        if (len > 0) @memcpy(self.dismissed_toast[0..len], message[0..len]);
        self.dismissed_toast_len = len;
        self.toast_message_len = 0;
    }

    pub fn clearToastGate(self: *PaneLayout) void {
        self.dismissed_toast_len = 0;
    }

    pub fn toastMessage(self: *const PaneLayout) []const u8 {
        return self.toast_message[0..self.toast_message_len];
    }

    fn dismissedToast(self: *const PaneLayout) []const u8 {
        return self.dismissed_toast[0..self.dismissed_toast_len];
    }

    fn addSelection(self: *PaneLayout, name: []const u8) void {
        if (self.isSelected(name) or self.selected_count >= max_selected_entries) return;
        const idx = self.selected_count;
        const len = @min(name.len, max_selected_name_len);
        if (len > 0) @memcpy(self.selected_names[idx][0..len], name[0..len]);
        self.selected_name_lens[idx] = len;
        self.selected_count += 1;
    }

    fn removeSelection(self: *PaneLayout, name: []const u8) bool {
        for (0..self.selected_count) |idx| {
            if (!std.mem.eql(u8, self.selectedName(idx), name)) continue;
            var move_idx = idx;
            while (move_idx + 1 < self.selected_count) : (move_idx += 1) {
                self.selected_names[move_idx] = self.selected_names[move_idx + 1];
                self.selected_name_lens[move_idx] = self.selected_name_lens[move_idx + 1];
            }
            self.selected_count -= 1;
            return true;
        }
        return false;
    }
};
