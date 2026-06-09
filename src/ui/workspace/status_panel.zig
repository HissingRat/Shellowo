const dvui = @import("dvui");
const std = @import("std");

const status_panel = @import("../../core/status_panel.zig");
const workspace = @import("../../core/workspace.zig");
const theme = @import("../theme.zig");

const section_font_size: f32 = 9;
const row_font_size: f32 = 9;
const metric_font_size: f32 = 9;
const table_header_font_size: f32 = 9;
const table_cell_font_size: f32 = 9;
const network_tooltip_font_size: f32 = 9;
const network_chart_height: f32 = 86;
const network_axis_width: f32 = 34;
const network_axis_font_size: f32 = 9;
const network_bar_gap: f32 = 0.5;
const network_min_bar_width: f32 = 1.5;
const network_target_bar_slot_width: f32 = 3;
const network_header_icon_gap: f32 = 4;
const network_header_group_gap: f32 = 14;
const network_header_y_offset: f32 = -3;
const network_tooltip_padding_x: f32 = 20;
const network_tooltip_padding_y: f32 = 8;
const network_tooltip_content_slack: f32 = 8;
const network_grid_color = dvui.Color{ .r = 0x97, .g = 0xa0, .b = 0xaa };

const NetworkHoverState = struct {
    frozen: bool = false,
    network: status_panel.NetworkMetric = .{},
};

pub const Options = struct {
    width: f32,
    id_extra: usize,
};

pub fn show(tab: workspace.WorkspaceTab, snapshot: status_panel.StatusPanelSnapshot, palette: theme.Palette, opts: Options) void {
    _ = tab;
    var panel = dvui.box(@src(), .{ .dir = .vertical }, theme.panel(.{
        .expand = .vertical,
        .min_size_content = .width(opts.width),
        .max_size_content = .width(opts.width),
        .padding = .{ .x = 10, .y = 10, .w = 10, .h = 10 },
        .id_extra = opts.id_extra,
    }, palette).override(.{
        .color_fill = palette.panel_bg,
        .color_border = palette.border_subtle,
    }));
    defer panel.deinit();

    summaryRows(snapshot.monitor, palette, opts.id_extra + 30);
    resourceBars(snapshot.monitor, palette, opts.id_extra + 60);
    processTable(snapshot.monitor, palette, opts.id_extra + 100);
    networkChart(snapshot.monitor, palette, opts.id_extra + 150);
    diskRows(snapshot.monitor, palette, opts.id_extra + 190);
}

fn summaryRows(monitor: status_panel.MonitorSnapshot, palette: theme.Palette, id_extra: usize) void {
    var uptime_buf: [32]u8 = undefined;
    infoRow("IP", if (monitor.ip_len > 0) monitor.ipText() else "--", palette, id_extra);
    infoRow("Uptime", uptimeText(&uptime_buf, monitor.uptime_seconds), palette, id_extra + 1);
    if (monitor.error_len > 0) infoRow("Monitor", monitor.errorText(), palette, id_extra + 2);
}

fn infoRow(label: []const u8, value: []const u8, palette: theme.Palette, id_extra: usize) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .height(20),
        .padding = .all(0),
        .id_extra = id_extra,
    });
    defer row.deinit();

    dvui.label(@src(), "{s}", .{label}, .{
        .font = theme.textFont(label, row_font_size),
        .color_text = palette.text_subtle,
        .gravity_y = 0.5,
        .id_extra = id_extra + 1000,
    });
    dvui.label(@src(), "{s}", .{value}, .{
        .font = theme.textFont(value, row_font_size),
        .color_text = palette.muted_text,
        .gravity_x = 1,
        .gravity_y = 0.5,
        .id_extra = id_extra + 2000,
    });
}

fn resourceBars(monitor: status_panel.MonitorSnapshot, palette: theme.Palette, id_extra: usize) void {
    var cpu_buf: [24]u8 = undefined;
    if (monitor.cpu) |cpu| {
        metricBar("CPU", percentText(&cpu_buf, cpu.percent), cpu.percent / 100, palette, id_extra);
    } else {
        metricBar("CPU", "--", 0, palette, id_extra);
    }

    var memory_buf: [56]u8 = undefined;
    if (monitor.memory) |memory| {
        metricBar("Memory", capacityText(&memory_buf, memory), memory.percent / 100, palette, id_extra + 1);
    } else {
        metricBar("Memory", "--", 0, palette, id_extra + 1);
    }

    var swap_buf: [56]u8 = undefined;
    if (monitor.swap) |swap| {
        metricBar("Swap", capacityText(&swap_buf, swap), swap.percent / 100, palette, id_extra + 2);
    } else {
        metricBar("Swap", "--", 0, palette, id_extra + 2);
    }
}

fn metricBar(label: []const u8, value: []const u8, percent: f32, palette: theme.Palette, id_extra: usize) void {
    dvui.label(@src(), "{s}  {s}", .{ label, value }, .{
        .font = theme.textFont(label, metric_font_size),
        .color_text = palette.muted_text,
        .margin = .{ .y = 5 },
        .id_extra = id_extra + 3000,
    });

    var track = dvui.box(@src(), .{}, .{
        .background = true,
        .color_fill = palette.surface_bg,
        .expand = .horizontal,
        .min_size_content = .height(4),
        .max_size_content = .height(4),
        .corner_radius = .all(2),
        .padding = .all(0),
        .id_extra = id_extra + 4000,
    });
    defer track.deinit();

    const fill_width = 150 * @max(0, @min(1, percent));
    var fill = dvui.box(@src(), .{}, .{
        .background = true,
        .color_fill = palette.accent,
        .min_size_content = .{ .w = fill_width, .h = 4 },
        .max_size_content = .{ .w = fill_width, .h = 4 },
        .corner_radius = .all(2),
        .padding = .all(0),
        .id_extra = id_extra + 5000,
    });
    defer fill.deinit();
}

fn processTable(monitor: status_panel.MonitorSnapshot, palette: theme.Palette, id_extra: usize) void {
    tableHeader(&.{ "MEM", "CPU", "CMD" }, palette, id_extra);
    if (monitor.process_count == 0) {
        processRow("--", "--", "--", palette, id_extra + 10);
        return;
    }
    for (monitor.processes[0..monitor.process_count], 0..) |process, idx| {
        var mem_buf: [24]u8 = undefined;
        var cpu_buf: [16]u8 = undefined;
        processRow(bytesText(&mem_buf, process.memory_bytes), percentText(&cpu_buf, process.cpu_percent), process.commandText(), palette, id_extra + 10 + idx * 10);
    }
}

fn tableHeader(columns: []const []const u8, palette: theme.Palette, id_extra: usize) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, theme.panel(.{
        .expand = .horizontal,
        .min_size_content = .height(22),
        .padding = .{ .x = 6, .y = 0, .w = 6, .h = 0 },
        .margin = .{ .y = 10 },
        .id_extra = id_extra,
    }, palette).override(.{ .color_fill = palette.surface_hover }));
    defer row.deinit();

    for (columns, 0..) |column, i| {
        dvui.label(@src(), "{s}", .{column}, .{
            .font = theme.textFont(column, table_header_font_size),
            .color_text = palette.text_subtle,
            .min_size_content = .width(if (i == columns.len - 1) 70 else 40),
            .gravity_y = 0.5,
            .id_extra = id_extra + 1 + i,
        });
    }
}

fn processRow(mem: []const u8, cpu: []const u8, cmd: []const u8, palette: theme.Palette, id_extra: usize) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .height(20),
        .padding = .all(0),
        .id_extra = id_extra,
    });
    defer row.deinit();

    cell(mem, 40, palette, id_extra + 1);
    cell(cpu, 40, palette, id_extra + 2);
    cell(cmd, 86, palette, id_extra + 3);
}

fn networkChart(monitor: status_panel.MonitorSnapshot, palette: theme.Palette, id_extra: usize) void {
    var chart = dvui.box(@src(), .{ .dir = .horizontal }, theme.panel(.{
        .expand = .horizontal,
        .min_size_content = .height(network_chart_height),
        .padding = .{ .x = 0, .y = 6, .w = 0, .h = 0 },
        .margin = .{ .y = 8 },
        .id_extra = id_extra + 1,
    }, palette).override(.{ .color_fill = dvui.Color.transparent, .color_border = dvui.Color.transparent }));
    defer chart.deinit();

    const content_rs = chart.data().contentRectScale();
    networkHeader(content_rs.r, monitor.network, palette);

    const live_network = monitor.network orelse return;
    const chart_rect = content_rs.r;
    const plot_rect = networkPlotRect(chart_rect, content_rs.s);
    const hovered = plot_rect.contains(dvui.currentWindow().mouse_pt);
    const hover_state = dvui.dataGetPtrDefault(null, chart.data().id, "network_hover", NetworkHoverState, .{});
    if (hovered) {
        if (!hover_state.frozen) {
            hover_state.network = live_network;
            hover_state.frozen = true;
        }
    } else {
        hover_state.frozen = false;
    }

    const network = if (hover_state.frozen) hover_state.network else live_network;
    const len = @min(network.history_len, status_panel.max_network_points);
    const slot_count = networkSlotCount(plot_rect.w);
    if (slot_count == 0 or len == 0) return;
    const max_value = networkScaleMax(network, len);
    drawNetworkGrid(chart_rect, plot_rect, max_value, palette, content_rs.s);

    const slot_width = plot_rect.w / @as(f32, @floatFromInt(slot_count));
    const gap = network_bar_gap * content_rs.s;
    const bar_width = @max(network_min_bar_width * content_rs.s, slot_width - gap * 2);
    const hover_slot = if (hovered) hoveredNetworkSlot(plot_rect, slot_count) else null;
    for (0..slot_count) |idx| {
        const source_index = visibleNetworkSourceIndex(len, idx, slot_count) orelse continue;
        const tx_height = networkBarHeight(network.tx_history[source_index], max_value, plot_rect.h);
        const rx_height = networkBarHeight(network.rx_history[source_index], max_value, plot_rect.h);
        const x = plot_rect.x + @as(f32, @floatFromInt(idx)) * slot_width + gap;
        drawNetworkBar(plot_rect, x, bar_width, tx_height, networkTxColor(palette), hover_slot != null and hover_slot.? == idx);
        drawNetworkBar(plot_rect, x, bar_width, rx_height, networkRxColor(palette), hover_slot != null and hover_slot.? == idx);
    }

    if (hover_slot) |slot| {
        const source_index = visibleNetworkSourceIndex(len, slot, slot_count) orelse return;
        const x = plot_rect.x + (@as(f32, @floatFromInt(slot)) + 0.5) * slot_width;
        const points = [_]dvui.Point.Physical{
            .{ .x = x, .y = plot_rect.y },
            .{ .x = x, .y = plot_rect.y + plot_rect.h },
        };
        dvui.Path.stroke(.{ .points = &points }, .{
            .thickness = content_rs.s,
            .color = palette.text_subtle,
        });
        networkTooltip(plot_rect, network, source_index, palette);
    }
}

fn diskRows(monitor: status_panel.MonitorSnapshot, palette: theme.Palette, id_extra: usize) void {
    tableHeader(&.{ "Path", "Free / Size" }, palette, id_extra);
    if (monitor.disk_count == 0) {
        diskRow("--", "--", palette, id_extra + 10);
        return;
    }
    for (monitor.disks[0..monitor.disk_count], 0..) |disk, idx| {
        var text_buf: [48]u8 = undefined;
        diskRow(disk.pathText(), diskText(&text_buf, disk), palette, id_extra + 10 + idx * 10);
    }
}

fn diskRow(path: []const u8, value: []const u8, palette: theme.Palette, id_extra: usize) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .height(20),
        .padding = .all(0),
        .id_extra = id_extra,
    });
    defer row.deinit();

    cell(path, 70, palette, id_extra + 1);
    cell(value, 96, palette, id_extra + 2);
}

fn cell(value: []const u8, width: f32, palette: theme.Palette, id_extra: usize) void {
    dvui.label(@src(), "{s}", .{value}, .{
        .font = theme.textFont(value, table_cell_font_size),
        .color_text = palette.muted_text,
        .min_size_content = .width(width),
        .gravity_y = 0.5,
        .id_extra = id_extra,
    });
}

fn percentText(buffer: []u8, percent: f32) []const u8 {
    return std.fmt.bufPrint(buffer, "{d:.1}%", .{percent}) catch "--";
}

fn capacityText(buffer: []u8, metric: status_panel.CapacityMetric) []const u8 {
    var used_buf: [16]u8 = undefined;
    var total_buf: [16]u8 = undefined;
    return std.fmt.bufPrint(buffer, "{s}/{s}  {d:.0}%", .{
        bytesText(&used_buf, metric.used_bytes),
        bytesText(&total_buf, metric.total_bytes),
        metric.percent,
    }) catch "--";
}

fn diskText(buffer: []u8, disk: status_panel.DiskMetric) []const u8 {
    var free_buf: [16]u8 = undefined;
    var total_buf: [16]u8 = undefined;
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{
        bytesText(&free_buf, disk.free_bytes),
        bytesText(&total_buf, disk.total_bytes),
    }) catch "--";
}

fn bytesText(buffer: []u8, bytes: u64) []const u8 {
    const value: f64 = @floatFromInt(bytes);
    if (bytes >= 1024 * 1024 * 1024) {
        return std.fmt.bufPrint(buffer, "{d:.1}G", .{value / (1024.0 * 1024.0 * 1024.0)}) catch "--";
    }
    if (bytes >= 1024 * 1024) {
        return std.fmt.bufPrint(buffer, "{d:.1}M", .{value / (1024.0 * 1024.0)}) catch "--";
    }
    if (bytes >= 1024) {
        return std.fmt.bufPrint(buffer, "{d:.1}K", .{value / 1024.0}) catch "--";
    }
    return std.fmt.bufPrint(buffer, "{d}B", .{bytes}) catch "--";
}

fn networkText(buffer: []u8, network: status_panel.NetworkMetric) []const u8 {
    var up_buf: [16]u8 = undefined;
    var down_buf: [16]u8 = undefined;
    return std.fmt.bufPrint(buffer, "↑ {s}/s   ↓ {s}/s", .{
        bytesText(&up_buf, network.tx_bytes_per_sec),
        bytesText(&down_buf, network.rx_bytes_per_sec),
    }) catch "↑ --   ↓ --";
}

fn networkHeader(chart_rect: dvui.Rect.Physical, maybe_network: ?status_panel.NetworkMetric, palette: theme.Palette) void {
    var tx_buf: [16]u8 = undefined;
    var rx_buf: [16]u8 = undefined;
    const tx_text = if (maybe_network) |network| bytesText(&tx_buf, network.tx_bytes_per_sec) else "--";
    const rx_text = if (maybe_network) |network| bytesText(&rx_buf, network.rx_bytes_per_sec) else "--";
    const font = theme.textFont("Network", metric_font_size + 1);
    const y = chart_rect.y + network_header_y_offset;
    const value_gap = network_header_icon_gap + 10;
    const tx_icon_width = font.textSize("↑").w;
    const rx_icon_width = font.textSize("↓").w;
    const tx_group_width = tx_icon_width + value_gap + font.textSize(tx_text).w;
    const left_x = chart_rect.x + chart_rect.w / 8;
    const min_right_x = left_x + tx_group_width + network_header_group_gap;
    const right_x = @max(min_right_x, chart_rect.x + chart_rect.w / 2 + chart_rect.w / 8);
    _ = renderNetworkHeaderPart("↑", left_x, y, font, networkTxTextColor(palette));
    _ = renderNetworkHeaderPart(tx_text, left_x + tx_icon_width + value_gap, y, font, networkTxTextColor(palette));
    _ = renderNetworkHeaderPart("↓", right_x, y, font, networkRxTextColor(palette));
    _ = renderNetworkHeaderPart(rx_text, right_x + rx_icon_width + value_gap, y, font, networkRxTextColor(palette));
}

fn networkTxColor(palette: theme.Palette) dvui.Color {
    return palette.accent;
}

fn networkRxColor(palette: theme.Palette) dvui.Color {
    return blendColor(palette.accent, palette.text_subtle, 0.45);
}

fn networkTxTextColor(palette: theme.Palette) dvui.Color {
    return palette.accent;
}

fn networkRxTextColor(palette: theme.Palette) dvui.Color {
    return blendColor(palette.accent, palette.muted_text, 0.45);
}

fn blendColor(a: dvui.Color, b: dvui.Color, amount_b: f32) dvui.Color {
    const t = @max(0, @min(1, amount_b));
    const inv = 1 - t;
    return .{
        .r = @intFromFloat(@as(f32, @floatFromInt(a.r)) * inv + @as(f32, @floatFromInt(b.r)) * t),
        .g = @intFromFloat(@as(f32, @floatFromInt(a.g)) * inv + @as(f32, @floatFromInt(b.g)) * t),
        .b = @intFromFloat(@as(f32, @floatFromInt(a.b)) * inv + @as(f32, @floatFromInt(b.b)) * t),
        .a = @intFromFloat(@as(f32, @floatFromInt(a.a)) * inv + @as(f32, @floatFromInt(b.a)) * t),
    };
}

fn renderNetworkHeaderPart(text: []const u8, x: f32, y: f32, font: dvui.Font, color: dvui.Color) f32 {
    const size = font.textSize(text);
    const rs = dvui.RectScale{
        .r = .{ .x = x, .y = y, .w = size.w, .h = size.h },
        .s = dvui.currentWindow().natural_scale,
    };
    dvui.renderText(.{
        .font = font,
        .text = text,
        .rs = rs,
        .p = .{ .x = x, .y = y },
        .color = color,
    }) catch {};
    return x + size.w;
}

fn networkPlotRect(chart_rect: dvui.Rect.Physical, scale: f32) dvui.Rect.Physical {
    const header_height = 20 * scale;
    const axis_width = network_axis_width * scale;
    return .{
        .x = chart_rect.x + axis_width,
        .y = chart_rect.y + header_height,
        .w = @max(1, chart_rect.w - axis_width),
        .h = @max(4, chart_rect.h - header_height - 2 * scale),
    };
}

fn drawNetworkGrid(chart_rect: dvui.Rect.Physical, plot_rect: dvui.Rect.Physical, max_value: u64, palette: theme.Palette, scale: f32) void {
    const tick_values = [_]u64{
        max_value,
        (max_value * 2) / 3,
        max_value / 3,
    };
    const tick_fracs = [_]f32{ 0, 1.0 / 3.0, 2.0 / 3.0 };
    const font = theme.textFont("43K", network_axis_font_size);

    for (tick_values, 0..) |tick, idx| {
        const y = plot_rect.y + plot_rect.h * tick_fracs[idx];
        var label_buf: [16]u8 = undefined;
        const label = bytesText(&label_buf, tick);
        const label_size = font.textSize(label);
        const label_rs = dvui.RectScale{
            .r = .{ .x = chart_rect.x, .y = y - label_size.h / 2 + 5, .w = network_axis_width * scale, .h = label_size.h },
            .s = scale,
        };
        dvui.renderText(.{
            .font = font,
            .text = label,
            .rs = label_rs,
            .p = .{ .x = chart_rect.x, .y = y - label_size.h / 2 },
            .color = palette.muted_text,
        }) catch {};
        drawDashedLine(plot_rect.x, y, plot_rect.x + plot_rect.w, network_grid_color.opacity(0.65), scale);
    }

    const baseline = dvui.Rect.Physical{
        .x = chart_rect.x,
        .y = plot_rect.y + plot_rect.h,
        .w = chart_rect.w,
        .h = @max(1, scale),
    };
    baseline.fill(.all(0), .{ .color = palette.accent.opacity(0.55), .fade = 0 });
}

fn drawDashedLine(x0: f32, y: f32, x1: f32, color: dvui.Color, scale: f32) void {
    const dash_w = 2.0 * scale;
    const gap_w = 6.0 * scale;
    var x = x0;
    while (x < x1) : (x += dash_w + gap_w) {
        const rect = dvui.Rect.Physical{
            .x = x,
            .y = y,
            .w = @min(dash_w, x1 - x),
            .h = @max(1, scale),
        };
        rect.fill(.all(0), .{ .color = color, .fade = 0 });
    }
}

fn networkScaleMax(network: status_panel.NetworkMetric, len: usize) u64 {
    var max_value = @max(network.rx_bytes_per_sec, network.tx_bytes_per_sec);
    for (network.rx_history[0..len]) |value| max_value = @max(max_value, value);
    for (network.tx_history[0..len]) |value| max_value = @max(max_value, value);
    return niceNetworkScale(@max(max_value, 1));
}

fn niceNetworkScale(value: u64) u64 {
    const units = [_]u64{ 1, 1024, 1024 * 1024, 1024 * 1024 * 1024 };
    const steps = [_]u64{ 15, 30, 45, 60, 90, 120 };
    for (units) |unit| {
        for (steps) |step| {
            const candidate = step * unit;
            if (candidate >= value) return candidate;
        }
    }
    return value;
}

fn networkBarHeight(value: u64, max_value: u64, plot_height: f32) f32 {
    if (max_value == 0 or value == 0) return 0;
    const ratio = @as(f32, @floatFromInt(value)) / @as(f32, @floatFromInt(max_value));
    return @max(1, plot_height * @min(1, ratio));
}

fn drawNetworkBar(plot_rect: dvui.Rect.Physical, x: f32, width: f32, height: f32, color: dvui.Color, hovered: bool) void {
    if (height <= 0) return;
    const rect = dvui.Rect.Physical{
        .x = x,
        .y = plot_rect.y + plot_rect.h - height,
        .w = width,
        .h = height,
    };
    rect.fill(.all(0), .{ .color = color.opacity(if (hovered) 1.0 else 0.82), .fade = 0 });
}

fn uptimeText(buffer: []u8, maybe_seconds: ?u64) []const u8 {
    const seconds = maybe_seconds orelse return "--";
    const days = seconds / 86400;
    const hours = (seconds % 86400) / 3600;
    const minutes = (seconds % 3600) / 60;
    if (days > 0) return std.fmt.bufPrint(buffer, "{d}d {d}h", .{ days, hours }) catch "--";
    if (hours > 0) return std.fmt.bufPrint(buffer, "{d}h {d}m", .{ hours, minutes }) catch "--";
    return std.fmt.bufPrint(buffer, "{d}m", .{minutes}) catch "--";
}

fn networkSlotCount(chart_width: f32) usize {
    const slot_count: usize = @intFromFloat(@max(1, @floor(chart_width / network_target_bar_slot_width)));
    return @min(status_panel.max_network_points, slot_count);
}

fn sampledHistoryValue(history: []const f32, slot_index: usize, slot_count: usize) f32 {
    if (history.len == 0 or slot_count == 0) return 0;
    return history[sampledHistoryIndex(history.len, slot_index, slot_count)];
}

fn sampledHistoryIndex(history_len: usize, slot_index: usize, slot_count: usize) usize {
    if (history_len == 0 or slot_count == 0) return 0;
    const numerator = slot_index * history_len;
    return @min(history_len - 1, numerator / slot_count);
}

fn visibleNetworkSourceIndex(history_len: usize, slot_index: usize, slot_count: usize) ?usize {
    if (history_len == 0 or slot_count == 0) return null;
    if (history_len <= slot_count) {
        const empty_slots = slot_count - history_len;
        if (slot_index < empty_slots) return null;
        return slot_index - empty_slots;
    }
    return history_len - slot_count + slot_index;
}

fn maxHistory(history: []const f32) f32 {
    var max_value: f32 = 0;
    for (history) |value| max_value = @max(max_value, value);
    return max_value;
}

fn hoveredNetworkSlot(chart_rect: dvui.Rect.Physical, slot_count: usize) ?usize {
    if (slot_count == 0 or chart_rect.w <= 0) return null;
    const mouse = dvui.currentWindow().mouse_pt;
    if (!chart_rect.contains(mouse)) return null;
    const slot_width = chart_rect.w / @as(f32, @floatFromInt(slot_count));
    if (slot_width <= 0) return null;
    const rel_x = @max(0, mouse.x - chart_rect.x);
    const slot: usize = @intFromFloat(@floor(rel_x / slot_width));
    return @min(slot_count - 1, slot);
}

fn networkTooltip(active_rect: dvui.Rect.Physical, network: status_panel.NetworkMetric, source_index: usize, palette: theme.Palette) void {
    var text_buf: [96]u8 = undefined;
    const text = networkTooltipText(&text_buf, network, source_index);
    const font = theme.textFont(text, network_tooltip_font_size);
    const tooltip_rect = networkTooltipRect(text, font);

    var tooltip: dvui.FloatingTooltipWidget = undefined;
    tooltip.init(@src(), .{
        .active_rect = active_rect,
        .interactive = false,
        .position = .absolute,
    }, theme.panel(.{
        .rect = dvui.Rect.cast(tooltip_rect),
        .background = false,
        .role = .tooltip,
        .padding = .{ .x = 2, .y = 1, .w = 2, .h = 1 },
    }, palette).override(.{
        .color_border = palette.border,
    }));
    defer tooltip.deinit();

    if (tooltip.shown()) {
        const text_size = multilineTextSize(text, font);
        var layout = dvui.textLayout(@src(), .{ .break_lines = false }, .{
            .font = font,
            .color_text = palette.text,
            .padding = .all(0),
            .background = false,
            .min_size_content = .{
                .w = text_size.w + network_tooltip_content_slack,
                .h = text_size.h,
            },
        });
        defer layout.deinit();
        layout.addText(text, .{
            .font = font,
            .color_text = palette.text,
        });
    }
}

fn networkTooltipRect(text: []const u8, font: dvui.Font) dvui.Rect.Natural {
    const mouse = dvui.currentWindow().mouse_pt.toNatural();
    const text_size = multilineTextSize(text, font);
    const offset_x: f32 = 10;
    const offset_y: f32 = 10;
    const start = dvui.Rect.Natural{
        .x = mouse.x + offset_x,
        .y = mouse.y + offset_y,
        .w = text_size.w + network_tooltip_padding_x + network_tooltip_content_slack,
        .h = text_size.h + network_tooltip_padding_y,
    };
    return dvui.placeOnScreen(dvui.windowRect(), .{}, .none, start);
}

fn multilineTextSize(text: []const u8, font: dvui.Font) dvui.Size {
    if (text.len == 0) return font.textSize("");

    var size = dvui.Size{};
    var line_count: usize = 0;
    var iter = std.mem.splitScalar(u8, text, '\n');
    while (iter.next()) |line| {
        const line_size = font.textSize(line);
        size.w = @max(size.w, line_size.w);
        size.h += line_size.h;
        line_count += 1;
    }

    if (line_count > 1) {
        const line_gap = @max(0, font.textHeight() * 0.12);
        size.h += line_gap * @as(f32, @floatFromInt(line_count - 1));
    }
    return size;
}

fn networkTooltipText(buffer: []u8, network: status_panel.NetworkMetric, source_index: usize) []const u8 {
    const index = @min(source_index, status_panel.max_network_points - 1);
    var up_buf: [16]u8 = undefined;
    var down_buf: [16]u8 = undefined;
    var time_buf: [20]u8 = undefined;
    return std.fmt.bufPrint(buffer, "{s}\n↑ {s}/s\n↓ {s}/s", .{
        sampleTimeText(&time_buf, network, index),
        bytesText(&up_buf, network.tx_history[index]),
        bytesText(&down_buf, network.rx_history[index]),
    }) catch "--:--:--\n↑ --\n↓ --";
}

fn sampleTimeText(buffer: []u8, network: status_panel.NetworkMetric, source_index: usize) []const u8 {
    const len = @min(network.history_len, status_panel.max_network_points);
    if (len == 0 or source_index >= len) return "--";
    const age_samples = len - 1 - source_index;
    const age_ms = age_samples * network.sample_ms;
    const unix_ms = network.sample_unix_ms -| age_ms;
    const day_seconds = (unix_ms / std.time.ms_per_s) % std.time.s_per_day;
    return std.fmt.bufPrint(buffer, "{d:0>2}:{d:0>2}:{d:0>2}", .{
        day_seconds / std.time.s_per_hour,
        (day_seconds % std.time.s_per_hour) / std.time.s_per_min,
        day_seconds % std.time.s_per_min,
    }) catch "--";
}
