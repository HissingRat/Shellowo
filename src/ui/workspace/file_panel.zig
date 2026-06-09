const std = @import("std");
const dvui = @import("dvui");

const remote_file = @import("../../core/remote_file.zig");
const workspace = @import("../../core/workspace.zig");
const resize = @import("resize.zig");
const theme = @import("../theme.zig");

const folder_icon_bytes = @embedFile("shellowo-folder-icon");
const file_icon_bytes = @embedFile("shellowo-file-icon");

pub const Options = struct {
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
};

pub fn show(tab: workspace.WorkspaceTab, palette: theme.Palette, opts: Options) ?remote_file.FilePanelIntent {
    _ = tab;
    var intent: ?remote_file.FilePanelIntent = null;
    var root = dvui.box(@src(), .{ .dir = .vertical }, theme.panel(panelOptions(opts), palette).override(.{
        .color_fill = palette.panel_bg,
        .color_border = palette.border_subtle,
    }));
    defer root.deinit();

    pathBar(opts.snapshot.remote, palette, opts.id_extra + 10);

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

fn pathBar(remote: remote_file.FilePaneSnapshot, palette: theme.Palette, id_extra: usize) void {
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

    if (kind == .local) {
        treeRows(opts.snapshot, layout, palette, opts.id_extra + 20, intent);
        return;
    }
    tableHeader(layout, palette, opts.id_extra + 10);
    fileRows(kind, opts.snapshot, layout, palette, opts.id_extra + 30, intent);
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

    if (snapshot.entries.len == 0) {
        emptyRow("No files", palette, id_extra);
        return;
    }

    for (snapshot.entries, 0..) |entry, idx| {
        fileRow(kind, snapshot, entry, layout, palette, id_extra + idx * 10, intent);
    }
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

    entryContextMenu(kind, snapshot, entry, crs.r, palette, id_extra + 100, intent);
    button.drawFocus();
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

fn entryContextMenu(kind: PaneKind, snapshot: remote_file.FilePaneSnapshot, entry: remote_file.RemoteFileEntry, rect: dvui.Rect.Physical, palette: theme.Palette, id_extra: usize, intent: *?remote_file.FilePanelIntent) void {
    if (rect.empty()) return;

    const context = dvui.context(@src(), .{ .rect = rect }, .{ .id_extra = id_extra });
    defer context.deinit();

    const active_point = context.activePoint() orelse return;
    var menu = dvui.floatingMenu(@src(), .{ .from = .fromPoint(active_point) }, fileContextMenuOptions(palette, id_extra + 1));
    defer menu.deinit();

    const pane = paneTarget(kind);
    const can_mutate = kind == .remote and snapshot.state == .ready;
    if (fileContextMenuItem("New File", false, palette, id_extra + 2)) |_| {
        menu.close();
    }
    if (fileContextMenuItem("New Folder", can_mutate and snapshot.capabilities.can_create_directory, palette, id_extra + 3)) |_| {
        intent.* = .{ .create_directory = .{
            .pane = pane,
            .parent_path = snapshot.path,
            .name = "New Folder",
        } };
        menu.close();
    }
    if (fileContextMenuItem("Rename", can_mutate and snapshot.capabilities.can_rename, palette, id_extra + 4)) |_| {
        intent.* = .{ .rename = .{
            .pane = pane,
            .path = snapshot.path,
            .old_name = entry.name,
            .new_name = entry.name,
        } };
        menu.close();
    }
    if (fileContextMenuItem("Delete", can_mutate and snapshot.capabilities.can_delete, palette, id_extra + 5)) |_| {
        intent.* = .{ .delete = .{
            .pane = pane,
            .path = snapshot.path,
            .name = entry.name,
        } };
        menu.close();
    }
    if (fileContextMenuItem("Download", can_mutate and snapshot.capabilities.can_download, palette, id_extra + 6)) |_| {
        intent.* = .{ .download = .{
            .local_path = "",
            .remote_path = snapshot.path,
            .name = entry.name,
        } };
        menu.close();
    }
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
