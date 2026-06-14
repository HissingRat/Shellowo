const dvui = @import("dvui");

const App = @import("../app/App.zig");
const remote_file = @import("../core/remote_file.zig");
const workspace = @import("../core/workspace.zig");
const file_panel = @import("workspace/file_panel.zig");
const resize = @import("workspace/resize.zig");
const status_panel = @import("workspace/status_panel.zig");
const terminal_panel = @import("workspace/terminal_panel.zig");
const terminal_slot = @import("../core/terminal_slot.zig");
const terminal_slot_bar = @import("workspace/terminal_slot_bar.zig");
const theme = @import("theme.zig");

const min_sidebar_width: f32 = 150;
const max_sidebar_width: f32 = 320;
const min_file_panel_height: f32 = 150;
const max_file_panel_height: f32 = 430;
const max_file_panel_rows: usize = 256;

pub fn show(app: *App, tab: workspace.WorkspaceTab, palette: theme.Palette) void {
    var stage = dvui.box(@src(), .{ .dir = .vertical }, theme.app(.{
        .expand = .both,
        .padding = .all(0),
        .id_extra = 600,
    }, palette));
    defer stage.deinit();

    terminalFileWorkspace(app, tab, palette);
}

fn terminalFileWorkspace(app: *App, tab: workspace.WorkspaceTab, palette: theme.Palette) void {
    const layout = &app.config.workspace;
    var shell = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .padding = .all(0),
        .id_extra = 610,
    });
    defer shell.deinit();

    status_panel.show(tab, app.sessions.statusPanelSnapshot(tab.id), palette, .{
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

    var tree_entries: [max_file_panel_rows]remote_file.RemoteFileEntry = undefined;
    var remote_entries: [max_file_panel_rows]remote_file.RemoteFileEntry = undefined;
    if (file_panel.show(tab, palette, .{
        .app = app,
        .snapshot = app.filePanelSnapshot(tab.id, &tree_entries, &remote_entries),
        .height = layout.file_panel_height,
        .local_width = &layout.local_file_width,
        .columns = &app.config.file_columns,
        .id_extra = 660,
    })) |intent| app.handleFilePanelIntent(tab.id, intent);
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
