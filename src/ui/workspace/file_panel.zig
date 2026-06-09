const std = @import("std");
const dvui = @import("dvui");

const App = @import("../../app/App.zig");
const remote_file = @import("../../core/remote_file.zig");
const transfer = @import("../../core/transfer.zig");
const workspace = @import("../../core/workspace.zig");
const resize = @import("resize.zig");
const theme = @import("../theme.zig");

const folder_icon_bytes = @embedFile("shellowo-folder-icon");
const file_icon_bytes = @embedFile("shellowo-file-icon");
const close_icon_bytes = @embedFile("shellowo-close-icon");

pub const Options = struct {
    app: *App,
    snapshot: remote_file.FilePanelSnapshot,
    height: ?f32,
    local_width: *f32,
    id_extra: usize,
};

const min_local_width: f32 = 160;
const max_local_width: f32 = 380;
const toolbar_height: f32 = 31;
const row_height: f32 = 24;
const header_height: f32 = 24;
const context_menu_font_size: f32 = 9;
const double_click_window_ns: i128 = 500 * 1_000_000;
const tooltip_delay_us: i32 = 1_500_000;
const file_icon_size: f32 = 15;
const file_icon_gap: f32 = 7;
const tree_indent: f32 = 18;
const tree_disclosure_width: f32 = 14;
const min_name_width: f32 = 90;
const max_name_width: f32 = 420;
const min_size_width: f32 = 44;
const max_size_width: f32 = 120;
const min_modified_width: f32 = 104;
const max_modified_width: f32 = 180;
const min_perm_width: f32 = 54;
const max_perm_width: f32 = 140;
const min_owner_width: f32 = 72;
const max_owner_width: f32 = 180;
const max_selected_entries: usize = 48;
const max_selected_name_len: usize = 256;
const edit_name_max_len: usize = 256;
const toast_visible_ns: i128 = 2 * std.time.ns_per_s;
const transfer_popup_max_height: f32 = 200;
const transfer_popup_min_width: f32 = 280;
const transfer_popup_max_width: f32 = 760;
const transfer_popup_pad_x: f32 = 2;
const transfer_popup_pad_y: f32 = 1;
const transfer_task_row_height: f32 = 64;
const transfer_close_button_size: f32 = 14;

const ColumnWidths = struct {
    name: f32 = 220,
    size: f32 = 76,
    modified: f32 = 130,
    perm: f32 = 86,
    owner: f32 = 100,
};

const PaneLayoutState = struct {
    columns: ColumnWidths = .{},
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

    toast_message: [96]u8 = undefined,
    toast_message_len: usize = 0,
    toast_started_ns: i128 = 0,
    dismissed_toast: [96]u8 = undefined,
    dismissed_toast_len: usize = 0,

    fn isSelected(self: *const PaneLayoutState, name: []const u8) bool {
        for (0..self.selected_count) |idx| {
            if (std.mem.eql(u8, self.selectedName(idx), name)) return true;
        }
        return false;
    }

    fn applySelection(self: *PaneLayoutState, name: []const u8, additive: bool) void {
        if (additive) {
            if (self.removeSelection(name)) return;
            self.addSelection(name);
            return;
        }
        self.selected_count = 0;
        self.addSelection(name);
    }

    fn selectedName(self: *const PaneLayoutState, idx: usize) []const u8 {
        return self.selected_names[idx][0..self.selected_name_lens[idx]];
    }

    fn addSelection(self: *PaneLayoutState, name: []const u8) void {
        if (self.isSelected(name) or self.selected_count >= max_selected_entries) return;
        const idx = self.selected_count;
        const len = @min(name.len, max_selected_name_len);
        if (len > 0) @memcpy(self.selected_names[idx][0..len], name[0..len]);
        self.selected_name_lens[idx] = len;
        self.selected_count += 1;
    }

    fn removeSelection(self: *PaneLayoutState, name: []const u8) bool {
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

    fn startCreate(self: *PaneLayoutState, mode: EditMode) void {
        self.edit_mode = mode;
        self.edit_buffer = std.mem.zeroes([edit_name_max_len]u8);
        self.edit_target_name_len = 0;
        self.edit_focus_requested = true;
        self.edit_select_requested = false;
        self.edit_was_focused = false;
    }

    fn startRename(self: *PaneLayoutState, name: []const u8) void {
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

    fn editingTargetName(self: *const PaneLayoutState) []const u8 {
        return self.edit_target_name[0..self.edit_target_name_len];
    }

    fn cancelEdit(self: *PaneLayoutState) void {
        self.edit_mode = .none;
        self.edit_focus_requested = false;
        self.edit_select_requested = false;
        self.edit_was_focused = false;
    }

    fn setDeletePending(self: *PaneLayoutState, name: []const u8, kind: remote_file.RemoteFileKind, anchor: dvui.Point.Natural) void {
        const len = @min(name.len, edit_name_max_len);
        if (len > 0) @memcpy(self.delete_name[0..len], name[0..len]);
        self.delete_name_len = len;
        self.delete_kind = kind;
        self.delete_anchor = anchor;
        self.delete_pending = true;
    }

    fn deleteName(self: *const PaneLayoutState) []const u8 {
        return self.delete_name[0..self.delete_name_len];
    }

    fn observeToast(self: *PaneLayoutState, message: ?[]const u8) void {
        const value = message orelse return;
        if (value.len == 0) return;
        if (std.mem.eql(u8, self.dismissedToast(), value)) return;
        if (std.mem.eql(u8, self.toastMessage(), value)) return;
        const len = @min(self.toast_message.len, value.len);
        if (len > 0) @memcpy(self.toast_message[0..len], value[0..len]);
        self.toast_message_len = len;
        self.toast_started_ns = dvui.frameTimeNS();
    }

    fn dismissToast(self: *PaneLayoutState) void {
        const message = self.toastMessage();
        const len = @min(self.dismissed_toast.len, message.len);
        if (len > 0) @memcpy(self.dismissed_toast[0..len], message[0..len]);
        self.dismissed_toast_len = len;
        self.toast_message_len = 0;
    }

    fn toastMessage(self: *const PaneLayoutState) []const u8 {
        return self.toast_message[0..self.toast_message_len];
    }

    fn dismissedToast(self: *const PaneLayoutState) []const u8 {
        return self.dismissed_toast[0..self.dismissed_toast_len];
    }
};

const PathBarState = struct {
    transfer_popup_open: bool = false,
    transfer_popup_anchor: dvui.Rect.Natural = .{},
    transfer_popup_rect: dvui.Rect = .{},
};

const EditMode = enum {
    none,
    new_file,
    new_folder,
    rename,
};

pub fn show(tab: workspace.WorkspaceTab, palette: theme.Palette, opts: Options) ?remote_file.FilePanelIntent {
    _ = tab;
    var intent: ?remote_file.FilePanelIntent = null;
    var root = dvui.box(@src(), .{ .dir = .vertical }, theme.panel(panelOptions(opts), palette).override(.{
        .color_fill = palette.panel_bg,
        .color_border = palette.border_subtle,
    }));
    defer root.deinit();

    pathBar(opts.app, opts.snapshot.remote, palette, opts.id_extra + 10);

    var split = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .padding = .all(0),
        .id_extra = opts.id_extra + 20,
    });
    defer split.deinit();

    filePane(.local, palette, .{
        .snapshot = opts.snapshot.local,
        .width = opts.local_width.*,
        .id_extra = opts.id_extra + 30,
    }, &intent);
    resize.handle(palette, .{
        .axis = .vertical,
        .value = opts.local_width,
        .min = min_local_width,
        .max = max_local_width,
        .id_extra = opts.id_extra + 40,
    });
    filePane(.remote, palette, .{
        .snapshot = opts.snapshot.remote,
        .width = null,
        .id_extra = opts.id_extra + 50,
    }, &intent);
    return intent;
}

fn panelOptions(opts: Options) dvui.Options {
    var options = dvui.Options{
        .expand = .horizontal,
        .padding = .all(0),
        .id_extra = opts.id_extra,
    };
    if (opts.height) |height| {
        options.min_size_content = .height(height);
        options.max_size_content = .height(height);
    } else {
        options.expand = .both;
    }
    return options;
}

fn pathBar(app: *App, remote: remote_file.FilePaneSnapshot, palette: theme.Palette, id_extra: usize) void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, theme.panel(.{
        .expand = .horizontal,
        .min_size_content = .height(toolbar_height),
        .max_size_content = .height(toolbar_height),
        .padding = .{ .x = 12, .y = 0, .w = 12, .h = 0 },
        .id_extra = id_extra,
    }, palette).override(.{ .color_fill = palette.topbar_bg }));
    defer bar.deinit();

    dvui.label(@src(), "{s}", .{remote.path}, .{
        .font = theme.textFont(remote.path, 10),
        .color_text = palette.muted_text,
        .expand = .horizontal,
        .gravity_y = 0.5,
        .id_extra = id_extra + 1,
    });

    const state = dvui.dataGetPtrDefault(null, bar.data().id, "path-bar-state", PathBarState, .{});
    transferTaskButton(app, state, palette, id_extra + 20);
}

fn transferTaskButton(app: *App, state: *PathBarState, palette: theme.Palette, id_extra: usize) void {
    var count_buf: [32]u8 = undefined;
    const active_count = activeTransferCount(app.transfers.items);
    const count_label = std.fmt.bufPrint(&count_buf, "{d} active tasks", .{active_count}) catch "active tasks";

    var button_box = dvui.box(@src(), .{}, .{
        .min_size_content = .{ .w = 148, .h = toolbar_height },
        .max_size_content = .{ .w = 148, .h = toolbar_height },
        .padding = .all(0),
        .id_extra = id_extra,
    });
    const button_rect = button_box.data().rectScale().r;
    const clicked = theme.button(@src(), count_label, .{
        .expand = .both,
        .gravity_y = 0.5,
        .padding = .all(0),
        .margin = .all(0),
        .corner_radius = .all(0),
        .id_extra = id_extra + 1,
    }, palette, .{ .variant = .ghost, .font_size = 10, .text_align_x = 0.5 });
    button_box.deinit();

    if (clicked) {
        state.transfer_popup_open = !state.transfer_popup_open;
        state.transfer_popup_anchor = button_rect.toNatural();
    }

    if (state.transfer_popup_open) {
        state.transfer_popup_rect = transferPopupRect(state.transfer_popup_anchor, app.transfers.items);
        transferPopup(app, palette, state, id_extra + 100);
    }
}

fn activeTransferCount(tasks: []const transfer.TransferTask) usize {
    var count: usize = 0;
    for (tasks) |task| {
        if (task.status == .pending or task.status == .running) count += 1;
    }
    return count;
}

fn transferPopup(app: *App, palette: theme.Palette, state: *PathBarState, id_extra: usize) void {
    const tasks = app.transfers.items;
    const popup_width = transferPopupWidth(tasks);
    var win = dvui.floatingWindow(@src(), .{
        .rect = &state.transfer_popup_rect,
        .open_flag = &state.transfer_popup_open,
        .resize = .none,
        .window_avoid = .none,
    }, theme.panel(.{
        .id_extra = id_extra,
        .padding = .{ .x = transfer_popup_pad_x, .y = transfer_popup_pad_y, .w = transfer_popup_pad_x, .h = transfer_popup_pad_y },
        .corner_radius = .all(3),
        .min_size_content = .{ .w = popup_width, .h = 58 },
        .max_size_content = .{ .w = popup_width, .h = transfer_popup_max_height },
    }, palette).override(.{
        .color_fill = palette.panel_bg,
        .color_border = palette.border_subtle,
    }));
    defer win.deinit();

    dvui.label(@src(), "Transfers", .{}, .{
        .font = theme.textFont("Transfers", 9),
        .color_text = palette.text_subtle,
        .min_size_content = .height(22),
        .padding = .{ .x = 2, .y = 1, .w = 2, .h = 1 },
        .id_extra = id_extra + 1,
    });

    var scroll = dvui.scrollArea(@src(), .{
        .vertical = .auto,
        .horizontal = .none,
    }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = popup_width - transfer_popup_pad_x * 2, .h = @min(transfer_popup_max_height - 28, popupContentHeight(tasks.len)) },
        .max_size_content = .{ .w = popup_width - transfer_popup_pad_x * 2, .h = transfer_popup_max_height - 28 },
        .padding = .all(0),
        .background = true,
        .color_fill = palette.panel_bg,
        .color_border = palette.border_subtle,
        .id_extra = id_extra + 2,
    });
    defer scroll.deinit();

    if (tasks.len == 0) {
        transferEmptyRow(palette, id_extra + 3);
    } else {
        for (tasks, 0..) |task, idx| {
            if (transferTaskRow(task, popup_width, palette, id_extra + 10 + idx * 8)) |transfer_id| {
                app.cancelTransfer(transfer_id);
            }
        }
    }

    if (outsideTransferPopupClick(win.data().rectScale().r)) {
        state.transfer_popup_open = false;
        win.close();
    }
}

fn transferPopupRect(anchor: dvui.Rect.Natural, tasks: []const transfer.TransferTask) dvui.Rect {
    const width = transferPopupWidth(tasks);
    const height = @min(transfer_popup_max_height, popupContentHeight(tasks.len) + 28 + transfer_popup_pad_y * 2);
    return .{
        .x = anchor.x + anchor.w - width,
        .y = anchor.y + anchor.h + 4,
        .w = width,
        .h = height,
    };
}

fn transferPopupWidth(tasks: []const transfer.TransferTask) f32 {
    var width = transfer_popup_min_width;
    for (tasks) |task| {
        const measured = theme.textFont(task.title, 9).textSize(task.title).w;
        const estimated = @as(f32, @floatFromInt(task.title.len)) * 7.2;
        const title_width = @max(measured, estimated) + 132;
        width = @max(width, title_width);
    }
    return @min(width, transfer_popup_max_width);
}

fn popupContentHeight(task_count: usize) f32 {
    if (task_count == 0) return 28;
    return @as(f32, @floatFromInt(task_count)) * transfer_task_row_height;
}

fn transferEmptyRow(palette: theme.Palette, id_extra: usize) void {
    dvui.label(@src(), "No active tasks", .{}, .{
        .font = theme.textFont("No active tasks", 9),
        .color_text = palette.muted_text,
        .min_size_content = .{ .w = 240, .h = 26 },
        .gravity_y = 0.5,
        .padding = .{ .x = 2, .y = 1, .w = 2, .h = 1 },
        .id_extra = id_extra,
    });
}

fn transferTaskRow(task: transfer.TransferTask, popup_width: f32, palette: theme.Palette, id_extra: usize) ?u64 {
    var row = dvui.box(@src(), .{ .dir = .vertical }, theme.panel(.{
        .expand = .horizontal,
        .min_size_content = .{ .w = popup_width - transfer_popup_pad_x * 2 - 6, .h = transfer_task_row_height },
        .max_size_content = .height(transfer_task_row_height),
        .padding = .{ .x = 2, .y = 1, .w = 2, .h = 1 },
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 2 },
        .corner_radius = .all(2),
        .border = .all(1),
        .id_extra = id_extra,
    }, palette).override(.{
        .color_fill = palette.panel_bg,
        .color_border = palette.border,
    }));
    defer row.deinit();
    var canceled_id: ?u64 = null;

    const can_cancel = task.status == .pending or task.status == .running;
    {
        var title_line = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .min_size_content = .height(24),
            .max_size_content = .height(24),
            .padding = .all(0),
            .id_extra = id_extra + 1,
        });
        defer title_line.deinit();

        dvui.label(@src(), "{s}", .{task.title}, .{
            .font = theme.textFont(task.title, 9),
            .color_text = palette.text,
            .expand = .horizontal,
            .min_size_content = .height(24),
            .max_size_content = .height(24),
            .padding = .{ .x = 2, .y = 1, .w = 2, .h = 1 },
            .id_extra = id_extra + 2,
        });

        if (transferCloseButton(can_cancel, palette, id_extra + 3)) {
            canceled_id = task.id;
        }
    }

    var progress_buf: [32]u8 = undefined;
    const clamped = @max(0, @min(task.progress, 1));
    const percent = std.fmt.bufPrint(&progress_buf, "{d:.0}%", .{clamped * 100}) catch "0%";
    var status_buf: [80]u8 = undefined;
    const status_text = std.fmt.bufPrint(&status_buf, "{s} {s}", .{ task.status.label(), percent }) catch task.status.label();
    {
        var status_line = dvui.box(@src(), .{}, .{
            .expand = .horizontal,
            .min_size_content = .height(22),
            .max_size_content = .height(22),
            .padding = .all(0),
            .id_extra = id_extra + 4,
        });
        defer status_line.deinit();

        dvui.label(@src(), "{s}", .{status_text}, .{
            .font = theme.textFont(status_text, 9),
            .color_text = palette.muted_text,
            .expand = .horizontal,
            .min_size_content = .height(22),
            .max_size_content = .height(22),
            .padding = .{ .x = 2, .y = 1, .w = 2, .h = 1 },
            .id_extra = id_extra + 5,
        });
    }

    {
        var bar_line = dvui.box(@src(), .{}, .{
            .expand = .horizontal,
            .min_size_content = .height(16),
            .max_size_content = .height(16),
            .padding = .{ .x = 2, .y = 5, .w = 2, .h = 5 },
            .id_extra = id_extra + 6,
        });
        defer bar_line.deinit();

        var bar = dvui.box(@src(), .{}, .{
            .expand = .horizontal,
            .min_size_content = .height(6),
            .max_size_content = .height(6),
            .background = true,
            .color_fill = palette.surface_hover,
            .corner_radius = .all(2),
            .id_extra = id_extra + 7,
        });
        const bar_rect = bar.data().contentRectScale().r;
        if (!bar_rect.empty()) {
            var fill = bar_rect;
            fill.w *= clamped;
            fill.fill(.{}, .{ .color = palette.accent });
        }
        bar.deinit();
    }
    return canceled_id;
}

fn transferCloseButton(enabled: bool, palette: theme.Palette, id_extra: usize) bool {
    var bw: dvui.ButtonWidget = undefined;
    var options = theme.buttonOptions(.{
        .min_size_content = .{ .w = transfer_close_button_size, .h = transfer_close_button_size },
        .max_size_content = .{ .w = transfer_close_button_size, .h = transfer_close_button_size },
        .padding = .{ .x = 2, .y = 1, .w = 2, .h = 1 },
        .corner_radius = .all(2),
        .id_extra = id_extra,
    }, palette, .{ .variant = .ghost, .font_size = 9 });
    if (!enabled) {
        options = options.override(.{
            .color_fill_hover = dvui.Color.transparent,
            .color_fill_press = dvui.Color.transparent,
            .tab_index = 0,
            .role = .none,
        });
    }

    bw.init(@src(), .{ .draw_focus = false }, options);
    if (enabled) bw.processEvents();
    bw.drawBackground();

    const color = if (enabled) bw.style().color(.text) else palette.text_subtle;
    renderThemedPng(close_icon_bytes, "close.png", bw.data().contentRectScale(), color);

    const clicked = enabled and bw.clicked();
    bw.drawFocus();
    bw.deinit();
    return clicked;
}

fn renderThemedPng(bytes: []const u8, name: []const u8, rs: dvui.RectScale, color: dvui.Color) void {
    const source: dvui.ImageSource = .{ .imageFile = .{
        .bytes = bytes,
        .name = name,
        .interpolation = .linear,
    } };
    dvui.renderImage(source, rs, .{ .colormod = color }) catch {};
}

fn outsideTransferPopupClick(menu_rect: dvui.Rect.Physical) bool {
    if (menu_rect.empty()) return false;
    for (dvui.events()) |event| {
        if (event.handled or event.evt != .mouse) continue;
        const mouse = event.evt.mouse;
        if (mouse.action != .press or !mouse.button.pointer()) continue;
        if (menu_rect.contains(mouse.p)) continue;
        return true;
    }
    return false;
}

const PaneKind = enum { local, remote };
const TreeRowAction = enum { none, toggle, row_click };
const PaneOptions = struct {
    snapshot: remote_file.FilePaneSnapshot,
    width: ?f32,
    id_extra: usize,
};

fn filePane(kind: PaneKind, palette: theme.Palette, opts: PaneOptions, intent: *?remote_file.FilePanelIntent) void {
    var options = dvui.Options{
        .expand = .vertical,
        .padding = .all(0),
        .id_extra = opts.id_extra,
    };
    if (opts.width) |width| {
        options.min_size_content = .width(width);
        options.max_size_content = .width(width);
    } else {
        options.expand = .both;
    }

    var pane = dvui.box(@src(), .{ .dir = .vertical }, theme.panel(options, palette).override(.{
        .color_fill = palette.panel_bg,
        .color_border = palette.border_subtle,
    }));
    defer pane.deinit();
    const layout = dvui.dataGetPtrDefault(null, pane.data().id, "file-pane-layout", PaneLayoutState, .{});

    if (kind == .local) { //清理
        treeRows(opts.snapshot, layout, palette, opts.id_extra + 20, intent);
        return;
    }
    layout.observeToast(opts.snapshot.error_summary);
    failureToast(layout, palette, opts.id_extra + 6); //TODO: 去掉
    tableHeader(layout, palette, opts.id_extra + 10);
    fileRows(kind, opts.snapshot, layout, palette, opts.id_extra + 30, intent);
    deleteConfirmModal(opts.snapshot, layout, palette, opts.id_extra + 5000, intent);
}

fn tableHeader(layout: *PaneLayoutState, palette: theme.Palette, id_extra: usize) void {
    const columns = layout.columns;
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = totalColumnWidth(columns), .h = header_height },
        .max_size_content = .height(header_height),
        .padding = .all(0),
        .id_extra = id_extra,
    });
    defer row.deinit();

    headerCell("Name", columns.name, palette, id_extra + 1);
    resize.handle(palette, .{ .axis = .vertical, .value = &layout.columns.name, .min = min_name_width, .max = max_name_width, .id_extra = id_extra + 2, .thickness = 7, .sep_thickness = 0 });
    headerCell("Size", columns.size, palette, id_extra + 3);
    resize.handle(palette, .{ .axis = .vertical, .value = &layout.columns.size, .min = min_size_width, .max = max_size_width, .id_extra = id_extra + 4, .thickness = 7, .sep_thickness = 0 });
    headerCell("Modified", columns.modified, palette, id_extra + 5);
    resize.handle(palette, .{ .axis = .vertical, .value = &layout.columns.modified, .min = min_modified_width, .max = max_modified_width, .id_extra = id_extra + 6, .thickness = 7, .sep_thickness = 0 });
    headerCell("Perm", columns.perm, palette, id_extra + 7);
    resize.handle(palette, .{ .axis = .vertical, .value = &layout.columns.perm, .min = min_perm_width, .max = max_perm_width, .id_extra = id_extra + 8, .thickness = 7, .sep_thickness = 0 });
    headerCell("User/Group", columns.owner, palette, id_extra + 9);

    drawColumnSeparators(row.data().contentRectScale(), columns, palette);
}

fn fileRows(kind: PaneKind, snapshot: remote_file.FilePaneSnapshot, layout: *PaneLayoutState, palette: theme.Palette, id_extra: usize, intent: *?remote_file.FilePanelIntent) void {
    var scroll = dvui.scrollArea(@src(), .{
        .vertical = .auto,
        .vertical_bar = .auto_overlay,
        .horizontal = .auto,
        .horizontal_bar = .auto_overlay,
        .process_events_after = true,
    }, .{
        .expand = .both,
        .background = true,
        .color_fill = palette.panel_bg,
        .color_border = palette.border_subtle,
        .padding = .all(0),
        .id_extra = id_extra,
    });
    defer scroll.deinit();

    switch (snapshot.state) {
        .unavailable => {
            emptyRow(snapshot.error_summary orelse "File runtime is not available.", palette, id_extra);
            return;
        },
        .loading => {
            emptyRow("Loading files...", palette, id_extra);
            return;
        },
        .failed => {
            emptyRow(snapshot.error_summary orelse "Could not load files.", palette, id_extra);
            return;
        },
        .ready => {},
    }

    if (layout.edit_mode == .new_file or layout.edit_mode == .new_folder) {
        editFileRow(snapshot, layout, palette, id_extra + 3, intent);
    }

    if (snapshot.entries.len == 0 and layout.edit_mode == .none) {
        emptyRow("No files", palette, id_extra);
        blankContextMenu(snapshot, layout, blankContextRect(scroll.data().contentRectScale(), 1), palette, id_extra + 500, intent);
        return;
    }

    for (snapshot.entries, 0..) |entry, idx| {
        fileRow(kind, snapshot, entry, layout, palette, id_extra + idx * 10, intent);
    }
    const row_count = snapshot.entries.len + if (layout.edit_mode == .new_file or layout.edit_mode == .new_folder) @as(usize, 1) else 0;
    blankContextMenu(snapshot, layout, blankContextRect(scroll.data().contentRectScale(), row_count), palette, id_extra + 500, intent);
}

fn treeRows(snapshot: remote_file.FilePaneSnapshot, layout: *PaneLayoutState, palette: theme.Palette, id_extra: usize, intent: *?remote_file.FilePanelIntent) void {
    var scroll = dvui.scrollArea(@src(), .{
        .vertical = .auto,
        .vertical_bar = .auto_overlay,
        .horizontal = .none,
        .process_events_after = true,
    }, .{
        .expand = .both,
        .background = true,
        .color_fill = palette.panel_bg,
        .color_border = palette.border_subtle,
        .padding = .all(0),
        .id_extra = id_extra,
    });
    defer scroll.deinit();

    if (snapshot.entries.len == 0) {
        switch (snapshot.state) {
            .unavailable => {
                emptyRow(snapshot.error_summary orelse "File tree is not available.", palette, id_extra + 1);
                return;
            },
            .loading => {
                emptyRow("Loading folders...", palette, id_extra + 1);
                return;
            },
            .failed => {
                emptyRow(snapshot.error_summary orelse "Could not load folders.", palette, id_extra + 1);
                return;
            },
            .ready => {},
        }
    }

    for (snapshot.entries, 0..) |entry, idx| {
        treeRow(snapshot, entry, layout, palette, id_extra + 10 + idx * 10, intent);
    }
}

fn treeRow(snapshot: remote_file.FilePaneSnapshot, entry: remote_file.RemoteFileEntry, layout: *PaneLayoutState, palette: theme.Palette, id_extra: usize, intent: *?remote_file.FilePanelIntent) void {
    const selected = treeEntrySelected(snapshot.path, entry);
    var row = dvui.box(@src(), .{}, .{
        .expand = .horizontal,
        .background = true,
        .min_size_content = .height(row_height),
        .max_size_content = .height(row_height),
        .padding = .all(0),
        .margin = .all(0),
        .corner_radius = .all(0),
        .id_extra = id_extra,
        .color_fill = if (selected) palette.surface_active else palette.panel_bg,
        .color_border = palette.border_subtle,
    });
    defer row.deinit();

    var hover = false;
    const crs = row.data().contentRectScale();
    const toggle_rect = treeToggleRect(crs, entry);
    const action = treeRowAction(row.data(), crs.r, toggle_rect, &hover);
    row.data().options = row.data().options.override(.{
        .color_fill = if (selected) palette.surface_active else if (hover) palette.surface_hover else palette.panel_bg,
    });
    row.drawBackground();

    const path = if (entry.full_path.len > 0) entry.full_path else snapshot.path;
    switch (action) {
        .toggle => intent.* = .{ .toggle_tree = .{
            .pane = .remote,
            .path = path,
            .name = "",
        } },
        .row_click => {
            if (registerEntryClick(layout, .local, path) >= 2) {
                intent.* = .{ .toggle_tree = .{
                    .pane = .remote,
                    .path = path,
                    .name = "",
                } };
            }
        },
        .none => {},
    }

    renderTreeEntry(crs, entry, palette);
}

fn treeRowAction(data: *dvui.WidgetData, row_rect: dvui.Rect.Physical, toggle_rect: dvui.Rect.Physical, hovered: *bool) TreeRowAction {
    for (dvui.events()) |*event| {
        if (!dvui.eventMatch(event, .{ .id = data.id, .r = row_rect })) continue;
        switch (event.evt) {
            .mouse => |mouse| switch (mouse.action) {
                .position => hovered.* = true,
                .release => if (mouse.button.pointer()) {
                    event.handle(@src(), data);
                    dvui.refresh(null, @src(), data.id);
                    return if (toggle_rect.contains(mouse.p)) .toggle else .row_click;
                },
                else => {},
            },
            else => {},
        }
    }
    return .none;
}

fn treeToggleRect(crs: dvui.RectScale, entry: remote_file.RemoteFileEntry) dvui.Rect.Physical {
    const indent = (@as(f32, @floatFromInt(entry.depth)) * tree_indent + 8) * crs.s;
    return .{
        .x = crs.r.x + indent,
        .y = crs.r.y,
        .w = tree_disclosure_width * crs.s,
        .h = crs.r.h,
    };
}

fn fileRow(kind: PaneKind, snapshot: remote_file.FilePaneSnapshot, entry: remote_file.RemoteFileEntry, layout: *PaneLayoutState, palette: theme.Palette, id_extra: usize, intent: *?remote_file.FilePanelIntent) void {
    if (layout.edit_mode == .rename and std.mem.eql(u8, layout.editingTargetName(), entry.name)) {
        editFileRow(snapshot, layout, palette, id_extra, intent);
        return;
    }

    const columns = layout.columns;
    const total_width = totalColumnWidth(columns);
    const selected = layout.isSelected(entry.name) or if (snapshot.selected_name) |name| std.mem.eql(u8, name, entry.name) else false;
    var button: dvui.ButtonWidget = undefined;
    button.init(@src(), .{ .draw_focus = false }, theme.buttonOptions(.{
        .expand = .horizontal,
        .min_size_content = .{ .w = total_width, .h = row_height },
        .max_size_content = .height(row_height),
        .padding = .all(0),
        .margin = .all(0),
        .corner_radius = .all(0),
        .id_extra = id_extra,
    }, palette, .{ .variant = .row, .font_size = 10, .text_align_x = 0 }).override(.{
        .color_fill = if (selected) palette.surface_active else palette.panel_bg,
        .color_fill_hover = if (selected) palette.surface_active else palette.surface_hover,
        .color_fill_press = if (selected) palette.surface_active else palette.surface_hover,
        .color_border = palette.border_subtle,
    }));
    defer button.deinit();
    const click_event = dvui.clickedEx(button.data(), .{ .hovered = &button.hover });
    button.drawBackground();

    if (click_event) |event| {
        const pane = paneTarget(kind);
        const additive = clickAdditive(event);
        if (entry.isDirectory() and registerEntryClick(layout, kind, entry.name) >= 2) {
            intent.* = .{ .open = .{
                .pane = pane,
                .path = snapshot.path,
                .name = entry.name,
            } };
        } else {
            layout.applySelection(entry.name, additive);
            intent.* = .{ .select = .{
                .target = .{
                    .pane = pane,
                    .path = snapshot.path,
                    .name = entry.name,
                    .kind = entry.kind,
                },
                .additive = additive,
            } };
        }
    }

    const crs = button.data().contentRectScale();
    var x: f32 = 0;
    renderNameCell(crs, x, columns.name, entry, palette, id_extra + 1);
    maybeNameTooltip(entry.name, crs, x, columns.name, id_extra + 2);
    x += columns.name;
    var size_buf: [32]u8 = undefined;
    renderCellText(crs, x, columns.size, sizeText(entry, &size_buf), palette.muted_text, id_extra + 3);
    x += columns.size;
    var modified_buf: [32]u8 = undefined;
    renderCellText(crs, x, columns.modified, modifiedText(entry, &modified_buf), palette.muted_text, id_extra + 4);
    x += columns.modified;
    var perm_buf: [12]u8 = undefined;
    renderCellText(crs, x, columns.perm, permissionText(entry, &perm_buf), palette.muted_text, id_extra + 5);
    x += columns.perm;
    var owner_buf: [40]u8 = undefined;
    renderCellText(crs, x, columns.owner, ownerText(entry, &owner_buf), palette.muted_text, id_extra + 6);

    entryContextMenu(kind, snapshot, entry, layout, crs.r, palette, id_extra + 100, intent);
    button.drawFocus();
}

fn editFileRow(snapshot: remote_file.FilePaneSnapshot, layout: *PaneLayoutState, palette: theme.Palette, id_extra: usize, intent: *?remote_file.FilePanelIntent) void {
    const columns = layout.columns;
    const mode = layout.edit_mode;
    if (mode == .none) return;

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = palette.panel_bg,
        .color_border = palette.border_subtle,
        .min_size_content = .{ .w = totalColumnWidth(columns), .h = row_height },
        .max_size_content = .height(row_height),
        .padding = .all(0),
        .margin = .all(0),
        .corner_radius = .all(0),
        .id_extra = id_extra,
    });
    defer row.deinit();

    var name_cell = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .min_size_content = .{ .w = columns.name, .h = row_height },
        .max_size_content = .width(columns.name),
        .padding = .{ .x = 8, .y = 0, .w = 8, .h = 0 },
        .id_extra = id_extra + 1,
    });
    defer name_cell.deinit();

    const icon_entry = remote_file.RemoteFileEntry{
        .name = editName(layout),
        .kind = if (mode == .new_folder) .directory else .file,
    };
    var icon_slot = dvui.box(@src(), .{}, .{
        .min_size_content = .{ .w = file_icon_size + file_icon_gap, .h = row_height },
        .max_size_content = .{ .w = file_icon_size + file_icon_gap, .h = row_height },
        .padding = .all(0),
        .id_extra = id_extra + 2,
    });
    const icon_crs = icon_slot.data().contentRectScale();
    const icon_rect = dvui.Rect.Physical{
        .x = icon_crs.r.x,
        .y = icon_crs.r.y + @round((icon_crs.r.h - file_icon_size * icon_crs.s) / 2),
        .w = file_icon_size * icon_crs.s,
        .h = file_icon_size * icon_crs.s,
    };
    const icon = iconForEntry(icon_entry);
    renderPng(icon.bytes, icon.name, .{ .r = icon_rect, .s = icon_crs.s }, iconColor(icon_entry, palette));
    icon_slot.deinit();

    var te: dvui.TextEntryWidget = undefined;
    te.init(@src(), .{ .text = .{ .buffer = &layout.edit_buffer } }, theme.panel(.{
        .expand = .horizontal,
        .min_size_content = .height(row_height - 4),
        .font = theme.textFont("filename", 10),
        .padding = .{ .x = 4, .y = 0, .w = 4, .h = 0 },
        .corner_radius = .all(0),
        .id_extra = id_extra + 3,
    }, palette).override(.{
        .color_fill = palette.surface_bg,
        .color_border = palette.border,
    }));
    if (layout.edit_focus_requested) {
        dvui.focusWidget(te.data().id, null, null);
        layout.edit_focus_requested = false;
    }
    if (layout.edit_select_requested or (mode == .rename and dvui.firstFrame(te.data().id))) {
        var sel = te.textLayout.selection;
        sel.start = 0;
        sel.cursor = 0;
        sel.end = std.math.maxInt(usize);
        layout.edit_select_requested = false;
    }
    te.processEvents();
    te.draw();
    const entered = te.enter_pressed;
    const focused = dvui.focusedWidgetIdInCurrentSubwindow() == te.data().id;
    const should_commit = entered or (layout.edit_was_focused and !focused);
    const name = layout.edit_buffer[0..te.len];
    te.deinit();

    layout.edit_was_focused = focused;
    if (should_commit) commitEdit(snapshot, layout, name, intent);
}

fn commitEdit(snapshot: remote_file.FilePaneSnapshot, layout: *PaneLayoutState, raw_name: []const u8, intent: *?remote_file.FilePanelIntent) void {
    const mode = layout.edit_mode;
    const name = std.mem.trim(u8, raw_name, " \t\r\n");
    defer layout.cancelEdit();

    if (name.len == 0 or !validFileName(name)) return;
    switch (mode) {
        .new_file => intent.* = .{ .create_file = .{
            .pane = .remote,
            .parent_path = snapshot.path,
            .name = name,
        } },
        .new_folder => intent.* = .{ .create_directory = .{
            .pane = .remote,
            .parent_path = snapshot.path,
            .name = name,
        } },
        .rename => {
            const old_name = layout.editingTargetName();
            if (std.mem.eql(u8, old_name, name)) return;
            intent.* = .{ .rename = .{
                .pane = .remote,
                .path = snapshot.path,
                .old_name = old_name,
                .new_name = name,
            } };
        },
        .none => {},
    }
}

fn editName(layout: *const PaneLayoutState) []const u8 {
    const end = std.mem.indexOfScalar(u8, &layout.edit_buffer, 0) orelse layout.edit_buffer.len;
    return layout.edit_buffer[0..end];
}

fn validFileName(name: []const u8) bool {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return std.mem.indexOfAny(u8, name, "/\x00") == null;
}

fn downloadIntent(snapshot: remote_file.FilePaneSnapshot, layout: *PaneLayoutState, entry: remote_file.RemoteFileEntry) remote_file.FilePanelIntent {
    const selected_count = selectedEntriesForAction(snapshot, layout, entry);
    if (selected_count <= 1 and entry.kind != .directory) {
        return .{ .download = .{
            .local_path = "",
            .remote_path = snapshot.path,
            .name = entry.name,
        } };
    }
    return .{ .download_many = .{
        .local_path = "",
        .remote_path = snapshot.path,
        .entries = layout.action_entries[0..selected_count],
    } };
}

fn selectedEntriesForAction(snapshot: remote_file.FilePaneSnapshot, layout: *PaneLayoutState, fallback: remote_file.RemoteFileEntry) usize {
    if (layout.selected_count == 0 or !layout.isSelected(fallback.name)) {
        layout.action_entries[0] = .{ .name = fallback.name, .kind = fallback.kind };
        return 1;
    }

    var count: usize = 0;
    for (layout.selected_names[0..layout.selected_count], layout.selected_name_lens[0..layout.selected_count]) |name_buf, name_len| {
        const name = name_buf[0..name_len];
        if (std.mem.eql(u8, name, "..")) continue;
        if (entryByName(snapshot, name)) |entry| {
            layout.action_entries[count] = .{ .name = entry.name, .kind = entry.kind };
            count += 1;
            if (count >= layout.action_entries.len) break;
        }
    }
    if (count == 0) {
        layout.action_entries[0] = .{ .name = fallback.name, .kind = fallback.kind };
        return 1;
    }
    return count;
}

fn entryByName(snapshot: remote_file.FilePaneSnapshot, name: []const u8) ?remote_file.RemoteFileEntry {
    for (snapshot.entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

fn deleteConfirmModal(snapshot: remote_file.FilePaneSnapshot, layout: *PaneLayoutState, palette: theme.Palette, id_extra: usize, intent: *?remote_file.FilePanelIntent) void {
    if (!layout.delete_pending) return;

    var menu = dvui.floatingMenu(@src(), .{ .from = .fromPoint(layout.delete_anchor) }, deleteConfirmOptions(palette, id_extra));
    defer menu.deinit();

    dvui.label(@src(), "Delete {s}?", .{layout.deleteName()}, .{
        .font = theme.textFont("Delete file?", 9),
        .color_text = palette.text,
        .expand = .horizontal,
        .min_size_content = .{ .w = 142, .h = 18 },
        .max_size_content = .height(18),
        .padding = .{ .x = 4, .y = 1, .w = 4, .h = 1 },
        .id_extra = id_extra + 1,
    });

    var actions = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 3, .w = 0, .h = 0 },
        .id_extra = id_extra + 2,
    });
    defer actions.deinit();

    if (theme.button(@src(), "Cancel", .{
        .min_size_content = .{ .w = 62, .h = 19 },
        .id_extra = id_extra + 3,
    }, palette, .{ .variant = .ghost, .font_size = 9 })) {
        layout.delete_pending = false;
        menu.close();
    }
    if (theme.button(@src(), "Delete", .{
        .min_size_content = .{ .w = 62, .h = 19 },
        .id_extra = id_extra + 4,
    }, palette, .{ .variant = .solid, .intent = .danger, .font_size = 9 })) {
        intent.* = .{ .delete = .{
            .pane = .remote,
            .path = snapshot.path,
            .name = layout.deleteName(),
            .kind = layout.delete_kind,
        } };
        layout.delete_pending = false;
        menu.close();
    }

    if (outsideDeleteConfirmClick(menu.data().rectScale().r)) {
        layout.delete_pending = false;
        menu.close();
    }
}

fn deleteConfirmOptions(palette: theme.Palette, id_extra: usize) dvui.Options {
    return .{
        .id_extra = id_extra,
        .background = true,
        .color_fill = palette.app_bg,
        .color_border = palette.border,
        .color_text = palette.text,
        .border = .all(1),
        .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
        .corner_radius = .all(3),
        .min_size_content = .{ .w = 156, .h = 48 },
    };
}

fn outsideDeleteConfirmClick(menu_rect: dvui.Rect.Physical) bool {
    if (menu_rect.empty()) return false;
    for (dvui.events()) |event| {
        if (event.handled or event.evt != .mouse) continue;
        const mouse = event.evt.mouse;
        if (mouse.action != .press or !mouse.button.pointer()) continue;
        if (menu_rect.contains(mouse.p)) continue;
        return true;
    }
    return false;
}

fn failureToast(layout: *PaneLayoutState, palette: theme.Palette, id_extra: usize) void {
    if (layout.toast_message_len == 0) return;
    if (dvui.frameTimeNS() - layout.toast_started_ns > toast_visible_ns) {
        layout.dismissToast();
        return;
    }

    for (dvui.events()) |*event| {
        if (event.evt == .mouse and event.evt.mouse.action == .press) {
            layout.dismissToast();
            return;
        }
    }

    var toast = dvui.box(@src(), .{}, theme.panel(.{
        .min_size_content = .height(22),
        .padding = .{ .x = 8, .y = 2, .w = 8, .h = 2 },
        .corner_radius = .all(3),
        .id_extra = id_extra,
    }, palette).override(.{
        .color_fill = palette.surface_active,
        .color_border = palette.border,
    }));
    defer toast.deinit();

    const message = layout.toastMessage();
    dvui.label(@src(), "{s}", .{message}, .{
        .font = theme.textFont(message, 9),
        .color_text = palette.text,
        .id_extra = id_extra + 1,
    });
}

fn registerEntryClick(layout: *PaneLayoutState, pane: PaneKind, name: []const u8) u8 {
    const now = dvui.frameTimeNS();
    const same_pane = layout.last_click_pane == pane;
    const same_name = std.mem.eql(u8, lastClickName(layout), name);
    const count: u8 = if (same_pane and same_name and now - layout.last_click_ns <= double_click_window_ns) 2 else 1;
    layout.last_click_pane = pane;
    layout.last_click_ns = now;
    const len = @min(layout.last_click_name.len, name.len);
    if (len > 0) @memcpy(layout.last_click_name[0..len], name[0..len]);
    layout.last_click_name_len = len;
    return count;
}

fn lastClickName(layout: *const PaneLayoutState) []const u8 {
    return layout.last_click_name[0..layout.last_click_name_len];
}

fn clickAdditive(event: dvui.Event.EventTypes) bool {
    return switch (event) {
        .mouse => |mouse| mouse.mod.control() or mouse.mod.command(),
        .key => |key| key.mod.control() or key.mod.command(),
        else => false,
    };
}

fn headerCell(text: []const u8, width: f32, palette: theme.Palette, id_extra: usize) void {
    const horizontal_padding: f32 = 16;
    const content_width = @max(0, width - horizontal_padding);
    dvui.label(@src(), "{s}", .{text}, .{
        .font = theme.textFont(text, 9),
        .color_text = palette.text_subtle,
        .min_size_content = .width(content_width),
        .max_size_content = .width(content_width),
        .gravity_y = 0.5,
        .padding = .{ .x = 8, .y = 0, .w = 8, .h = 0 },
        .id_extra = id_extra,
    });
}

fn drawColumnSeparators(crs: dvui.RectScale, columns: ColumnWidths, palette: theme.Palette) void {
    var x = columns.name;
    drawColumnSeparator(crs, x, palette);
    x += columns.size;
    drawColumnSeparator(crs, x, palette);
    x += columns.modified;
    drawColumnSeparator(crs, x, palette);
    x += columns.perm;
    drawColumnSeparator(crs, x, palette);
}

fn drawColumnSeparator(crs: dvui.RectScale, x: f32, palette: theme.Palette) void {
    const line = dvui.Rect.Physical{
        .x = crs.r.x + @round(x * crs.s),
        .y = crs.r.y,
        .w = @max(1, crs.s),
        .h = crs.r.h,
    };
    line.fill(.{}, .{ .color = palette.border_subtle });
}

fn emptyRow(text: []const u8, palette: theme.Palette, id_extra: usize) void {
    dvui.label(@src(), "{s}", .{text}, .{
        .font = theme.textFont(text, 10),
        .color_text = palette.muted_text,
        .expand = .horizontal,
        .min_size_content = .height(row_height),
        .max_size_content = .height(row_height),
        .gravity_y = 0.5,
        .padding = .{ .x = 8, .y = 0, .w = 8, .h = 0 },
        .id_extra = id_extra,
    });
}

fn entryContextMenu(kind: PaneKind, snapshot: remote_file.FilePaneSnapshot, entry: remote_file.RemoteFileEntry, layout: *PaneLayoutState, rect: dvui.Rect.Physical, palette: theme.Palette, id_extra: usize, intent: *?remote_file.FilePanelIntent) void {
    if (rect.empty()) return;

    const context = dvui.context(@src(), .{ .rect = rect }, .{ .id_extra = id_extra });
    defer context.deinit();

    const active_point = context.activePoint() orelse return;
    var menu = dvui.floatingMenu(@src(), .{ .from = .fromPoint(active_point) }, fileContextMenuOptions(palette, id_extra + 1));
    defer menu.deinit();

    const can_mutate = kind == .remote and snapshot.state == .ready;
    if (fileContextMenuItem("New File", can_mutate, palette, id_extra + 2)) |_| {
        layout.startCreate(.new_file);
        menu.close();
    }
    if (fileContextMenuItem("New Folder", can_mutate and snapshot.capabilities.can_create_directory, palette, id_extra + 3)) |_| {
        layout.startCreate(.new_folder);
        menu.close();
    }
    if (fileContextMenuItem("Rename", can_mutate and snapshot.capabilities.can_rename, palette, id_extra + 4)) |_| {
        layout.startRename(entry.name);
        menu.close();
    }
    if (fileContextMenuItem("Delete", can_mutate and snapshot.capabilities.can_delete, palette, id_extra + 5)) |_| {
        layout.setDeletePending(entry.name, entry.kind, active_point);
        menu.close();
    }
    if (fileContextMenuItem("Download", can_mutate and snapshot.capabilities.can_download, palette, id_extra + 6)) |_| {
        intent.* = downloadIntent(snapshot, layout, entry);
        menu.close();
    }
}

fn blankContextMenu(snapshot: remote_file.FilePaneSnapshot, layout: *PaneLayoutState, rect: dvui.Rect.Physical, palette: theme.Palette, id_extra: usize, intent: *?remote_file.FilePanelIntent) void {
    _ = intent;
    if (rect.empty()) return;

    const context = dvui.context(@src(), .{ .rect = rect }, .{ .id_extra = id_extra });
    defer context.deinit();

    const active_point = context.activePoint() orelse return;
    var menu = dvui.floatingMenu(@src(), .{ .from = .fromPoint(active_point) }, fileContextMenuOptions(palette, id_extra + 1));
    defer menu.deinit();

    const can_mutate = snapshot.state == .ready;
    if (fileContextMenuItem("New File", can_mutate, palette, id_extra + 2)) |_| {
        layout.startCreate(.new_file);
        menu.close();
    }
    if (fileContextMenuItem("New Folder", can_mutate and snapshot.capabilities.can_create_directory, palette, id_extra + 3)) |_| {
        layout.startCreate(.new_folder);
        menu.close();
    }
}

fn blankContextRect(crs: dvui.RectScale, row_count: usize) dvui.Rect.Physical {
    const consumed_h = @as(f32, @floatFromInt(row_count)) * row_height * crs.s;
    if (consumed_h >= crs.r.h) return .{};
    return .{
        .x = crs.r.x,
        .y = crs.r.y + consumed_h,
        .w = crs.r.w,
        .h = crs.r.h - consumed_h,
    };
}

fn fileContextMenuOptions(palette: theme.Palette, id_extra: usize) dvui.Options {
    return .{
        .id_extra = id_extra,
        .background = true,
        .color_fill = palette.app_bg,
        .color_border = palette.border,
        .color_text = palette.text,
        .border = .all(1),
        .padding = .all(0),
        .corner_radius = .all(3),
    };
}

fn fileContextMenuItem(label: []const u8, enabled: bool, palette: theme.Palette, id_extra: usize) ?dvui.Rect.Natural {
    const text_color = if (enabled) palette.text else palette.text_subtle;
    const result = dvui.menuItemLabel(@src(), label, .{}, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .background = true,
        .font = theme.textFont(label, context_menu_font_size),
        .color_fill = dvui.Color.transparent,
        .color_fill_hover = if (enabled) palette.surface_active else dvui.Color.transparent,
        .color_fill_press = if (enabled) palette.active_bg else dvui.Color.transparent,
        .color_text = text_color,
        .color_text_hover = text_color,
        .color_text_press = text_color,
        .padding = .{ .x = 2, .y = 1, .w = 2, .h = 1 },
        .min_size_content = .{ .h = 17 },
        .corner_radius = .all(2),
    });
    return if (enabled) result else null;
}

fn renderNameCell(crs: dvui.RectScale, x_offset: f32, width: f32, entry: remote_file.RemoteFileEntry, palette: theme.Palette, id_extra: usize) void {
    _ = id_extra;
    const pad: f32 = 8 * crs.s;
    const icon_size = file_icon_size * crs.s;
    const icon_gap = file_icon_gap * crs.s;
    const cell_rect = dvui.Rect.Physical{
        .x = crs.r.x + x_offset * crs.s,
        .y = crs.r.y,
        .w = width * crs.s,
        .h = crs.r.h,
    };
    const icon_rect = dvui.Rect.Physical{
        .x = cell_rect.x + pad,
        .y = cell_rect.y + @round((cell_rect.h - icon_size) / 2),
        .w = icon_size,
        .h = icon_size,
    };
    const icon = iconForEntry(entry);
    renderPng(icon.bytes, icon.name, .{ .r = icon_rect, .s = crs.s }, iconColor(entry, palette));

    const text_x = icon_rect.x + icon_rect.w + icon_gap;
    const text_rect = dvui.Rect.Physical{
        .x = text_x,
        .y = cell_rect.y,
        .w = @max(0, cell_rect.x + cell_rect.w - pad - text_x),
        .h = cell_rect.h,
    };
    const old_clip = dvui.clip(text_rect);
    defer dvui.clipSet(old_clip);

    const font = theme.textFont(entry.name, 10);
    const text_size = font.textSize(entry.name);
    dvui.renderText(.{
        .font = font,
        .text = entry.name,
        .rs = .{ .r = text_rect, .s = crs.s },
        .p = .{
            .x = text_rect.x,
            .y = text_rect.y + @round((text_rect.h - text_size.h * crs.s) / 2),
        },
        .color = palette.text,
    }) catch {};
}

fn renderTreeEntry(crs: dvui.RectScale, entry: remote_file.RemoteFileEntry, palette: theme.Palette) void {
    const indent = (@as(f32, @floatFromInt(entry.depth)) * tree_indent + 8) * crs.s;
    const disclosure_w: f32 = tree_disclosure_width * crs.s;
    const icon_size = file_icon_size * crs.s;
    const icon_gap = file_icon_gap * crs.s;
    const icon_x = crs.r.x + indent + disclosure_w;
    const icon_rect = dvui.Rect.Physical{
        .x = icon_x,
        .y = crs.r.y + @round((crs.r.h - icon_size) / 2),
        .w = icon_size,
        .h = icon_size,
    };

    const disclosure_rect = dvui.Rect.Physical{
        .x = crs.r.x + indent + 3 * crs.s,
        .y = crs.r.y,
        .w = disclosure_w,
        .h = crs.r.h,
    };
    const glyph = if (entry.expanded) "v" else ">";
    const disclosure_font = theme.textFont(glyph, 9);
    const disclosure_size = disclosure_font.textSize(glyph);
    dvui.renderText(.{
        .font = disclosure_font,
        .text = glyph,
        .rs = .{ .r = disclosure_rect, .s = crs.s },
        .p = .{
            .x = disclosure_rect.x,
            .y = disclosure_rect.y + @round((disclosure_rect.h - disclosure_size.h * crs.s) / 2),
        },
        .color = palette.text_subtle,
    }) catch {};
    renderPng(folder_icon_bytes, "folder.png", .{ .r = icon_rect, .s = crs.s }, palette.accent);

    const text_x = icon_rect.x + icon_rect.w + icon_gap;
    const text_rect = dvui.Rect.Physical{
        .x = text_x,
        .y = crs.r.y,
        .w = @max(0, crs.r.x + crs.r.w - 8 * crs.s - text_x),
        .h = crs.r.h,
    };
    const old_clip = dvui.clip(text_rect);
    defer dvui.clipSet(old_clip);

    const font = theme.textFont(entry.name, 10);
    const text_size = font.textSize(entry.name);
    dvui.renderText(.{
        .font = font,
        .text = entry.name,
        .rs = .{ .r = text_rect, .s = crs.s },
        .p = .{
            .x = text_rect.x,
            .y = text_rect.y + @round((text_rect.h - text_size.h * crs.s) / 2),
        },
        .color = palette.text,
    }) catch {};
}

fn treeEntrySelected(current_path: []const u8, entry: remote_file.RemoteFileEntry) bool {
    if (entry.full_path.len == 0) return false;
    return std.mem.eql(u8, current_path, entry.full_path);
}

fn paneTarget(kind: PaneKind) remote_file.FilePaneTarget {
    return switch (kind) {
        .local => .local,
        .remote => .remote,
    };
}

fn sizeText(entry: remote_file.RemoteFileEntry, buf: []u8) []const u8 {
    if (entry.kind == .directory) return "-";
    const size = entry.size orelse return "-";
    if (size < 1024) return std.fmt.bufPrint(buf, "{d} B", .{size}) catch "-";
    if (size < 1024 * 1024) return std.fmt.bufPrint(buf, "{d} KB", .{(size + 1023) / 1024}) catch "-";
    if (size < 1024 * 1024 * 1024) return std.fmt.bufPrint(buf, "{d} MB", .{(size + 1024 * 1024 - 1) / (1024 * 1024)}) catch "-";
    return std.fmt.bufPrint(buf, "{d} GB", .{(size + 1024 * 1024 * 1024 - 1) / (1024 * 1024 * 1024)}) catch "-";
}

fn modifiedText(entry: remote_file.RemoteFileEntry, buf: []u8) []const u8 {
    const modified_unix = entry.modified_unix orelse return "-";
    if (modified_unix < 0) return "-";
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(modified_unix) };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        year_day.year,
        @intFromEnum(month_day.month),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
    }) catch "-";
}

fn permissionText(entry: remote_file.RemoteFileEntry, buf: *[12]u8) []const u8 {
    const permissions = entry.permissions orelse return "-";
    buf[0] = switch (entry.kind) {
        .directory => 'd',
        .symlink => 'l',
        else => '-',
    };
    const bits = permissions & 0o777;
    const chars = "rwxrwxrwx";
    for (0..9) |idx| {
        const bit: u32 = @as(u32, 1) << @intCast(8 - idx);
        buf[idx + 1] = if ((bits & bit) != 0) chars[idx] else '-';
    }
    return buf[0..10];
}

fn ownerText(entry: remote_file.RemoteFileEntry, buf: []u8) []const u8 {
    if (entry.uid) |uid| {
        if (entry.gid) |gid| return std.fmt.bufPrint(buf, "{d}/{d}", .{ uid, gid }) catch "-";
        return std.fmt.bufPrint(buf, "{d}/-", .{uid}) catch "-";
    }
    if (entry.gid) |gid| return std.fmt.bufPrint(buf, "-/{d}", .{gid}) catch "-";
    return "-";
}

fn totalColumnWidth(columns: ColumnWidths) f32 {
    return columns.name + columns.size + columns.modified + columns.perm + columns.owner;
}

fn renderCellText(crs: dvui.RectScale, x_offset: f32, width: f32, text: []const u8, color: dvui.Color, id_extra: usize) void {
    _ = id_extra;
    const pad: f32 = 8 * crs.s;
    const cell_rect = dvui.Rect.Physical{
        .x = crs.r.x + x_offset * crs.s,
        .y = crs.r.y,
        .w = width * crs.s,
        .h = crs.r.h,
    };
    const text_rect = cell_rect.inset(.{ .x = pad, .w = pad });
    const old_clip = dvui.clip(text_rect);
    defer dvui.clipSet(old_clip);

    const font = theme.textFont(text, 9);
    const text_size = font.textSize(text);
    dvui.renderText(.{
        .font = font,
        .text = text,
        .rs = .{ .r = text_rect, .s = crs.s },
        .p = .{
            .x = text_rect.x,
            .y = text_rect.y + @round((text_rect.h - text_size.h * crs.s) / 2),
        },
        .color = color,
    }) catch {};
}

fn maybeNameTooltip(name: []const u8, crs: dvui.RectScale, x_offset: f32, width: f32, id_extra: usize) void {
    _ = id_extra;
    const font = theme.textFont(name, 10);
    const available = @max(0, width - 16);
    if (font.textSize(name).w <= available) return;
    const active_rect = dvui.Rect.Physical{
        .x = crs.r.x + x_offset * crs.s,
        .y = crs.r.y,
        .w = width * crs.s,
        .h = crs.r.h,
    };
    dvui.tooltip(@src(), .{
        .active_rect = active_rect,
        .position = .vertical,
        .delay = tooltip_delay_us,
    }, "{s}", .{name}, .{
        .font = font,
        .color_fill = dvui.Color.black.opacity(0.92),
        .color_text = dvui.Color.white,
        .corner_radius = .all(4),
    });
}

const FileIcon = struct {
    bytes: []const u8,
    name: []const u8,
};

fn iconForEntry(entry: remote_file.RemoteFileEntry) FileIcon {
    return switch (entry.kind) {
        .directory => .{ .bytes = folder_icon_bytes, .name = "folder.png" },
        else => .{ .bytes = file_icon_bytes, .name = "file.png" },
    };
}

fn iconColor(entry: remote_file.RemoteFileEntry, palette: theme.Palette) dvui.Color {
    return switch (entry.kind) {
        .directory => palette.accent,
        .file => palette.muted_text,
        .symlink => palette.text_subtle,
        .other => palette.text_subtle,
    };
}

fn renderPng(bytes: []const u8, name: []const u8, rs: dvui.RectScale, color: dvui.Color) void {
    const source: dvui.ImageSource = .{ .imageFile = .{
        .bytes = bytes,
        .name = name,
        .interpolation = .linear,
    } };
    dvui.renderImage(source, rs, .{ .colormod = color }) catch {};
}
