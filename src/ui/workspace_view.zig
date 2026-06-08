const dvui = @import("dvui");

const App = @import("../app/App.zig");
const workspace = @import("../core/workspace.zig");
const file_panel = @import("workspace/file_panel.zig");
const resize = @import("workspace/resize.zig");
const status_panel = @import("workspace/status_panel.zig");
const terminal_panel = @import("workspace/terminal_panel.zig");
const terminal_slot = @import("../core/terminal_slot.zig");
const terminal_slot_bar = @import("workspace/terminal_slot_bar.zig");
const theme = @import("theme.zig");

const default_sidebar_width: f32 = 190;
const default_file_panel_height: f32 = 230;
const default_local_file_width: f32 = 214;
const transfer_height: f32 = 24;

const min_sidebar_width: f32 = 150;
const max_sidebar_width: f32 = 320;
const min_file_panel_height: f32 = 150;
const max_file_panel_height: f32 = 430;

const LayoutState = struct {
    sidebar_width: f32 = default_sidebar_width,
    file_panel_height: f32 = default_file_panel_height,
    local_file_width: f32 = default_local_file_width,
};

pub fn show(app: *App, tab: workspace.WorkspaceTab, palette: theme.Palette) void {
    var stage = dvui.box(@src(), .{ .dir = .vertical }, theme.app(.{
        .expand = .both,
        .padding = .all(0),
        .id_extra = 600,
    }, palette));
    defer stage.deinit();

    const layout = dvui.dataGetPtrDefault(null, stage.data().id, "layout", LayoutState, .{});

    switch (tab.layout) {
        .terminal_file => terminalFileWorkspace(app, tab, palette, layout),
        .file_only => fileOnlyWorkspace(tab, palette, layout),
    }
}

fn terminalFileWorkspace(app: *App, tab: workspace.WorkspaceTab, palette: theme.Palette, layout: *LayoutState) void {
    var shell = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .padding = .all(0),
        .id_extra = 610,
    });
    defer shell.deinit();

    status_panel.show(tab, palette, .{
        .width = layout.sidebar_width,
        .id_extra = 620,
    });

    resize.handle(palette, .{
        .axis = .vertical,
        .value = &layout.sidebar_width,
        .min = min_sidebar_width,
        .max = max_sidebar_width,
        .id_extra = 621,
    });

    var main = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .all(0),
        .id_extra = 630,
    });
    defer main.deinit();

    var snapshot = app.sessions.copySshSnapshot(app.allocator, tab.id) catch null;
    defer if (snapshot) |*shot| shot.deinit();

    var slot_buffer: [64]terminal_slot.TerminalSlotSummary = undefined;
    const slots = app.sessions.terminalSlots(tab.id, &slot_buffer);
    const active_slot_id = app.sessions.activeTerminalSlotId(tab.id);
    topSeparator(palette, 634);
    if (terminal_slot_bar.show(slots, palette, .{
        .id_extra = 635,
        .active_slot_id = active_slot_id,
    })) |action| {
        switch (action) {
            .activate => |slot_id| app.activateTerminalSlot(tab.id, slot_id),
            .close => |slot_id| app.closeTerminalSlot(tab.id, slot_id),
            .create => app.createTerminalSlot(tab.id),
        }
    }
    topSeparator(palette, 636);

    terminal_panel.show(app, tab, palette, .{
        .id_extra = 640,
        .snapshot = snapshot,
        .failure = app.sessions.sshFailure(tab.id),
        .active_slot_id = active_slot_id,
    });

    resize.handle(palette, .{
        .axis = .horizontal,
        .value = &layout.file_panel_height,
        .min = min_file_panel_height,
        .max = max_file_panel_height,
        .direction = -1,
        .id_extra = 650,
    });

    file_panel.show(tab, palette, .{
        .height = layout.file_panel_height,
        .local_width = &layout.local_file_width,
        .id_extra = 660,
    });

    transferStrip(palette, false, 670);
}

fn fileOnlyWorkspace(tab: workspace.WorkspaceTab, palette: theme.Palette, layout: *LayoutState) void {
    var shell = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .padding = .all(0),
        .id_extra = 680,
    });
    defer shell.deinit();

    status_panel.show(tab, palette, .{
        .width = layout.sidebar_width,
        .id_extra = 690,
    });

    resize.handle(palette, .{
        .axis = .vertical,
        .value = &layout.sidebar_width,
        .min = min_sidebar_width,
        .max = max_sidebar_width,
        .id_extra = 691,
    });

    var main = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .all(0),
        .id_extra = 700,
    });
    defer main.deinit();

    file_panel.show(tab, palette, .{
        .height = null,
        .local_width = &layout.local_file_width,
        .id_extra = 710,
    });

    transferStrip(palette, false, 720);
}

fn topSeparator(palette: theme.Palette, id_extra: usize) void {
    var line = dvui.box(@src(), .{}, .{
        .expand = .horizontal,
        .min_size_content = .height(1),
        .max_size_content = .height(1),
        .padding = .all(0),
        .background = true,
        .color_fill = palette.border_subtle,
        .id_extra = id_extra,
    });
    defer line.deinit();
}

fn transferStrip(palette: theme.Palette, full_width: bool, id_extra: usize) void {
    _ = full_width;
    var strip = dvui.box(@src(), .{ .dir = .horizontal }, theme.panel(.{
        .expand = .horizontal,
        .min_size_content = .height(transfer_height),
        .max_size_content = .height(transfer_height),
        .padding = .{ .x = 10, .y = 0, .w = 10, .h = 0 },
        .id_extra = id_extra,
    }, palette).override(.{
        .color_fill = palette.topbar_bg,
        .color_border = palette.border_subtle,
    }));
    defer strip.deinit();

    dvui.label(@src(), "Transfers", .{}, .{
        .font = theme.textFont("Transfers", 10),
        .color_text = palette.text_subtle,
        .gravity_y = 0.5,
        .id_extra = id_extra + 1,
    });

    dvui.label(@src(), "0 active tasks", .{}, .{
        .font = theme.textFont("0 active tasks", 10),
        .color_text = palette.muted_text,
        .gravity_x = 1,
        .gravity_y = 0.5,
        .id_extra = id_extra + 2,
    });
}
