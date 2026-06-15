const std = @import("std");
const dvui = @import("dvui");

const App = @import("../../../app/App.zig");
const transfer = @import("../../../core/transfer.zig");
const theme = @import("../../theme.zig");

const close_icon_bytes = @embedFile("shellowo-close-icon");
const retry_icon_bytes = @embedFile("shellowo-refresh-icon");

const toolbar_height: f32 = 31;
const popup_max_height: f32 = 200;
const popup_min_width: f32 = 280;
const popup_max_width: f32 = 760;
const popup_pad_x: f32 = 2;
const popup_pad_y: f32 = 1;
const task_row_height: f32 = 68;
const close_button_size: f32 = 14;

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
    }, theme.panel(.{
        .id_extra = id_extra,
        .padding = .{ .x = popup_pad_x, .y = popup_pad_y, .w = popup_pad_x, .h = popup_pad_y },
        .corner_radius = .all(3),
        .min_size_content = .{ .w = width, .h = 58 },
        .max_size_content = .{ .w = width, .h = popup_max_height },
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
        .min_size_content = .{ .w = width - popup_pad_x * 2, .h = @min(popup_max_height - 28, popupContentHeight(tasks.len)) },
        .max_size_content = .{ .w = width - popup_pad_x * 2, .h = popup_max_height - 28 },
        .padding = .all(0),
        .background = true,
        .color_fill = palette.panel_bg,
        .color_border = palette.border_subtle,
        .id_extra = id_extra + 2,
    });
    defer scroll.deinit();

    if (tasks.len == 0) {
        emptyRow(palette, id_extra + 3);
    } else {
        for (tasks, 0..) |task, idx| {
            if (taskRow(task, width, palette, id_extra + 10 + idx * 10)) |action| {
                switch (action) {
                    .cancel_or_dismiss => |transfer_id| if (task.status == .pending or task.status == .running) {
                        app.cancelTransfer(transfer_id);
                    } else {
                        app.dismissTransfer(transfer_id);
                    },
                    .retry => |transfer_id| app.retryTransfer(transfer_id),
                }
            }
        }
    }

    if (outsidePopupClick(win.data().rectScale().r)) {
        state.popup_open = false;
        win.close();
    }
}

fn popupRect(anchor: dvui.Rect.Natural, tasks: []const transfer.TransferTask) dvui.Rect {
    const width = popupWidth(tasks);
    const height = @min(popup_max_height, popupContentHeight(tasks.len) + 28 + popup_pad_y * 2);
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
        const estimated = @as(f32, @floatFromInt(task.title.len)) * 7.2;
        const title_width = @max(measured, estimated) + 132;
        width = @max(width, title_width);
    }
    return @min(width, popup_max_width);
}

fn popupContentHeight(task_count: usize) f32 {
    if (task_count == 0) return 28;
    return @as(f32, @floatFromInt(task_count)) * task_row_height;
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
    var row = dvui.box(@src(), .{ .dir = .vertical }, theme.panel(.{
        .expand = .horizontal,
        .min_size_content = .{ .w = width - popup_pad_x * 2 - 6, .h = task_row_height },
        .max_size_content = .height(task_row_height),
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
    var action: ?RowAction = null;

    {
        var title_line = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .min_size_content = .height(24),
            .max_size_content = .height(24),
            .padding = .all(0),
            .id_extra = id_extra + 1,
        });
        defer title_line.deinit();

        // var title_buf: [96]u8 = undefined;
        // const title = if (task.attempt > 1)
        //     std.fmt.bufPrint(&title_buf, "{s}  attempt {d}", .{ task.title, task.attempt }) catch task.title
        // else
        //     task.title;
        const title = task.title;
        dvui.label(@src(), "{s}", .{title}, .{
            .font = theme.textFont(title, 9),
            .color_text = palette.text,
            .expand = .horizontal,
            .min_size_content = .height(24),
            .max_size_content = .height(24),
            .padding = .{ .x = 2, .y = 1, .w = 2, .h = 1 },
            .id_extra = id_extra + 2,
        });

        if (task.status == .failed or task.status == .canceled) {
            if (retryButton(palette, id_extra + 8)) {
                action = .{ .retry = task.id };
            }
        }
        if (closeButton(palette, id_extra + 3)) {
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
    const status_text = std.fmt.bufPrint(&status_buf, "{s} {s}   {s}   {s}", .{ task.status.label(), percent, bytes_text, speed_text }) catch task.status.label();
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
    return action;
}

fn retryButton(palette: theme.Palette, id_extra: usize) bool {
    var bw: dvui.ButtonWidget = undefined;
    const options = theme.buttonOptions(.{
        .min_size_content = .{ .w = close_button_size, .h = close_button_size },
        .max_size_content = .{ .w = close_button_size, .h = close_button_size },
        .padding = .{ .x = 2, .y = 1, .w = 2, .h = 1 },
        .corner_radius = .all(2),
        .id_extra = id_extra,
    }, palette, .{ .variant = .ghost, .font_size = 9 });

    bw.init(@src(), .{ .draw_focus = false }, options);
    bw.processEvents();
    bw.drawBackground();

    const color = bw.style().color(.text);
    renderThemedPng(retry_icon_bytes, "refresh.png", bw.data().contentRectScale(), color);

    const clicked = bw.clicked();
    bw.drawFocus();
    bw.deinit();
    return clicked;
}

fn bytesText(task: transfer.TransferTask, buf: []u8) []const u8 {
    var done_buf: [24]u8 = undefined;
    const done = byteSizeText(task.bytes_done, &done_buf);
    if (task.bytes_total) |total| {
        var total_buf: [24]u8 = undefined;
        const total_text = byteSizeText(total, &total_buf);
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ done, total_text }) catch done;
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

fn closeButton(palette: theme.Palette, id_extra: usize) bool {
    var bw: dvui.ButtonWidget = undefined;
    const options = theme.buttonOptions(.{
        .min_size_content = .{ .w = close_button_size, .h = close_button_size },
        .max_size_content = .{ .w = close_button_size, .h = close_button_size },
        .padding = .{ .x = 2, .y = 1, .w = 2, .h = 1 },
        .corner_radius = .all(2),
        .id_extra = id_extra,
    }, palette, .{ .variant = .ghost, .font_size = 9 });

    bw.init(@src(), .{ .draw_focus = false }, options);
    bw.processEvents();
    bw.drawBackground();

    const color = bw.style().color(.text);
    renderThemedPng(close_icon_bytes, "close.png", bw.data().contentRectScale(), color);

    const clicked = bw.clicked();
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
