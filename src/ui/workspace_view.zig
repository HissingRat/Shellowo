const dvui = @import("dvui");
const workspace = @import("../core/workspace.zig");
const theme = @import("theme.zig");

pub fn show(tab: workspace.WorkspaceTab, palette: theme.Palette) void {
    var stage = dvui.box(@src(), .{ .dir = .vertical }, theme.panel(.{
        .expand = .both,
        .padding = .all(18),
        .corner_radius = .all(0),
        .id_extra = 600,
    }, palette).override(.{
        .color_fill = palette.app_bg,
        .color_border = palette.border_subtle,
    }));
    defer stage.deinit();

    dvui.label(@src(), "{s}", .{tab.title}, .{
        .font = theme.textFont(tab.title, 20),
        .color_text = palette.text,
        .margin = .{ .h = 8 },
    });
    dvui.label(@src(), "{s} / {s}", .{ tab.layout.label(), tab.status.label() }, .{
        .color_text = palette.muted_text,
        .font = theme.textFont(tab.layout.label(), 12),
        .margin = .{ .h = 18 },
    });

    switch (tab.layout) {
        .terminal_file => sshWorkspace(palette),
        .file_only => fileOnlyWorkspace(palette),
    }
}

fn sshWorkspace(palette: theme.Palette) void {
    var terminal = dvui.box(@src(), .{ .dir = .vertical }, theme.panel(.{
        .expand = .both,
        .padding = .all(12),
        .corner_radius = .all(4),
        .id_extra = 610,
    }, palette).override(.{
        .color_fill = palette.surface_bg,
        .color_border = palette.border_subtle,
    }));
    defer terminal.deinit();

    dvui.label(@src(), "Terminal", .{}, .{ .font = theme.textFont("Terminal", 13), .color_text = palette.text });
    dvui.label(@src(), "$ ssh session will render here", .{}, .{ .font = theme.textFont("$ ssh session will render here", 12), .color_text = palette.text_subtle });
}

fn fileOnlyWorkspace(palette: theme.Palette) void {
    var files = dvui.box(@src(), .{ .dir = .vertical }, theme.panel(.{
        .expand = .both,
        .padding = .all(12),
        .corner_radius = .all(4),
        .id_extra = 620,
    }, palette).override(.{
        .color_fill = palette.surface_bg,
        .color_border = palette.border_subtle,
    }));
    defer files.deinit();

    dvui.label(@src(), "Files", .{}, .{ .font = theme.textFont("Files", 13), .color_text = palette.text });
    dvui.label(@src(), "Remote directory table will render here.", .{}, .{ .font = theme.textFont("Remote directory table will render here.", 12), .color_text = palette.text_subtle });
}
