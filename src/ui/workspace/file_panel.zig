const std = @import("std");
const dvui = @import("dvui");

const App = @import("../../app/App.zig");
const app_config = @import("../../app/config.zig");
const native_event = @import("../../app/native_event.zig");
const remote_file = @import("../../core/remote_file.zig");
const workspace = @import("../../core/workspace.zig");
const active_tasks_panel = @import("file_panel_elements/active_tasks_panel.zig");
const context_menu = @import("file_panel_elements/context_menu.zig");
const details_panel = @import("file_panel_elements/details_panel.zig");
const file_format = @import("file_panel_elements/file_format.zig");
const permissions_panel = @import("file_panel_elements/permissions_panel.zig");
const remote_editor = @import("file_panel_elements/remote_editor.zig");
const split_view = @import("../layouts/split_view.zig");
const theme = @import("../theme.zig");
const transfer_confirm = @import("file_panel_elements/transfer_confirm.zig");
const panel_state = @import("../features/files/panel_state.zig");

const ColumnWidths = panel_state.ColumnWidths;
const PathBarState = panel_state.PathBar;
const PaneLayoutState = panel_state.PaneLayout;
const EditMode = panel_state.EditMode;
const PaneKind = panel_state.PaneKind;

const folder_icon_bytes = @embedFile("shellowo-folder-icon");
const file_icon_bytes = @embedFile("shellowo-file-icon");

pub const Options = struct {
    app: *App,
    snapshot: remote_file.FilePanelSnapshot,
    height: ?f32,
    local_width: *f32,
    columns: *app_config.FileColumnWidths,
    id_extra: usize,
};

const min_local_width: f32 = 160;
const max_local_width: f32 = 380;
const toolbar_height: f32 = 31;
const row_height: f32 = 24;
const header_height: f32 = 24;
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
const path_entry_max_len: usize = 512;
const toast_visible_ns: i128 = 2 * std.time.ns_per_s;
const toast_fade_ns: i128 = 180 * std.time.ns_per_ms;
const toast_tooltip_offset: dvui.Point.Natural = .{ .x = 12, .y = 14 };
const toast_tooltip_max_width: f32 = 280;
const drop_tooltip_width: f32 = 58;
const drop_tooltip_height: f32 = 22;
const drop_tooltip_offset: dvui.Point.Natural = .{ .x = 14, .y = 16 };

pub fn show(tab: workspace.WorkspaceTab, palette: theme.Palette, opts: Options) ?remote_file.FilePanelIntent {
    _ = tab;
    var intent: ?remote_file.FilePanelIntent = null;
    var root = dvui.box(@src(), .{ .dir = .vertical }, theme.panel(panelOptions(opts), palette).override(.{
        .color_fill = palette.panel_bg,
        .color_border = palette.border_subtle,
    }));
    defer root.deinit();

    pathBar(opts.app, opts.snapshot.remote, palette, opts.id_extra + 10, &intent);

    var split = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .padding = .all(0),
        .id_extra = opts.id_extra + 20,
    });
    defer split.deinit();

    filePane(.tree, palette, .{
        .app = opts.app,
        .tree = opts.snapshot.tree,
        .snapshot = .{ .location = .sftp },
        .editor = opts.snapshot.editor,
        .width = opts.local_width.*,
        .columns = opts.columns,
        .id_extra = opts.id_extra + 30,
    }, &intent);
    split_view.handle(palette, .{
        .axis = .vertical,
        .value = opts.local_width,
        .min = min_local_width,
        .max = max_local_width,
        .id_extra = opts.id_extra + 40,
    });
    filePane(.remote, palette, .{
        .app = opts.app,
        .snapshot = opts.snapshot.remote,
        .editor = opts.snapshot.editor,
        .width = null,
        .columns = opts.columns,
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

fn pathBar(app: *App, remote: remote_file.FilePaneSnapshot, palette: theme.Palette, id_extra: usize, intent: *?remote_file.FilePanelIntent) void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, theme.panel(.{
        .expand = .horizontal,
        .min_size_content = .height(toolbar_height),
        .max_size_content = .height(toolbar_height),
        .padding = .{ .x = 12, .y = 0, .w = 12, .h = 0 },
        .id_extra = id_extra,
    }, palette).override(.{ .color_fill = palette.topbar_bg }));
    defer bar.deinit();
    const state = dvui.dataGetPtrDefault(null, bar.data().id, "file-path-bar", PathBarState, .{});
    state.observePath(remote.path);
    const editable = pathBarEditable(remote);
    if (!editable and state.editing) state.cancelEdit();

    if (state.editing) {
        var te: dvui.TextEntryWidget = undefined;
        te.init(@src(), .{
            .text = .{ .buffer = &state.buffer },
            .placeholder = remote.path,
        }, theme.panel(.{
            .expand = .horizontal,
            .min_size_content = .height(toolbar_height - 8),
            .max_size_content = .height(toolbar_height - 8),
            .font = theme.textFont(remote.path, 10),
            .padding = .{ .x = 6, .y = 2.5, .w = 6, .h = 0 },
            .corner_radius = .all(3),
            .id_extra = id_extra + 1,
        }, palette).override(.{
            .color_fill = palette.surface_bg,
            .color_border = palette.surface_bg,
        }));
        if (state.focus_requested) {
            dvui.focusWidget(te.data().id, null, null);
            state.focus_requested = false;
        }
        te.processEvents();
        const canceled = pathBarCancelPressed(te.data());
        const entered = te.enter_pressed;
        const focused = dvui.focusedWidgetIdInCurrentSubwindow() == te.data().id;
        const path = std.mem.trim(u8, state.buffer[0..te.len], " \t\r\n");
        drawPathTextEntry(&te);
        te.deinit();

        if (canceled) {
            state.cancelEdit();
        } else if (entered and path.len > 0) {
            state.cancelEdit();
            intent.* = .{ .go_path = .{ .pane = .remote, .path = path } };
        } else if (!focused) {
            state.cancelEdit();
        }
    } else {
        var path_slot = dvui.box(@src(), .{}, .{
            .expand = .horizontal,
            .min_size_content = .height(toolbar_height),
            .max_size_content = .height(toolbar_height),
            .background = true,
            .padding = .{ .x = 4, .y = 0, .w = 4, .h = 0 },
            .corner_radius = .all(3),
            .id_extra = id_extra + 1,
            .color_fill = palette.topbar_bg,
            .color_border = palette.topbar_bg,
        });
        defer path_slot.deinit();
        var clicked = false;
        const path_rect = path_slot.data().contentRectScale().r;
        for (dvui.events()) |*event| {
            if (!dvui.eventMatch(event, .{ .id = path_slot.data().id, .r = path_rect })) continue;
            switch (event.evt) {
                .mouse => |mouse| switch (mouse.action) {
                    .release => if (mouse.button.pointer()) {
                        event.handle(@src(), path_slot.data());
                        clicked = true;
                    },
                    else => {},
                },
                else => {},
            }
        }
        path_slot.drawBackground();
        dvui.label(@src(), "{s}", .{remote.path}, .{
            .font = theme.textFont(remote.path, 10),
            .color_text = palette.muted_text,
            .expand = .horizontal,
            .gravity_y = 0.5,
            .id_extra = id_extra + 2,
        });
        if (clicked and editable) {
            state.beginEdit(remote.path);
            dvui.refresh(null, @src(), path_slot.data().id);
        }
    }

    active_tasks_panel.showButton(app, palette, id_extra + 20);
}

fn pathBarEditable(remote: remote_file.FilePaneSnapshot) bool {
    return remote.state == .ready or remote.state == .failed;
}

fn pathBarCancelPressed(data: *dvui.WidgetData) bool {
    for (dvui.events()) |*event| {
        if (event.handled or event.evt != .key) continue;
        const key = event.evt.key;
        if (key.action != .down and key.action != .repeat) continue;
        if (key.code != .escape) continue;
        event.handle(@src(), data);
        dvui.focusWidget(null, null, event.num);
        dvui.refresh(null, @src(), data.id);
        return true;
    }
    return false;
}

fn drawPathTextEntry(te: *dvui.TextEntryWidget) void {
    te.drawBeforeText();
    if (te.len == 0) {
        if (te.init_opts.placeholder) |placeholder| {
            te.textLayout.addText(placeholder, .{ .color_text = te.textLayout.data().options.color(.text).opacity(0.65) });
        }
    } else {
        te.textLayout.addText(te.text[0..te.len], te.data().options.strip());
    }
    te.textLayout.addTextDone(te.data().options.strip());
    if (te.data().id == dvui.focusedWidgetId()) {
        te.drawCursor();
    }
    dvui.clipSet(te.prevClip);
}

const TreeRowAction = enum { none, toggle, row_click };
const PaneOptions = struct {
    app: *App,
    tree: remote_file.FileTreeSnapshot = .{},
    snapshot: remote_file.FilePaneSnapshot,
    editor: remote_file.FileEditorSnapshot = .{},
    width: ?f32,
    columns: *ColumnWidths,
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
    if (!layout.columns_initialized) {
        layout.columns = opts.columns.*;
        layout.columns_initialized = true;
    }

    if (kind == .tree) {
        treeRows(opts.tree, layout, palette, opts.id_extra + 20, intent);
        return;
    }
    layout.observeToast(opts.snapshot.error_summary);
    layout.details.syncFromSnapshot(opts.snapshot);
    failureTooltip(layout, palette, opts.id_extra + 6);
    const path_busy = opts.app.transferBusyInRemotePath(opts.snapshot.path);
    tableHeader(layout, palette, opts.id_extra + 10);
    opts.columns.* = layout.columns;
    fileRows(kind, opts.app, opts.snapshot, layout, path_busy, palette, opts.id_extra + 30, intent);
    handleDeleteConfirm(opts.snapshot, layout, palette, opts.id_extra + 5000, intent);
    if (details_panel.show(&layout.details, palette, opts.id_extra + 5200)) |action| {
        switch (action) {
            .edit_permissions => |entry| layout.permissions.openFor(entry),
        }
    }
    if (permissions_panel.show(&layout.permissions, palette, opts.id_extra + 5400)) |panel_intent| {
        switch (panel_intent) {
            .chmod => |chmod| layout.details.applyPermissions(chmod.path, chmod.permissions),
            else => {},
        }
        intent.* = panel_intent;
    }
    if (remote_editor.show(&layout.editor, opts.editor, palette, opts.id_extra + 5600)) |editor_intent| {
        intent.* = editor_intent;
    }
    switch (transfer_confirm.show(&layout.transfer_confirm, palette, opts.id_extra + 5800)) {
        .none => {},
        .cancel => layout.transfer_confirm.clear(),
        .overwrite => {
            intent.* = layout.transfer_confirm.intent();
            layout.transfer_confirm.clear();
        },
    }
    if (intent.* != null) layout.clearToastGate();
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
    split_view.handle(palette, .{ .axis = .vertical, .value = &layout.columns.name, .min = min_name_width, .max = max_name_width, .id_extra = id_extra + 2, .thickness = 7, .sep_thickness = 0 });
    headerCell("Size", columns.size, palette, id_extra + 3);
    split_view.handle(palette, .{ .axis = .vertical, .value = &layout.columns.size, .min = min_size_width, .max = max_size_width, .id_extra = id_extra + 4, .thickness = 7, .sep_thickness = 0 });
    headerCell("Modified", columns.modified, palette, id_extra + 5);
    split_view.handle(palette, .{ .axis = .vertical, .value = &layout.columns.modified, .min = min_modified_width, .max = max_modified_width, .id_extra = id_extra + 6, .thickness = 7, .sep_thickness = 0 });
    headerCell("Perm", columns.perm, palette, id_extra + 7);
    split_view.handle(palette, .{ .axis = .vertical, .value = &layout.columns.perm, .min = min_perm_width, .max = max_perm_width, .id_extra = id_extra + 8, .thickness = 7, .sep_thickness = 0 });
    headerCell("User/Group", columns.owner, palette, id_extra + 9);

    drawColumnSeparators(row.data().contentRectScale(), columns, palette);
}

fn fileRows(kind: PaneKind, app: *App, snapshot: remote_file.FilePaneSnapshot, layout: *PaneLayoutState, path_busy: bool, palette: theme.Palette, id_extra: usize, intent: *?remote_file.FilePanelIntent) void {
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

    const drop_rect = scroll.data().contentRectScale().r;
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

    registerDropTarget(kind, app, snapshot, path_busy, drop_rect);
    renderDropTooltip(kind, app, snapshot, palette, id_extra + 7000);
    handleDroppedUploads(kind, app, snapshot, layout, path_busy, drop_rect, intent);

    if (layout.edit_mode == .new_file or layout.edit_mode == .new_folder) {
        editFileRow(snapshot, layout, palette, id_extra + 3, intent);
    }

    if (snapshot.entries.len == 0 and layout.edit_mode == .none) {
        emptyRow("No files", palette, id_extra);
        handleBlankContextMenu(app, snapshot, layout, path_busy, blankContextRect(scroll.data().contentRectScale(), 1), palette, id_extra + 500, intent);
        return;
    }

    for (snapshot.entries, 0..) |entry, idx| {
        fileRow(kind, app, snapshot, entry, layout, path_busy, palette, id_extra + idx * 10, intent);
    }
    const row_count = snapshot.entries.len + if (layout.edit_mode == .new_file or layout.edit_mode == .new_folder) @as(usize, 1) else 0;
    handleBlankContextMenu(app, snapshot, layout, path_busy, blankContextRect(scroll.data().contentRectScale(), row_count), palette, id_extra + 500, intent);
}

fn treeRows(snapshot: remote_file.FileTreeSnapshot, layout: *PaneLayoutState, palette: theme.Palette, id_extra: usize, intent: *?remote_file.FilePanelIntent) void {
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

fn treeRow(snapshot: remote_file.FileTreeSnapshot, entry: remote_file.RemoteFileEntry, layout: *PaneLayoutState, palette: theme.Palette, id_extra: usize, intent: *?remote_file.FilePanelIntent) void {
    const selected = treeEntrySelected(snapshot.path, entry);
    var row = dvui.box(@src(), .{}, .{
        .expand = .horizontal,
        .background = true,
        .min_size_content = .{ .w = treeRowWidth(entry), .h = row_height },
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
            if (registerEntryClick(layout, .tree, path) >= 2) {
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

fn treeRowWidth(entry: remote_file.RemoteFileEntry) f32 {
    const font = theme.textFont(entry.name, 10);
    const text_width = font.textSize(entry.name).w;
    const indent = @as(f32, @floatFromInt(entry.depth)) * tree_indent + 8;
    const right_padding: f32 = 8;
    return indent + tree_disclosure_width + file_icon_size + file_icon_gap + text_width + right_padding;
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

fn fileRow(kind: PaneKind, app: *App, snapshot: remote_file.FilePaneSnapshot, entry: remote_file.RemoteFileEntry, layout: *PaneLayoutState, path_busy: bool, palette: theme.Palette, id_extra: usize, intent: *?remote_file.FilePanelIntent) void {
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
        const click_count = registerEntryClick(layout, kind, entry.name);
        if (entry.isDirectory() and click_count >= 2) {
            intent.* = .{ .open = .{
                .pane = pane,
                .path = snapshot.path,
                .name = entry.name,
            } };
        } else if (kind == .remote and entry.kind == .file and snapshot.capabilities.can_edit and click_count >= 2) {
            intent.* = .{ .open_edit = .{
                .pane = .remote,
                .path = snapshot.path,
                .name = entry.name,
                .size = entry.size,
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
    renderCellText(crs, x, columns.size, file_format.sizeText(entry, &size_buf), palette.muted_text, id_extra + 3);
    x += columns.size;
    var modified_buf: [32]u8 = undefined;
    renderCellText(crs, x, columns.modified, file_format.modifiedText(entry, &modified_buf), palette.muted_text, id_extra + 4);
    x += columns.modified;
    var perm_buf: [12]u8 = undefined;
    renderCellText(crs, x, columns.perm, file_format.permissionText(entry, &perm_buf), palette.muted_text, id_extra + 5);
    x += columns.perm;
    var owner_buf: [40]u8 = undefined;
    renderCellText(crs, x, columns.owner, file_format.ownerText(entry, &owner_buf), palette.muted_text, id_extra + 6);

    handleEntryContextMenu(kind, app, snapshot, entry, layout, path_busy, crs.r, palette, id_extra + 100, intent);
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

fn uploadFilesIntent(snapshot: remote_file.FilePaneSnapshot) ?remote_file.FilePanelIntent {
    const arena = dvui.currentWindow().arena();
    const paths = dvui.dialogNativeFileOpenMultiple(arena, .{ .title = "Upload Files" }) catch return null;
    const selected = paths orelse return null;
    if (selected.len == 0) return null;

    const first_dir = std.fs.path.dirname(selected[0]) orelse "";
    if (selected.len == 1) {
        return .{ .upload = .{
            .local_path = first_dir,
            .remote_path = snapshot.path,
            .name = std.fs.path.basename(selected[0]),
        } };
    }

    const entries = arena.alloc(remote_file.FileBatchEntry, selected.len) catch return null;
    for (selected, 0..) |path, idx| {
        entries[idx] = .{
            .name = std.fs.path.basename(path),
            .kind = .file,
        };
    }
    return .{ .upload_many = .{
        .local_path = first_dir,
        .remote_path = snapshot.path,
        .entries = entries,
    } };
}

fn uploadFolderIntent(snapshot: remote_file.FilePaneSnapshot) ?remote_file.FilePanelIntent {
    const arena = dvui.currentWindow().arena();
    const path = dvui.dialogNativeFolderSelect(arena, .{ .title = "Upload Folder" }) catch return null;
    const selected = path orelse return null;
    return .{ .upload = .{
        .local_path = std.fs.path.dirname(selected) orelse "",
        .remote_path = snapshot.path,
        .name = std.fs.path.basename(selected),
    } };
}

fn droppedUploadIntent(snapshot: remote_file.FilePaneSnapshot, path: []const u8) ?remote_file.FilePanelIntent {
    const name = std.fs.path.basename(path);
    if (name.len == 0) return null;
    return .{ .upload = .{
        .local_path = std.fs.path.dirname(path) orelse "",
        .remote_path = snapshot.path,
        .name = name,
    } };
}

fn handleDroppedUploads(kind: PaneKind, app: *const App, snapshot: remote_file.FilePaneSnapshot, layout: *PaneLayoutState, path_busy: bool, rect: dvui.Rect.Physical, intent: *?remote_file.FilePanelIntent) void {
    if (intent.* != null or kind != .remote or snapshot.state != .ready or !snapshot.capabilities.can_upload or path_busy) return;
    var paths: [max_selected_entries][]const u8 = undefined;
    var count: usize = 0;
    for (app.nativeEvents()) |event| {
        switch (event) {
            .file_drop => |drop| {
                if (!rect.contains(.{ .x = drop.x, .y = drop.y })) continue;
                if (count < paths.len) {
                    paths[count] = drop.path;
                    count += 1;
                }
            },
        }
    }
    if (count == 0) return;
    if (count == 1) {
        queueTransferIntent(app, snapshot, layout, droppedUploadIntent(snapshot, paths[0]), intent);
        return;
    }

    const first_dir = std.fs.path.dirname(paths[0]) orelse "";
    for (paths[1..count]) |path| {
        const dir = std.fs.path.dirname(path) orelse "";
        if (!std.mem.eql(u8, dir, first_dir)) {
            queueTransferIntent(app, snapshot, layout, droppedUploadIntent(snapshot, paths[0]), intent);
            return;
        }
    }

    const arena = dvui.currentWindow().arena();
    const entries = arena.alloc(remote_file.FileBatchEntry, count) catch {
        queueTransferIntent(app, snapshot, layout, droppedUploadIntent(snapshot, paths[0]), intent);
        return;
    };
    for (paths[0..count], 0..) |path, idx| {
        entries[idx] = .{
            .name = std.fs.path.basename(path),
            .kind = .file,
        };
    }
    queueTransferIntent(app, snapshot, layout, .{ .upload_many = .{
        .local_path = first_dir,
        .remote_path = snapshot.path,
        .entries = entries,
    } }, intent);
}

fn registerDropTarget(kind: PaneKind, app: *App, snapshot: remote_file.FilePaneSnapshot, path_busy: bool, rect: dvui.Rect.Physical) void {
    if (kind != .remote or snapshot.state != .ready or !snapshot.capabilities.can_upload or path_busy) return;
    app.registerFileDropTarget(.{
        .x = rect.x,
        .y = rect.y,
        .w = rect.w,
        .h = rect.h,
    });
}

fn renderDropTooltip(kind: PaneKind, app: *const App, snapshot: remote_file.FilePaneSnapshot, palette: theme.Palette, id_extra: usize) void {
    if (kind != .remote or snapshot.state != .ready or !snapshot.capabilities.can_upload) return;
    const point = app.fileDragPoint() orelse return;
    if (!app.canAcceptFileDrop(point.x, point.y)) return;
    const natural_point = dvui.windowRectScale().pointFromPhysical(.{ .x = point.x, .y = point.y });
    var tooltip_rect = dvui.Rect.Natural{
        .x = natural_point.x + drop_tooltip_offset.x,
        .y = natural_point.y + drop_tooltip_offset.y,
        .w = drop_tooltip_width,
        .h = drop_tooltip_height,
    };
    tooltip_rect = dvui.placeOnScreen(dvui.windowRect(), .{}, .none, tooltip_rect);

    var tooltip: dvui.FloatingWidget = undefined;
    tooltip.init(@src(), .{ .mouse_events = false }, theme.panel(.{
        .rect = .cast(tooltip_rect),
        .min_size_content = .{ .w = drop_tooltip_width, .h = drop_tooltip_height },
        .max_size_content = .{ .w = drop_tooltip_width, .h = drop_tooltip_height },
        .padding = .{ .x = 2, .y = 1, .w = 2, .h = 1 },
        .corner_radius = .all(4),
        .id_extra = id_extra,
    }, palette).override(.{
        .color_fill = palette.surface_active.opacity(0.86),
        .color_border = palette.border.opacity(0.72),
        .color_text = palette.text,
    }));
    defer tooltip.deinit();

    dvui.label(@src(), "Upload", .{}, .{
        .font = theme.textFont("Upload", 9),
        .color_text = palette.text,
        .gravity_y = 0.5,
        .id_extra = id_extra + 1,
        .padding = .all(0),
        .margin = .all(0),
    });
}

fn queueTransferIntent(app: *const App, snapshot: remote_file.FilePaneSnapshot, layout: *PaneLayoutState, candidate: ?remote_file.FilePanelIntent, intent: *?remote_file.FilePanelIntent) void {
    const transfer_intent = candidate orelse return;
    var message_buf: [160]u8 = undefined;
    if (transferConflictMessage(app, snapshot, transfer_intent, &message_buf)) |message| {
        layout.transfer_confirm.set(transfer_intent, message);
        return;
    }
    intent.* = transfer_intent;
}

fn transferConflictMessage(app: *const App, snapshot: remote_file.FilePaneSnapshot, intent: remote_file.FilePanelIntent, buf: []u8) ?[]const u8 {
    return switch (intent) {
        .upload => |item| if (remoteNameExists(snapshot, item.name))
            std.fmt.bufPrint(buf, "Remote item '{s}' already exists. Overwrite it?", .{item.name}) catch "Remote item already exists. Overwrite it?"
        else
            null,
        .upload_many => |item| conflictMessageForRemoteBatch(snapshot, item.entries, buf),
        .download => |item| if (localTargetExists(app, item.local_path, item.name))
            std.fmt.bufPrint(buf, "Local item '{s}' already exists. Overwrite it?", .{item.name}) catch "Local item already exists. Overwrite it?"
        else
            null,
        .download_many => |item| conflictMessageForLocalBatch(app, item.local_path, item.entries, buf),
        else => null,
    };
}

fn conflictMessageForRemoteBatch(snapshot: remote_file.FilePaneSnapshot, entries: []const remote_file.FileBatchEntry, buf: []u8) ?[]const u8 {
    var count: usize = 0;
    var first: []const u8 = "";
    for (entries) |entry| {
        if (!remoteNameExists(snapshot, entry.name)) continue;
        if (count == 0) first = entry.name;
        count += 1;
    }
    if (count == 0) return null;
    if (count == 1) {
        return std.fmt.bufPrint(buf, "Remote item '{s}' already exists. Overwrite it?", .{first}) catch "Remote item already exists. Overwrite it?";
    }
    return std.fmt.bufPrint(buf, "{d} remote items already exist. Overwrite them?", .{count}) catch "Remote items already exist. Overwrite them?";
}

fn conflictMessageForLocalBatch(app: *const App, local_path: []const u8, entries: []const remote_file.FileBatchEntry, buf: []u8) ?[]const u8 {
    var count: usize = 0;
    var first: []const u8 = "";
    for (entries) |entry| {
        if (!localTargetExists(app, local_path, entry.name)) continue;
        if (count == 0) first = entry.name;
        count += 1;
    }
    if (count == 0) return null;
    if (count == 1) {
        return std.fmt.bufPrint(buf, "Local item '{s}' already exists. Overwrite it?", .{first}) catch "Local item already exists. Overwrite it?";
    }
    return std.fmt.bufPrint(buf, "{d} local items already exist. Overwrite them?", .{count}) catch "Local items already exist. Overwrite them?";
}

fn remoteNameExists(snapshot: remote_file.FilePaneSnapshot, name: []const u8) bool {
    return entryByName(snapshot, name) != null;
}

fn localTargetExists(app: *const App, local_path: []const u8, name: []const u8) bool {
    const io = app.io orelse return false;
    const arena = dvui.currentWindow().arena();
    const base = if (local_path.len > 0) local_path else app.config.download_path;
    const full_path = std.fs.path.join(arena, &.{ base, name }) catch return false;
    if (std.fs.path.isAbsolute(full_path)) {
        std.Io.Dir.accessAbsolute(io, full_path, .{}) catch return false;
        return true;
    }
    std.Io.Dir.cwd().access(io, full_path, .{}) catch return false;
    return true;
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

fn handleDeleteConfirm(snapshot: remote_file.FilePaneSnapshot, layout: *PaneLayoutState, palette: theme.Palette, id_extra: usize, intent: *?remote_file.FilePanelIntent) void {
    if (!layout.delete_pending) return;
    switch (context_menu.deleteConfirm(palette, layout.deleteName(), layout.delete_anchor, id_extra)) {
        .none => {},
        .cancel => layout.delete_pending = false,
        .confirm => {
            intent.* = .{ .delete = .{
                .pane = .remote,
                .path = snapshot.path,
                .name = layout.deleteName(),
                .kind = layout.delete_kind,
            } };
            layout.delete_pending = false;
        },
    }
}

fn failureTooltip(layout: *PaneLayoutState, palette: theme.Palette, id_extra: usize) void {
    if (layout.toast_message_len == 0) return;
    const elapsed = dvui.frameTimeNS() - layout.toast_started_ns;
    if (elapsed > toast_visible_ns) {
        layout.dismissToast();
        return;
    }

    const alpha = toastAlpha(elapsed);
    if (alpha <= 0) return;
    dvui.refresh(null, @src(), dvui.currentWindow().data().id.update("file_failure_tooltip"));

    const message = layout.toastMessage();
    const font = theme.textFont(message, 9);
    const text_size = font.textSize(message);
    const natural_mouse = dvui.windowRectScale().pointFromPhysical(dvui.currentWindow().mouse_pt);
    var rect = dvui.Rect.Natural{
        .x = natural_mouse.x + toast_tooltip_offset.x,
        .y = natural_mouse.y + toast_tooltip_offset.y,
        .w = @min(toast_tooltip_max_width, text_size.w + 8),
        .h = text_size.h + 2,
    };
    rect = dvui.placeOnScreen(dvui.windowRect(), .{}, .none, rect);

    var tooltip: dvui.FloatingTooltipWidget = undefined;
    tooltip.init(@src(), .{
        .active_rect = dvui.windowRectPixels(),
        .position = .absolute,
        .interactive = false,
    }, theme.panel(.{
        .rect = .cast(rect),
        .min_size_content = .{ .w = rect.w, .h = rect.h },
        .padding = .{ .x = 2, .y = 1, .w = 2, .h = 1 },
        .corner_radius = .all(4),
        .id_extra = id_extra,
    }, palette).override(.{
        .color_fill = palette.surface_active.opacity(0.82 * alpha),
        .color_border = palette.border.opacity(0.65 * alpha),
        .color_text = palette.text.opacity(alpha),
    }));
    defer tooltip.deinit();

    if (tooltip.shown()) {
        dvui.label(@src(), "{s}", .{message}, .{
            .font = font,
            .color_text = palette.text.opacity(alpha),
            .id_extra = id_extra + 1,
            .margin = .all(0),
            .padding = .all(0),
        });
    }
}

fn toastAlpha(elapsed: i128) f32 {
    const remaining = toast_visible_ns - elapsed;
    const ramp_ns = @min(@min(elapsed, remaining), toast_fade_ns);
    if (ramp_ns <= 0) return 0;
    return @min(1.0, @as(f32, @floatFromInt(ramp_ns)) / @as(f32, @floatFromInt(toast_fade_ns)));
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

fn handleEntryContextMenu(kind: PaneKind, app: *App, snapshot: remote_file.FilePaneSnapshot, entry: remote_file.RemoteFileEntry, layout: *PaneLayoutState, path_busy: bool, rect: dvui.Rect.Physical, palette: theme.Palette, id_extra: usize, intent: *?remote_file.FilePanelIntent) void {
    const can_mutate = kind == .remote and snapshot.state == .ready;
    const entry_busy = app.remoteEntryTransferBusy(snapshot.path, entry.name);
    const action = context_menu.entry(palette, .{
        .rect = rect,
        .can_mutate = can_mutate,
        .capabilities = snapshot.capabilities,
        .kind = entry.kind,
        .entry_busy = entry_busy,
        .path_busy = path_busy,
        .id_extra = id_extra,
    }) orelse return;

    switch (action.kind) {
        .new_file => layout.startCreate(.new_file),
        .new_folder => layout.startCreate(.new_folder),
        .rename => layout.startRename(entry.name),
        .delete => layout.setDeletePending(entry.name, entry.kind, action.anchor),
        .edit => intent.* = .{ .open_edit = .{
            .pane = .remote,
            .path = snapshot.path,
            .name = entry.name,
            .size = entry.size,
        } },
        .download => queueTransferIntent(app, snapshot, layout, downloadIntent(snapshot, layout, entry), intent),
        .upload => queueTransferIntent(app, snapshot, layout, uploadFilesIntent(snapshot), intent),
        .upload_folder => queueTransferIntent(app, snapshot, layout, uploadFolderIntent(snapshot), intent),
        .details => layout.details.show(snapshot, entry),
    }
}

fn handleBlankContextMenu(app: *const App, snapshot: remote_file.FilePaneSnapshot, layout: *PaneLayoutState, path_busy: bool, rect: dvui.Rect.Physical, palette: theme.Palette, id_extra: usize, intent: *?remote_file.FilePanelIntent) void {
    const action = context_menu.blank(palette, .{
        .rect = rect,
        .can_mutate = snapshot.state == .ready,
        .capabilities = snapshot.capabilities,
        .path_busy = path_busy,
        .id_extra = id_extra,
    }) orelse return;

    switch (action) {
        .new_file => layout.startCreate(.new_file),
        .new_folder => layout.startCreate(.new_folder),
        .upload => queueTransferIntent(app, snapshot, layout, uploadFilesIntent(snapshot), intent),
        .upload_folder => queueTransferIntent(app, snapshot, layout, uploadFolderIntent(snapshot), intent),
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
        .tree => .remote,
        .remote => .remote,
    };
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
