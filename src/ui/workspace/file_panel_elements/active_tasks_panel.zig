const std = @import("std");
const dvui = @import("dvui");

const App = @import("../../../app/App.zig");
const transfer = @import("../../../core/transfer.zig");
const theme = @import("../../theme.zig");

const close_icon_bytes = @embedFile("shellowo-close-icon");
const retry_icon_bytes = @embedFile("shellowo-refresh-icon");

const toolbar_height: f32 = 31;
const popup_max_height: f32 = 300;
const popup_min_width: f32 = 360;
const popup_max_width: f32 = 620;
const popup_pad_x: f32 = 2;
const popup_pad_y: f32 = 1;
const task_row_height: f32 = 70;
const task_title_height: f32 = 26;
const task_status_height: f32 = 24;
const task_error_height: f32 = 22;
const action_button_content_size: f32 = 16;
const action_button_slot_width: f32 = 26;
const action_icon_size: f32 = 16;
const scrollbar_reserve: f32 = 16;

const State = struct {
    popup_open: bool = false,
    popup_anchor: dvui.Rect.Natural = .{},
    popup_rect: dvui.Rect = .{},
};

const RowAction = union(enum) {
    cancel_or_dismiss: u64,
    retry: u64,
};

pub fn showButton(app: *App, palette: theme.Palette, id_extra: usize) void {
    var count_buf: [32]u8 = undefined;
    const active_count = activeTransferCount(app.transfers.items);
    const count_label = std.fmt.bufPrint(&count_buf, "{d} active tasks", .{active_count}) catch "active tasks";

    var button_box = dvui.box(@src(), .{}, .{
        .min_size_content = .{ .w = 148, .h = toolbar_height },
        .max_size_content = .{ .w = 148, .h = toolbar_height },
        .padding = .all(0),
        .id_extra = id_extra,
    });
    const state = dvui.dataGetPtrDefault(null, button_box.data().id, "active-tasks-panel-state", State, .{});
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
        state.popup_open = !state.popup_open;
        state.popup_anchor = button_rect.toNatural();
    }

    if (state.popup_open) {
        state.popup_rect = popupRect(state.popup_anchor, app.transfers.items);
        popup(app, palette, state, id_extra + 100);
    }
}

fn activeTransferCount(tasks: []const transfer.TransferTask) usize {
    var count: usize = 0;
    for (tasks) |task| {
        if (task.status == .pending or task.status == .running) count += 1;
    }
    return count;
}

fn popup(app: *App, palette: theme.Palette, state: *State, id_extra: usize) void {
    const tasks = app.transfers.items;
    const width = popupWidth(tasks);
    var win = dvui.floatingWindow(@src(), .{
        .rect = &state.popup_rect,
        .open_flag = &state.popup_open,
        .resize = .none,
        .window_avoid = .none,
    }, theme.popup(.{
        .id_extra = id_extra,
        .padding = .{ .x = popup_pad_x, .y = popup_pad_y, .w = popup_pad_x, .h = popup_pad_y },
        .corner_radius = .all(3),
        .min_size_content = .{ .w = width, .h = 58 },
        .max_size_content = .{ .w = width, .h = popup_max_height },
    }, palette));
    defer win.deinit();

    dvui.label(@src(), "Transfers", .{}, .{
        .font = theme.textFont("Transfers", 9),
        .color_text = palette.text_subtle,
        .min_size_content = .height(22),
        .padding = .{ .x = 2, .y = 1, .w = 2, .h = 1 },
        .id_extra = id_extra + 1,
    });

    var pending_action: ?RowAction = null;
    {
        var scroll = dvui.scrollArea(@src(), .{
            .vertical = .auto,
            .horizontal = .none,
        }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = width - popup_pad_x * 2, .h = @min(popup_max_height - 28, popupContentHeight(tasks, width)) },
            .max_size_content = .{ .w = width - popup_pad_x * 2, .h = popup_max_height - 28 },
            .padding = .all(0),
            .background = true,
            .color_fill = palette.popup_bg,
            .color_border = palette.border_subtle,
            .id_extra = id_extra + 2,
        });
        defer scroll.deinit();

        if (tasks.len == 0) {
            emptyRow(palette, id_extra + 3);
        } else {
            for (tasks, 0..) |task, idx| {
                if (taskRow(task, width, palette, id_extra + 10 + idx * 20)) |action| {
                    pending_action = action;
                }
            }
        }
    }

    if (pending_action) |action| applyRowAction(app, action);

    if (outsidePopupClick(win.data().rectScale().r)) {
        state.popup_open = false;
        win.close();
    }
}

fn applyRowAction(app: *App, action: RowAction) void {
    switch (action) {
        .cancel_or_dismiss => |transfer_id| {
            const idx = transferIndex(app.transfers.items, transfer_id) orelse return;
            const status = app.transfers.items[idx].status;
            if (status == .pending or status == .running) {
                app.cancelTransfer(transfer_id);
            } else {
                app.dismissTransfer(transfer_id);
            }
        },
        .retry => |transfer_id| app.retryTransfer(transfer_id),
    }
}

fn transferIndex(tasks: []const transfer.TransferTask, transfer_id: u64) ?usize {
    for (tasks, 0..) |task, idx| {
        if (task.id == transfer_id) return idx;
    }
    return null;
}

fn popupRect(anchor: dvui.Rect.Natural, tasks: []const transfer.TransferTask) dvui.Rect {
    const width = popupWidth(tasks);
    const height = @min(popup_max_height, popupContentHeight(tasks, width) + 28 + popup_pad_y * 2);
    return .{
        .x = anchor.x + anchor.w - width,
        .y = anchor.y + anchor.h + 4,
        .w = width,
        .h = height,
    };
}

fn popupWidth(tasks: []const transfer.TransferTask) f32 {
    var width = popup_min_width;
    for (tasks) |task| {
        const measured = theme.textFont(task.title, 9).textSize(task.title).w;
        const title_width = measured + 48;
        width = @max(width, title_width);
    }
    return @min(width, popup_max_width);
}

fn popupContentHeight(tasks: []const transfer.TransferTask, width: f32) f32 {
    if (tasks.len == 0) return 28;
    var height: f32 = 0;
    for (tasks) |task| height += taskRowHeight(task, width);
    return height;
}

fn taskRowHeight(task: transfer.TransferTask, width: f32) f32 {
    const title_height = wrappedTextHeight(
        task.title,
        theme.textFont(task.title, 9),
        taskTitleWidth(task, width),
        task_title_height,
    );
    const extra_title_height = title_height - task_title_height;
    const error_height = if (task.errorSummary()) |error_summary|
        wrappedTextHeight(
            error_summary,
            theme.textFont(error_summary, 9),
            taskContentWidth(width),
            task_error_height,
        )
    else
        0;
    return task_row_height + extra_title_height + error_height;
}

fn taskContentWidth(width: f32) f32 {
    return @max(width - popup_pad_x * 2 - scrollbar_reserve - 14, 1);
}

fn taskTitleWidth(task: transfer.TransferTask, width: f32) f32 {
    return @max(taskContentWidth(width) - taskActionsWidth(task), 1);
}

fn taskActionsWidth(task: transfer.TransferTask) f32 {
    const button_count: f32 = if (task.status == .failed or task.status == .canceled) 2 else 1;
    return button_count * action_button_slot_width;
}

fn wrappedTextHeight(text: []const u8, font: dvui.Font, max_width: f32, min_height: f32) f32 {
    if (text.len == 0) return min_height;

    const line_height = @max(font.lineHeight(), 18);
    const break_width = @max(max_width, font.sizeM(1, 1).w);
    const m_width = font.sizeM(1, 1).w;
    var line_count: usize = 0;
    var pos: usize = 0;
    while (pos < text.len) {
        var end: usize = 0;
        _ = font.textSizeEx(text[pos..], .{
            .max_width = break_width,
            .end_idx = &end,
        });
        if (end == 0) {
            end = std.unicode.utf8ByteSequenceLength(text[pos]) catch 1;
        }

        var line_end = end;
        const newline = text[pos + line_end - 1] == '\n';
        if (line_end < text.len - pos and !newline and break_width > (10 * m_width)) {
            if (std.mem.findLastLinear(u8, text[pos .. pos + line_end + 1], " ")) |space_idx| {
                line_end = space_idx + 1;
            }
        }

        line_count += 1;
        pos += line_end;
    }

    const content_height = @as(f32, @floatFromInt(line_count)) * line_height + 6;
    return @max(min_height, content_height);
}

fn emptyRow(palette: theme.Palette, id_extra: usize) void {
    dvui.label(@src(), "No active tasks", .{}, .{
        .font = theme.textFont("No active tasks", 9),
        .color_text = palette.muted_text,
        .min_size_content = .{ .w = 240, .h = 26 },
        .gravity_y = 0.5,
        .padding = .{ .x = 2, .y = 1, .w = 2, .h = 1 },
        .id_extra = id_extra,
    });
}

fn taskRow(task: transfer.TransferTask, width: f32, palette: theme.Palette, id_extra: usize) ?RowAction {
    const row_height = taskRowHeight(task, width);
    const title_height = wrappedTextHeight(
        task.title,
        theme.textFont(task.title, 9),
        taskTitleWidth(task, width),
        task_title_height,
    );
    const has_error = task.errorSummary() != null;
    var row = dvui.box(@src(), .{ .dir = .vertical }, theme.panel(.{
        .expand = .horizontal,
        .min_size_content = .{ .w = width - popup_pad_x * 2 - 6, .h = row_height },
        .max_size_content = .height(row_height),
        .padding = .{ .x = 2, .y = 1, .w = 2, .h = 1 },
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 2 },
        .corner_radius = .all(2),
        .border = .all(1),
        .id_extra = id_extra,
    }, palette).override(.{
        .color_fill = if (has_error) palette.warning.opacity(0.16) else palette.panel_bg,
        .color_border = if (has_error) palette.warning.opacity(0.55) else palette.border,
    }));
    defer row.deinit();
    var action: ?RowAction = null;

    {
        var title_line = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .min_size_content = .height(title_height),
            .max_size_content = .height(title_height),
            .padding = .all(0),
            .id_extra = id_extra + 1,
        });
        defer title_line.deinit();

        const title = task.title;
        const title_font = theme.textFont(title, 9);
        var title_layout = dvui.textLayout(@src(), .{ .break_lines = true }, .{
            .font = title_font,
            .color_text = palette.text,
            .background = false,
            .expand = .horizontal,
            .min_size_content = .{ .w = 1, .h = title_height },
            .max_size_content = .height(title_height),
            .padding = .{ .x = 2, .y = 1, .w = 2, .h = 1 },
            .id_extra = id_extra + 2,
        });
        title_layout.addText(title, .{
            .font = title_font,
            .color_text = palette.text,
        });
        title_layout.deinit();

        var actions = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .min_size_content = .{ .w = taskActionsWidth(task), .h = title_height },
            .max_size_content = .{ .w = taskActionsWidth(task), .h = title_height },
            .gravity_x = 1,
            .gravity_y = 0,
            .padding = .all(0),
            .id_extra = id_extra + 10,
        });
        defer actions.deinit();

        if (task.status == .failed or task.status == .canceled) {
            if (actionIconButton(retry_icon_bytes, "refresh.png", palette, id_extra + 8)) {
                action = .{ .retry = task.id };
            }
        }
        if (actionIconButton(close_icon_bytes, "close.png", palette, id_extra + 3)) {
            action = .{ .cancel_or_dismiss = task.id };
        }
    }

    var progress_buf: [32]u8 = undefined;
    const clamped = @max(0, @min(task.progress, 1));
    const percent = std.fmt.bufPrint(&progress_buf, "{d:.0}%", .{clamped * 100}) catch "0%";
    var bytes_buf: [64]u8 = undefined;
    const bytes_text = bytesText(task, &bytes_buf);
    var speed_buf: [48]u8 = undefined;
    const speed_text = speedText(task, &speed_buf);
    var status_buf: [128]u8 = undefined;
    const status_text = std.fmt.bufPrint(&status_buf, "{s} {s}   {s}   {s}", .{
        if (task.status == transfer.TransferStatus.running) "" else task.status.label(),
        percent,
        bytes_text,
        speed_text,
    }) catch task.status.label();
    {
        var status_line = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .min_size_content = .height(task_status_height),
            .max_size_content = .height(task_status_height),
            .padding = .all(0),
            .id_extra = id_extra + 4,
        });
        defer status_line.deinit();

        dvui.label(@src(), "{s}", .{status_text}, .{
            .font = theme.textFont(status_text, 9),
            .color_text = palette.muted_text,
            .expand = .horizontal,
            .min_size_content = .height(task_status_height),
            .max_size_content = .height(task_status_height),
            .padding = .{ .x = 2, .y = 1, .w = 2, .h = 1 },
            .id_extra = id_extra + 5,
        });
    }

    if (task.errorSummary()) |error_summary| {
        const error_font = theme.textFont(error_summary, 9);
        const error_height = wrappedTextHeight(
            error_summary,
            error_font,
            taskContentWidth(width),
            task_error_height,
        );
        var error_layout = dvui.textLayout(@src(), .{ .break_lines = true }, .{
            .font = error_font,
            .color_text = palette.danger,
            .background = false,
            .expand = .horizontal,
            .min_size_content = .height(error_height),
            .max_size_content = .height(error_height),
            .padding = .{ .x = 2, .y = 1, .w = 2, .h = 1 },
            .id_extra = id_extra + 9,
        });
        defer error_layout.deinit();
        error_layout.addText(error_summary, .{
            .font = error_font,
            .color_text = palette.danger,
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
    return action;
}

fn bytesText(task: transfer.TransferTask, buf: []u8) []const u8 {
    var done_buf: [24]u8 = undefined;
    const done = byteSizeText(task.bytes_done, &done_buf);
    if (task.bytes_total) |total| {
        var total_buf: [24]u8 = undefined;
        const total_text = byteSizeText(total, &total_buf);
        return std.fmt.bufPrint(buf, "{s} / {s}", .{ done, total_text }) catch done;
    }
    if (task.bytes_done > 0) return done;
    return "-";
}

fn speedText(task: transfer.TransferTask, buf: []u8) []const u8 {
    if (task.status != .running or task.bytes_per_sec <= 0) return "";
    const bytes_per_sec: u64 = @intFromFloat(@max(0, task.bytes_per_sec));
    var speed_buf: [24]u8 = undefined;
    const speed = byteSizeText(bytes_per_sec, &speed_buf);
    return std.fmt.bufPrint(buf, "{s}/s", .{speed}) catch "";
}

fn byteSizeText(bytes: u64, buf: []u8) []const u8 {
    if (bytes < 1024) return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "-";
    if (bytes < 1024 * 1024) return std.fmt.bufPrint(buf, "{d:.1} KB", .{@as(f64, @floatFromInt(bytes)) / 1024.0}) catch "-";
    if (bytes < 1024 * 1024 * 1024) return std.fmt.bufPrint(buf, "{d:.1} MB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)}) catch "-";
    return std.fmt.bufPrint(buf, "{d:.1} GB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0)}) catch "-";
}

fn actionIconButton(bytes: []const u8, name: []const u8, palette: theme.Palette, id_extra: usize) bool {
    return theme.iconButton(@src(), bytes, name, .{
        .min_size_content = .{ .w = action_button_content_size, .h = action_button_content_size },
        .max_size_content = .{ .w = action_button_content_size, .h = action_button_content_size },
        .gravity_y = 0.5,
        .padding = .all(3),
        .margin = .{ .x = 1 },
        .corner_radius = .all(3),
        .id_extra = id_extra,
    }, palette, .{ .variant = .ghost }, .{
        .icon_size = action_icon_size,
        .id_extra = id_extra,
    }).clicked;
}

fn outsidePopupClick(menu_rect: dvui.Rect.Physical) bool {
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
