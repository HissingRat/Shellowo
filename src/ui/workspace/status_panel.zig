const dvui = @import("dvui");

const workspace = @import("../../core/workspace.zig");
const theme = @import("../theme.zig");

pub const Options = struct {
    width: f32,
    id_extra: usize,
};

pub fn show(tab: workspace.WorkspaceTab, palette: theme.Palette, opts: Options) void {
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

    // title(tab, palette, opts.id_extra + 10);
    sectionButton("System", palette, opts.id_extra + 20);
    summaryRows(tab, palette, opts.id_extra + 30);
    resourceBars(palette, opts.id_extra + 60);
    processTable(palette, opts.id_extra + 100);
    networkChart(palette, opts.id_extra + 150);
    diskRows(palette, opts.id_extra + 190);
}

fn title(tab: workspace.WorkspaceTab, palette: theme.Palette, id_extra: usize) void {
    dvui.label(@src(), "{s}", .{tab.title}, .{
        .font = theme.textFont(tab.title, 13),
        .color_text = palette.text,
        .margin = .{ .h = 4 },
        .id_extra = id_extra,
    });

    dvui.label(@src(), "{s} / {s}", .{ tab.layout.label(), tab.status.label() }, .{
        .font = theme.textFont(tab.status.label(), 10),
        .color_text = palette.text_subtle,
        .margin = .{ .h = 12 },
        .id_extra = id_extra + 1,
    });
}

fn sectionButton(label: []const u8, palette: theme.Palette, id_extra: usize) void {
    var box = dvui.box(@src(), .{}, theme.panel(.{
        .min_size_content = .{ .w = 1, .h = 24 },
        .max_size_content = .height(24),
        .expand = .horizontal,
        .corner_radius = .all(4),
        .padding = .{ .x = 8, .y = 0, .w = 8, .h = 0 },
        .margin = .{ .h = 8 },
        .id_extra = id_extra,
    }, palette).override(.{
        .color_fill = palette.surface_hover,
        .color_border = palette.border_subtle,
    }));
    defer box.deinit();

    dvui.label(@src(), "{s}", .{label}, .{
        .font = theme.textFont(label, 10),
        .color_text = palette.text,
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .id_extra = id_extra + 1,
    });
}

fn summaryRows(tab: workspace.WorkspaceTab, palette: theme.Palette, id_extra: usize) void {
    infoRow("IP", "10.246.32.203", palette, id_extra);
    infoRow("Access", if (tab.session_type == .ssh) "SSH mock" else "FTP mock", palette, id_extra + 1);
    infoRow("Uptime", "10 days", palette, id_extra + 2);
    infoRow("Load", "0.36, 0.25, 0.24", palette, id_extra + 3);
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
        .font = theme.textFont(label, 10),
        .color_text = palette.text_subtle,
        .gravity_y = 0.5,
        .id_extra = id_extra + 1000,
    });
    dvui.label(@src(), "{s}", .{value}, .{
        .font = theme.textFont(value, 10),
        .color_text = palette.muted_text,
        .gravity_x = 1,
        .gravity_y = 0.5,
        .id_extra = id_extra + 2000,
    });
}

fn resourceBars(palette: theme.Palette, id_extra: usize) void {
    metricBar("CPU", "8%", 0.08, palette, id_extra);
    metricBar("Memory", "3.3G/15.6G  20%", 0.20, palette, id_extra + 1);
    metricBar("Swap", "4.0G/15.2G  26%", 0.26, palette, id_extra + 2);
}

fn metricBar(label: []const u8, value: []const u8, percent: f32, palette: theme.Palette, id_extra: usize) void {
    dvui.label(@src(), "{s}  {s}", .{ label, value }, .{
        .font = theme.textFont(label, 10),
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

    var fill = dvui.box(@src(), .{}, .{
        .background = true,
        .color_fill = palette.accent,
        .min_size_content = .{ .w = 150 * percent, .h = 4 },
        .max_size_content = .{ .w = 150 * percent, .h = 4 },
        .corner_radius = .all(2),
        .padding = .all(0),
        .id_extra = id_extra + 5000,
    });
    defer fill.deinit();
}

fn processTable(palette: theme.Palette, id_extra: usize) void {
    tableHeader(&.{ "MEM", "CPU", "CMD" }, palette, id_extra);
    processRow("39.3M", "19.0", "packagekitd", palette, id_extra + 10);
    processRow("8.6M", "9.5", "avahi-daemon", palette, id_extra + 20);
    processRow("58.3M", "1.6", "sshd-session", palette, id_extra + 30);
    processRow("64.3M", "1.2", "aTrustAgent", palette, id_extra + 40);
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
            .font = theme.textFont(column, 9),
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

fn networkChart(palette: theme.Palette, id_extra: usize) void {
    dvui.label(@src(), "Network  ↑ 0B/s   ↓ 725K", .{}, .{
        .font = theme.textFont("Network", 10),
        .color_text = palette.muted_text,
        .margin = .{ .y = 8 },
        .id_extra = id_extra,
    });

    var chart = dvui.box(@src(), .{}, theme.panel(.{
        .expand = .horizontal,
        .min_size_content = .height(48),
        .padding = .all(0),
        .id_extra = id_extra + 1,
    }, palette).override(.{ .color_fill = palette.surface_bg }));
    defer chart.deinit();
}

fn diskRows(palette: theme.Palette, id_extra: usize) void {
    tableHeader(&.{ "Path", "Free / Size" }, palette, id_extra);
    processRow("/dev", "7.8G", "7.8G", palette, id_extra + 10);
    processRow("/run", "1.6G", "1.6G", palette, id_extra + 20);
    processRow("/", "242G", "280G", palette, id_extra + 30);
}

fn cell(value: []const u8, width: f32, palette: theme.Palette, id_extra: usize) void {
    dvui.label(@src(), "{s}", .{value}, .{
        .font = theme.textFont(value, 9),
        .color_text = palette.muted_text,
        .min_size_content = .width(width),
        .gravity_y = 0.5,
        .id_extra = id_extra,
    });
}
