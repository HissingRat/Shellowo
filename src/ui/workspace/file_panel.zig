const dvui = @import("dvui");

const workspace = @import("../../core/workspace.zig");
const resize = @import("resize.zig");
const theme = @import("../theme.zig");

pub const Options = struct {
    height: ?f32,
    local_width: *f32,
    id_extra: usize,
};

const min_local_width: f32 = 160;
const max_local_width: f32 = 380;
const toolbar_height: f32 = 25;
const row_height: f32 = 24;

pub fn show(tab: workspace.WorkspaceTab, palette: theme.Palette, opts: Options) void {
    var root = dvui.box(@src(), .{ .dir = .vertical }, theme.panel(panelOptions(opts), palette).override(.{
        .color_fill = palette.panel_bg,
        .color_border = palette.border_subtle,
    }));
    defer root.deinit();

    toolbar(tab, palette, opts.id_extra + 10);

    var split = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .padding = .all(0),
        .id_extra = opts.id_extra + 20,
    });
    defer split.deinit();

    filePane(.local, palette, .{
        .width = opts.local_width.*,
        .id_extra = opts.id_extra + 30,
    });
    resize.handle(palette, .{
        .axis = .vertical,
        .value = opts.local_width,
        .min = min_local_width,
        .max = max_local_width,
        .id_extra = opts.id_extra + 40,
    });
    filePane(.remote, palette, .{
        .width = null,
        .id_extra = opts.id_extra + 50,
    });
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

fn toolbar(tab: workspace.WorkspaceTab, palette: theme.Palette, id_extra: usize) void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, theme.panel(.{
        .expand = .horizontal,
        .min_size_content = .height(toolbar_height),
        .max_size_content = .height(toolbar_height),
        .padding = .{ .x = 12, .y = 0, .w = 12, .h = 0 },
        .id_extra = id_extra,
    }, palette).override(.{ .color_fill = palette.topbar_bg }));
    defer bar.deinit();

    dvui.label(@src(), "Files", .{}, .{
        .font = theme.textFont("Files", 10),
        .color_text = palette.text,
        .gravity_y = 0.5,
        .id_extra = id_extra + 1,
    });
    dvui.label(@src(), "{s}  /", .{if (tab.layout == .terminal_file) "remote host" else "file workspace"}, .{
        .font = theme.textFont("remote host", 10),
        .color_text = palette.muted_text,
        .gravity_x = 1,
        .gravity_y = 0.5,
        .id_extra = id_extra + 2,
    });
}

const PaneKind = enum { local, remote };
const PaneOptions = struct {
    width: ?f32,
    id_extra: usize,
};

fn filePane(kind: PaneKind, palette: theme.Palette, opts: PaneOptions) void {
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

    paneHeader(kind, palette, opts.id_extra + 1);
    tableHeader(kind, palette, opts.id_extra + 10);
    fileRows(kind, palette, opts.id_extra + 30);
}

fn paneHeader(kind: PaneKind, palette: theme.Palette, id_extra: usize) void {
    const title = if (kind == .local) "Local  /Users/stoffel" else "Remote  /";
    var head = dvui.box(@src(), .{}, theme.panel(.{
        .expand = .horizontal,
        .min_size_content = .height(toolbar_height),
        .max_size_content = .height(toolbar_height),
        .padding = .{ .x = 10, .y = 0, .w = 10, .h = 0 },
        .id_extra = id_extra,
    }, palette).override(.{ .color_fill = palette.surface_bg }));
    defer head.deinit();

    dvui.label(@src(), "{s}", .{title}, .{
        .font = theme.textFont(title, 10),
        .color_text = palette.muted_text,
        .gravity_y = 0.5,
        .id_extra = id_extra + 1,
    });
}

fn tableHeader(kind: PaneKind, palette: theme.Palette, id_extra: usize) void {
    _ = kind;
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .height(row_height),
        .max_size_content = .height(row_height),
        .padding = .all(0),
        .id_extra = id_extra,
    });
    defer row.deinit();

    headerCell("Name", 160, palette, id_extra + 1);
    headerCell("Size", 70, palette, id_extra + 2);
    headerCell("Type", 90, palette, id_extra + 3);
    headerCell("Modified", 130, palette, id_extra + 4);
    headerCell("Perm", 100, palette, id_extra + 5);
}

fn fileRows(kind: PaneKind, palette: theme.Palette, id_extra: usize) void {
    if (kind == .local) {
        fileRow("..", "-", "folder", "2026-06-07", "drwx", palette, id_extra);
        fileRow(".agents", "-", "folder", "2026-06-06", "drwx", palette, id_extra + 10);
        fileRow(".android", "-", "folder", "2026-06-04", "drwx", palette, id_extra + 20);
        fileRow("README.md", "8K", "file", "2026-06-06", "-rw-", palette, id_extra + 30);
    } else {
        fileRow("boot", "-", "folder", "2026-05-25", "drwxr-xr-x", palette, id_extra);
        fileRow("dev", "-", "folder", "2026-05-25", "drwxr-xr-x", palette, id_extra + 10);
        fileRow("etc", "-", "folder", "2026-05-26", "drwxr-xr-x", palette, id_extra + 20);
        fileRow("home", "-", "folder", "2026-05-19", "drwxr-xr-x", palette, id_extra + 30);
        fileRow("var", "-", "folder", "2026-05-19", "drwxr-xr-x", palette, id_extra + 40);
    }
}

fn fileRow(name: []const u8, size: []const u8, kind: []const u8, modified: []const u8, perm: []const u8, palette: theme.Palette, id_extra: usize) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .background = true,
        .color_fill = if ((id_extra / 10) % 2 == 0) palette.panel_bg else palette.surface_bg,
        .expand = .horizontal,
        .min_size_content = .height(row_height),
        .max_size_content = .height(row_height),
        .padding = .all(0),
        .id_extra = id_extra,
    });
    defer row.deinit();

    cell(name, 160, palette, id_extra + 1);
    cell(size, 70, palette, id_extra + 2);
    cell(kind, 90, palette, id_extra + 3);
    cell(modified, 130, palette, id_extra + 4);
    cell(perm, 100, palette, id_extra + 5);
}

fn headerCell(text: []const u8, width: f32, palette: theme.Palette, id_extra: usize) void {
    dvui.label(@src(), "{s}", .{text}, .{
        .font = theme.textFont(text, 9),
        .color_text = palette.text_subtle,
        .min_size_content = .width(width),
        .gravity_y = 0.5,
        .padding = .{ .x = 8, .y = 0, .w = 8, .h = 0 },
        .id_extra = id_extra,
    });
}

fn cell(text: []const u8, width: f32, palette: theme.Palette, id_extra: usize) void {
    dvui.label(@src(), "{s}", .{text}, .{
        .font = theme.textFont(text, 10),
        .color_text = palette.muted_text,
        .min_size_content = .width(width),
        .gravity_y = 0.5,
        .padding = .{ .x = 8, .y = 0, .w = 8, .h = 0 },
        .id_extra = id_extra,
    });
}
