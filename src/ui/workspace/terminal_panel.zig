const dvui = @import("dvui");
const std = @import("std");

const App = @import("../../app/App.zig");
const keybindings = @import("../../app/keybindings.zig");
const ssh_session = @import("../../services/ssh_session.zig");
const terminal = @import("../../terminal/terminal.zig");
const terminal_slot = @import("../../core/terminal_slot.zig");
const workspace = @import("../../core/workspace.zig");
const theme = @import("../theme.zig");

const terminal_font_size: f32 = 10;
const terminal_line_height: f32 = 18;
const terminal_cjk_baseline_lift: f32 = 2;
const cursor_blink_period_ns: i128 = 1_000_000_000;
const cursor_blink_timer_us: i32 = 250_000;
const cursor_underline_height: f32 = 2;
const cursor_underline_lift: f32 = 2;
const min_terminal_cols: u16 = 20;
const min_terminal_rows: u16 = 5;
const scroll_rows_per_wheel_tick: f32 = 1.25;
const scrollbar_width: f32 = 4;
const scrollbar_hit_width: f32 = 14;
const scrollbar_min_thumb_height: f32 = 24;
const scrollbar_margin: f32 = 3;
const scrollbar_idle_fade_delay_ns: i128 = 3 * std.time.ns_per_s;
const scrollbar_idle_opacity: f32 = 0.35;
const ime_composition_capacity: usize = 128;
const selection_background_mix: f32 = 0.42;
const selection_background_darken: f32 = 0.72;
const paste_chunk_size: usize = 2048;
const paste_queue_capacity: usize = 512 * 1024;
const paste_queue_timer_us: i32 = 16_000;
const bracketed_paste_start = "\x1b[200~";
const bracketed_paste_end = "\x1b[201~";
const multi_click_window_ns: i128 = 500 * std.time.ns_per_ms;
const context_menu_font_size: f32 = terminal_font_size;
const context_menu_item_height: f32 = 18;
const search_query_capacity: usize = 128;
const search_max_matches: usize = 512;
const search_bar_width: f32 = 260;
const search_bar_height: f32 = 34;
const search_bar_font_size: f32 = 10;

const TerminalRun = struct {
    row: f32,
    start_col: u16,
    end_col: u16,
    style: terminal.Style,
    text: []const u8,
};

const TerminalPoint = struct {
    row: usize,
    col: u16,
};

const TerminalSelection = struct {
    anchor: TerminalPoint,
    head: TerminalPoint,
};

const TerminalSearchMatch = struct {
    row: usize,
    col: u16,
    len: u16,
};

const TerminalSearchMatches = struct {
    items: [search_max_matches]TerminalSearchMatch = undefined,
    len: usize = 0,
    overflow: bool = false,
};

const TerminalViewport = struct {
    last_size: ?terminal.Size = null,
    scroll_offset: usize = 0,
    wheel_remainder: f32 = 0,
    scrollbar_grab_y: f32 = 0,
    last_scroll_interaction_ns: i128 = 0,
    selection: ?TerminalSelection = null,
    selecting: bool = false,
    last_click_point: ?TerminalPoint = null,
    last_click_ns: i128 = 0,
    click_count: u8 = 0,
    ime_composition: [ime_composition_capacity]u8 = std.mem.zeroes([ime_composition_capacity]u8),
    ime_composition_len: usize = 0,
    search_open: bool = false,
    search_focus_requested: bool = false,
    search_scroll_to_active: bool = false,
    search_query: [search_query_capacity]u8 = std.mem.zeroes([search_query_capacity]u8),
    search_active_index: usize = 0,
    pending_paste: [paste_queue_capacity]u8 = std.mem.zeroes([paste_queue_capacity]u8),
    pending_paste_len: usize = 0,
    pending_paste_offset: usize = 0,
};

const ScrollbarGeometry = struct {
    track: dvui.Rect.Physical,
    thumb: dvui.Rect.Physical,
    hit_rect: dvui.Rect.Physical,
    max_start: usize,
    travel: f32,
};

pub const Options = struct {
    id_extra: usize,
    snapshot: ?terminal.Snapshot = null,
    failure: ?ssh_session.Error = null,
    active_slot_id: ?terminal_slot.TerminalSlotId = null,
};

pub fn show(app: *App, tab: workspace.WorkspaceTab, palette: theme.Palette, opts: Options) void {
    var panel = dvui.box(@src(), .{ .dir = .vertical }, theme.panel(.{
        .expand = .both,
        .min_size_content = .height(0),
        .padding = .{ .x = 12, .y = 10, .w = 12, .h = 10 },
        .id_extra = opts.id_extra,
    }, palette).override(.{
        .color_fill = palette.app_bg,
        .color_border = palette.border_subtle,
    }));
    defer panel.deinit();

    if (opts.snapshot) |snapshot| {
        terminalSnapshot(app, tab, snapshot, palette, terminalHostIdExtra(opts.id_extra + 1, opts.active_slot_id));
        return;
    }

    const transcript = switch (tab.status) {
        .idle => "Session is idle.\n",
        .connecting => "Connecting SSH session...\n",
        .connected => "SSH session connected. Waiting for terminal output...\n",
        .failed => failureText(opts.failure),
        .closed => "SSH session closed.\n",
    };

    terminalText(app, tab, transcript, palette, terminalHostIdExtra(opts.id_extra + 1, opts.active_slot_id));
}

fn terminalHostIdExtra(base: usize, slot_id: ?terminal_slot.TerminalSlotId) usize {
    const id = slot_id orelse return base;
    return base + @as(usize, @intCast(id % 10_000)) * 100;
}

fn failureText(failure: ?ssh_session.Error) []const u8 {
    const err = failure orelse return "SSH session failed. Check host key, credentials, network, or server status.\n";
    return switch (err) {
        error.HostKeyUnknown => "SSH host key is unknown. Confirm and trust this host before connecting.\n",
        error.HostKeyChanged => "SSH host key changed. Verify the server identity before reconnecting.\n",
        error.InvalidHostKey => "SSH host key verification failed.\n",
        error.MissingCredentials => "SSH credentials are missing. Add a password, key, or agent auth.\n",
        error.AuthenticationFailed => "SSH authentication failed. Check username, password, key, or passphrase.\n",
        error.UnsupportedAuth => "SSH auth method is not supported yet.\n",
        error.ConnectionFailed => "SSH connection failed. Check host, port, network, and server status.\n",
        error.ChannelOpenFailed => "SSH connected, but opening a terminal shell failed.\n",
        error.ChannelClosed => "SSH channel closed.\n",
        else => "SSH session failed. Check host key, credentials, network, or server status.\n",
    };
}

fn terminalText(app: *App, tab: workspace.WorkspaceTab, text: []const u8, palette: theme.Palette, id_extra: usize) void {
    var host = dvui.box(@src(), .{}, theme.panel(.{
        .expand = .both,
        .min_size_content = .height(0),
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .corner_radius = .all(0),
        .tab_index = 1,
        .id_extra = id_extra,
    }, palette).override(.{
        .color_fill = palette.app_bg,
        .color_border = palette.border_subtle,
    }));
    defer host.deinit();
    const viewport = viewportState(host.data());
    processTerminalInput(app, tab, host.data(), viewport, null);

    const crs = host.data().contentRectScale();
    syncTerminalResize(app, tab, viewport, crs);
    renderTerminalText(text, crs, palette);
}

fn terminalSnapshot(app: *App, tab: workspace.WorkspaceTab, snapshot: terminal.Snapshot, palette: theme.Palette, id_extra: usize) void {
    var host = dvui.box(@src(), .{ .dir = .vertical }, theme.panel(.{
        .expand = .both,
        .min_size_content = .height(0),
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .corner_radius = .all(0),
        .tab_index = 1,
        .id_extra = id_extra,
    }, palette).override(.{
        .color_fill = palette.app_bg,
        .color_border = palette.border_subtle,
    }));
    defer host.deinit();
    const viewport = viewportState(host.data());
    processTerminalInput(app, tab, host.data(), viewport, snapshot);
    drainPendingPaste(app, tab, host.data().id, viewport);

    const crs = host.data().contentRectScale();
    syncTerminalResize(app, tab, viewport, crs);
    clampScrollOffset(viewport, snapshot.scrollback_rows);

    const total_rows = snapshot.scrollback_rows + @as(usize, snapshot.size.rows);
    const rows = visibleRows(crs, total_rows);
    var start_row = visibleStartRow(total_rows, rows, viewport.scroll_offset);
    const search_matches = computeSearchMatches(snapshot, viewport);
    clampSearchActiveIndex(viewport, search_matches);
    if (viewport.search_scroll_to_active and search_matches.len > 0) {
        scrollToSearchMatch(viewport, crs, snapshot, search_matches.items[viewport.search_active_index]);
        viewport.search_scroll_to_active = false;
        start_row = visibleStartRow(total_rows, rows, viewport.scroll_offset);
    }
    processTerminalSelection(app, tab, host.data(), viewport, crs, snapshot, start_row, rows, total_rows);
    const old_clip = dvui.clip(crs.r);
    defer dvui.clipSet(old_clip);

    for (0..rows) |i| {
        renderTerminalSnapshotRow(snapshot, crs, viewport, search_matches, start_row + i, @as(f32, @floatFromInt(i)), palette);
    }
    renderImeComposition(snapshot, crs, start_row, rows, viewport, palette);
    renderCursor(snapshot, crs, start_row, rows, viewport.scroll_offset, palette, host.data().id);
    scrollbar(app, tab, host.data(), viewport, crs, total_rows, rows, start_row, palette);
    terminalContextMenu(app, tab, viewport, crs, snapshot, palette, id_extra + 2, host.data().id);
    terminalSearchBar(viewport, crs, snapshot, search_matches, palette, id_extra + 20, host.data().id);
}

fn renderTerminalText(text: []const u8, crs: dvui.RectScale, palette: theme.Palette) void {
    const old_clip = dvui.clip(crs.r);
    defer dvui.clipSet(old_clip);

    var line_index: usize = 0;
    const max_rows = visibleRows(crs, std.math.maxInt(u16));
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (line_index < max_rows) {
        const line = lines.next() orelse break;
        renderTerminalLine(line, crs, @as(f32, @floatFromInt(line_index)), palette);
        line_index += 1;
    }
}

fn terminalContextMenu(app: *App, tab: workspace.WorkspaceTab, viewport: *TerminalViewport, crs: dvui.RectScale, snapshot: terminal.Snapshot, palette: theme.Palette, id_extra: usize, terminal_id: dvui.Id) void {
    if (crs.r.empty()) return;

    const context = dvui.context(@src(), .{ .rect = crs.r }, .{ .id_extra = id_extra });
    defer context.deinit();

    const active_point = context.activePoint() orelse return;
    if (pointInTerminalSearchBarNatural(viewport, crs, active_point)) return;
    var menu = dvui.floatingMenu(@src(), .{ .from = .fromPoint(active_point) }, terminalContextMenuOptions(palette, id_extra + 1));
    defer menu.deinit();

    if (terminalContextMenuItem("Copy", palette, id_extra + 2)) |_| {
        copySelectionToClipboard(app.allocator, snapshot, viewport);
        menu.close();
    }
    if (terminalContextMenuItem("Paste", palette, id_extra + 3)) |_| {
        pasteClipboard(app, tab, snapshot, viewport, terminal_id);
        menu.close();
    }
    if (terminalContextMenuItem("Clear Screen", palette, id_extra + 4)) |_| {
        clearTerminalSelection(viewport);
        handleTerminalBytes(app, tab, "\x0c");
        menu.close();
    }
    if (terminalContextMenuItem("Clear History", palette, id_extra + 5)) |_| {
        clearTerminalSelection(viewport);
        viewport.scroll_offset = 0;
        app.clearTerminalScrollback(tab.id);
        menu.close();
    }
}

fn terminalContextMenuOptions(palette: theme.Palette, id_extra: usize) dvui.Options {
    return .{
        .id_extra = id_extra,
        .background = true,
        .color_fill = palette.app_bg,
        .color_border = palette.border,
        .color_text = palette.text,
        .border = .all(1),
        .padding = .all(3),
        .corner_radius = .all(3),
    };
}

fn terminalContextMenuItem(label: []const u8, palette: theme.Palette, id_extra: usize) ?dvui.Rect.Natural {
    return dvui.menuItemLabel(@src(), label, .{}, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .background = true,
        .font = theme.textFont(label, context_menu_font_size),
        .color_fill = dvui.Color.transparent,
        .color_fill_hover = palette.surface_active,
        .color_fill_press = palette.active_bg,
        .color_text = palette.text,
        .color_text_hover = palette.text,
        .color_text_press = palette.text,
        .padding = .{ .x = 8, .y = 5, .w = 8, .h = 3 },
        .min_size_content = .{ .h = context_menu_item_height },
        .corner_radius = .all(3),
    });
}

fn terminalSearchBar(viewport: *TerminalViewport, crs: dvui.RectScale, snapshot: terminal.Snapshot, matches: TerminalSearchMatches, palette: theme.Palette, id_extra: usize, terminal_id: dvui.Id) void {
    if (!viewport.search_open or crs.r.empty()) return;

    var bar = dvui.box(@src(), .{ .dir = .horizontal }, terminalSearchBarOptions(crs, palette, id_extra));
    defer bar.deinit();
    processSearchBarKeys(viewport, crs, snapshot, matches, bar.data(), terminal_id);

    var te = dvui.textEntry(@src(), .{
        .text = .{ .buffer = &viewport.search_query },
        .placeholder = "Search",
    }, terminalSearchEntryOptions(palette, id_extra + 1));
    if (viewport.search_focus_requested) {
        dvui.focusWidget(te.data().id, null, null);
        viewport.search_focus_requested = false;
    }
    const entered = te.enter_pressed;
    if (te.text_changed) {
        viewport.search_active_index = 0;
        viewport.search_scroll_to_active = terminalSearchQuery(viewport).len > 0;
    }
    te.deinit();

    if (entered) {
        gotoSearchMatch(viewport, crs, snapshot, matches, 1);
    }

    terminalSearchCountLabel(matches, viewport, palette, id_extra + 2);
    if (terminalSearchButton("↑", palette, id_extra + 3)) {
        gotoSearchMatch(viewport, crs, snapshot, matches, -1);
    }
    if (terminalSearchButton("↓", palette, id_extra + 4)) {
        gotoSearchMatch(viewport, crs, snapshot, matches, 1);
    }
    if (terminalSearchButton("x", palette, id_extra + 5)) {
        closeSearch(viewport, terminal_id);
    }
}

fn processSearchBarKeys(viewport: *TerminalViewport, crs: dvui.RectScale, snapshot: terminal.Snapshot, matches: TerminalSearchMatches, data: *dvui.WidgetData, terminal_id: dvui.Id) void {
    for (dvui.events()) |*event| {
        if (event.handled or event.evt != .key) continue;
        const key = event.evt.key;
        if (key.action != .down and key.action != .repeat) continue;
        switch (key.code) {
            .escape => {
                closeSearch(viewport, terminal_id);
                event.handle(@src(), data);
                dvui.refresh(null, @src(), terminal_id);
            },
            .enter, .kp_enter => {
                gotoSearchMatch(viewport, crs, snapshot, matches, if (key.mod.shift()) -1 else 1);
                event.handle(@src(), data);
                dvui.refresh(null, @src(), data.id);
            },
            else => {},
        }
    }
}

fn terminalSearchBarOptions(crs: dvui.RectScale, palette: theme.Palette, id_extra: usize) dvui.Options {
    return .{
        .id_extra = id_extra,
        .rect = crs.rectFromPhysical(terminalSearchBarRect(crs)),
        .background = true,
        .color_fill = palette.app_bg.opacity(0.94),
        .color_border = palette.border,
        .color_text = palette.text,
        .border = .all(1),
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .corner_radius = .all(4),
    };
}

fn terminalSearchBarRect(crs: dvui.RectScale) dvui.Rect.Physical {
    const width = @min(search_bar_width * crs.s, @max(1, crs.r.w - 16 * crs.s));
    const height = search_bar_height * crs.s;
    return .{
        .x = crs.r.x + crs.r.w - width - 10 * crs.s,
        .y = crs.r.y + 8 * crs.s,
        .w = width,
        .h = height,
    };
}

fn pointInTerminalSearchBar(viewport: *TerminalViewport, crs: dvui.RectScale, point: dvui.Point.Physical) bool {
    return viewport.search_open and !crs.r.empty() and terminalSearchBarRect(crs).contains(point);
}

fn pointInTerminalSearchBarNatural(viewport: *TerminalViewport, crs: dvui.RectScale, point: dvui.Point.Natural) bool {
    if (!viewport.search_open or crs.r.empty()) return false;
    const rect = crs.rectFromPhysical(terminalSearchBarRect(crs));
    return point.x >= rect.x and point.x <= rect.x + rect.w and point.y >= rect.y and point.y <= rect.y + rect.h;
}

fn terminalSearchEntryOptions(palette: theme.Palette, id_extra: usize) dvui.Options {
    return .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .gravity_y = 0.5,
        .min_size_content = .{ .h = 22, .w = 92 },
        .font = theme.textFont("Search", search_bar_font_size),
        .background = true,
        .color_fill = palette.surface_bg,
        .color_border = palette.border_subtle,
        .color_text = palette.text,
        .border = .all(1),
        .padding = .{ .x = 8, .y = 3, .w = 8, .h = 2 },
        .corner_radius = .all(3),
    };
}

fn terminalSearchCountLabel(matches: TerminalSearchMatches, viewport: *TerminalViewport, palette: theme.Palette, id_extra: usize) void {
    const query = terminalSearchQuery(viewport);
    var buf: [24]u8 = undefined;
    const text = if (query.len == 0)
        "0/0"
    else
        std.fmt.bufPrint(&buf, "{d}/{d}", .{ if (matches.len == 0) @as(usize, 0) else viewport.search_active_index + 1, matches.len }) catch "*/ *";
    dvui.labelNoFmt(@src(), text, .{}, .{
        .id_extra = id_extra,
        .font = theme.textFont(text, search_bar_font_size),
        .color_text = palette.muted_text,
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 42 },
    });
}

fn terminalSearchButton(label: []const u8, palette: theme.Palette, id_extra: usize) bool {
    const is_arrow = std.mem.eql(u8, label, "↑") or std.mem.eql(u8, label, "↓");
    const is_close = std.mem.eql(u8, label, "x");
    const button_height: f32 = if (is_arrow) 22 else if (is_close) 16 else 22;
    const button_width: f32 = if (is_arrow) 12 else if (is_close) 16 else 22;
    const y_padding: f32 = if (is_close) 1 else 2;
    return theme.button(@src(), label, .{
        .id_extra = id_extra,
        .gravity_y = 0.5,
        .min_size_content = .{ .w = button_width, .h = button_height },
        .padding = .{ .x = 3, .y = y_padding, .w = 3, .h = 2 },
        .corner_radius = .all(3),
        .font = theme.textFont(label, search_bar_font_size),
    }, palette, .{
        .variant = .ghost,
        .font_size = search_bar_font_size,
    });
}

fn closeSearch(viewport: *TerminalViewport, terminal_id: dvui.Id) void {
    viewport.search_open = false;
    viewport.search_focus_requested = false;
    viewport.search_scroll_to_active = false;
    @memset(&viewport.search_query, 0);
    viewport.search_active_index = 0;
    dvui.focusWidget(terminal_id, null, null);
}

fn gotoSearchMatch(viewport: *TerminalViewport, crs: dvui.RectScale, snapshot: terminal.Snapshot, matches: TerminalSearchMatches, direction: i8) void {
    if (matches.len == 0) return;
    if (direction < 0) {
        viewport.search_active_index = if (viewport.search_active_index == 0) matches.len - 1 else viewport.search_active_index - 1;
    } else {
        viewport.search_active_index = (viewport.search_active_index + 1) % matches.len;
    }
    scrollToSearchMatch(viewport, crs, snapshot, matches.items[viewport.search_active_index]);
}

fn scrollToSearchMatch(viewport: *TerminalViewport, crs: dvui.RectScale, snapshot: terminal.Snapshot, match: TerminalSearchMatch) void {
    const total_rows = snapshot.scrollback_rows + @as(usize, snapshot.size.rows);
    const rows = visibleRows(crs, total_rows);
    if (rows == 0 or total_rows <= rows) {
        viewport.scroll_offset = 0;
        return;
    }

    const max_start = total_rows - rows;
    const preferred_start = match.row -| rows / 2;
    const start_row = @min(preferred_start, max_start);
    viewport.scroll_offset = max_start - start_row;
    noteScrollInteraction(viewport);
}

fn renderTerminalLine(text: []const u8, crs: dvui.RectScale, row: f32, palette: theme.Palette) void {
    if (crs.r.empty()) return;

    const text_rect = terminalTextRect(crs, row);
    dvui.renderText(.{
        .font = theme.textFont(text, terminal_font_size),
        .text = text,
        .rs = crs,
        .p = .{
            .x = text_rect.x,
            .y = text_rect.y,
        },
        .color = palette.text,
    }) catch {};
}

fn renderTerminalSnapshotRow(snapshot: terminal.Snapshot, crs: dvui.RectScale, viewport: *TerminalViewport, search_matches: TerminalSearchMatches, absolute_row: usize, visible_row: f32, palette: theme.Palette) void {
    if (crs.r.empty()) return;

    renderTerminalBackgrounds(snapshot, crs, viewport, absolute_row, visible_row, palette);
    renderTerminalSearchHighlights(crs, search_matches, viewport.search_active_index, absolute_row, visible_row, palette);

    var run_buf: [1024]u8 = undefined;
    var col: u16 = 0;
    while (col < snapshot.size.cols) {
        const cell = snapshotDisplayCell(snapshot, absolute_row, col) orelse break;
        if (cell.width == 0 or isBlankCell(cell)) {
            col += 1;
            continue;
        }

        if (isSingleWidthAscii(cell)) {
            const run = asciiRun(snapshot, absolute_row, visible_row, col, cell.style, &run_buf);
            renderTerminalRun(run, crs, palette);
            col = run.end_col;
            continue;
        }

        var char_buf: [4]u8 = undefined;
        const text = codepointToUtf8(cell.codepoint, &char_buf);
        renderTerminalRun(.{
            .row = visible_row,
            .start_col = col,
            .end_col = @min(snapshot.size.cols, col + cellDisplayWidth(cell)),
            .style = cell.style,
            .text = text,
        }, crs, palette);
        col += cellDisplayWidth(cell);
    }
}

fn renderTerminalBackgrounds(snapshot: terminal.Snapshot, crs: dvui.RectScale, viewport: *TerminalViewport, absolute_row: usize, visible_row: f32, palette: theme.Palette) void {
    var col: u16 = 0;
    while (col < snapshot.size.cols) {
        const cell = snapshotDisplayCell(snapshot, absolute_row, col) orelse break;
        const width = @min(cellDisplayWidth(cell), snapshot.size.cols - col);
        if (cell.width != 0) {
            const selected = selectionIntersectsCell(viewport, absolute_row, col, width, snapshot.size.cols);
            if (terminalBackgroundColor(cell.style, palette)) |color| {
                const fill = if (selected) selectedTerminalBackground(color, palette) else color;
                terminalCellRect(crs, visible_row, col, width).fill(.{}, .{ .color = fill, .fade = 0 });
            } else if (selected) {
                terminalCellRect(crs, visible_row, col, width).fill(.{}, .{ .color = palette.surface_active, .fade = 0 });
            }
        }
        col += width;
    }
}

fn renderTerminalSearchHighlights(crs: dvui.RectScale, matches: TerminalSearchMatches, active_index: usize, absolute_row: usize, visible_row: f32, palette: theme.Palette) void {
    for (matches.items[0..matches.len], 0..) |match, idx| {
        if (match.row != absolute_row) continue;
        const active = idx == active_index;
        const fill = if (active)
            blendColor(palette.accent, palette.app_bg, 0.22).opacity(0.72)
        else
            blendColor(palette.accent, palette.app_bg, 0.55).opacity(0.42);
        terminalCellRect(crs, visible_row, match.col, match.len).fill(.{ .x = 1, .y = 1, .w = 1, .h = 1 }, .{ .color = fill, .fade = 0 });
    }
}

fn computeSearchMatches(snapshot: terminal.Snapshot, viewport: *TerminalViewport) TerminalSearchMatches {
    var matches = TerminalSearchMatches{};
    const query = terminalSearchQuery(viewport);
    if (query.len == 0) return matches;

    const total_rows = snapshot.scrollback_rows + @as(usize, snapshot.size.rows);
    var row: usize = 0;
    while (row < total_rows) : (row += 1) {
        appendRowSearchMatches(snapshot, row, query, &matches);
    }
    return matches;
}

fn appendRowSearchMatches(snapshot: terminal.Snapshot, row: usize, query: []const u8, matches: *TerminalSearchMatches) void {
    var text_buf: [4096]u8 = undefined;
    var byte_cols: [4096]u16 = undefined;
    var col_widths: [4096]u16 = undefined;
    var text_len: usize = 0;

    var col: u16 = 0;
    while (col < snapshot.size.cols and text_len < text_buf.len) : (col += 1) {
        const cell = snapshotDisplayCell(snapshot, row, col) orelse break;
        if (cell.width == 0) continue;

        var cp_buf: [4]u8 = undefined;
        const text = codepointToUtf8(cell.codepoint, &cp_buf);
        if (text_len + text.len > text_buf.len) break;
        for (text) |byte| {
            text_buf[text_len] = byte;
            byte_cols[text_len] = col;
            col_widths[text_len] = cellDisplayWidth(cell);
            text_len += 1;
        }
    }

    var search_start: usize = 0;
    while (search_start < text_len) {
        const found = std.mem.indexOfPos(u8, text_buf[0..text_len], search_start, query) orelse break;
        if (matches.len >= matches.items.len) {
            matches.overflow = true;
            return;
        }
        const end_byte = found + query.len -| 1;
        const start_col = byte_cols[found];
        const end_col = byte_cols[end_byte] + col_widths[end_byte];
        matches.items[matches.len] = .{
            .row = row,
            .col = start_col,
            .len = @max(@as(u16, 1), end_col -| start_col),
        };
        matches.len += 1;
        search_start = found + @max(query.len, 1);
    }
}

fn terminalSearchQuery(viewport: *TerminalViewport) []const u8 {
    return std.mem.sliceTo(viewport.search_query[0..], 0);
}

fn clampSearchActiveIndex(viewport: *TerminalViewport, matches: TerminalSearchMatches) void {
    if (matches.len == 0) {
        viewport.search_active_index = 0;
        return;
    }
    viewport.search_active_index = @min(viewport.search_active_index, matches.len - 1);
}

fn asciiRun(snapshot: terminal.Snapshot, absolute_row: usize, visible_row: f32, start_col: u16, style: terminal.Style, buffer: []u8) TerminalRun {
    var len: usize = 0;
    var col = start_col;
    while (col < snapshot.size.cols and len < buffer.len) : (col += 1) {
        const cell = snapshotDisplayCell(snapshot, absolute_row, col) orelse break;
        if (!isSingleWidthAscii(cell) or !sameStyle(cell.style, style)) break;
        buffer[len] = @intCast(cell.codepoint);
        len += 1;
    }

    return .{
        .row = visible_row,
        .start_col = start_col,
        .end_col = col,
        .style = style,
        .text = buffer[0..len],
    };
}

fn renderTerminalRun(run: TerminalRun, crs: dvui.RectScale, palette: theme.Palette) void {
    if (run.text.len == 0) return;

    const text_rect = terminalTextRect(crs, run.row);
    const cell_width = terminalCellWidth() * crs.s;
    dvui.renderText(.{
        .font = terminalFont(run.text, run.style),
        .text = run.text,
        .rs = crs,
        .p = .{
            .x = text_rect.x + @as(f32, @floatFromInt(run.start_col)) * cell_width,
            .y = text_rect.y - terminalTextBaselineLift(run.text) * crs.s,
        },
        .color = terminalForegroundColor(run.style, palette),
    }) catch {};
}

fn renderImeComposition(snapshot: terminal.Snapshot, crs: dvui.RectScale, start_row: usize, rows: usize, viewport: *TerminalViewport, palette: theme.Palette) void {
    if (viewport.ime_composition_len == 0 or rows == 0 or crs.r.empty()) return;
    if (viewport.scroll_offset != 0) return;

    const cursor_row = snapshot.scrollback_rows + @as(usize, snapshot.cursor.row);
    if (cursor_row < start_row or cursor_row >= start_row + rows) return;

    const visible_row = @as(f32, @floatFromInt(cursor_row - start_row));
    const text = viewport.ime_composition[0..viewport.ime_composition_len];
    renderTerminalRun(.{
        .row = visible_row,
        .start_col = snapshot.cursor.col,
        .end_col = snapshot.cursor.col,
        .style = .{ .underline = true },
        .text = text,
    }, crs, palette);
}

fn terminalTextBaselineLift(text: []const u8) f32 {
    return if (theme.needsCjkFont(text)) terminal_cjk_baseline_lift else 0;
}

fn selectionIntersectsCell(viewport: *TerminalViewport, absolute_row: usize, col: u16, width: u16, cols: u16) bool {
    const selection = normalizedSelection(viewport.selection) orelse return false;
    if (absolute_row < selection.anchor.row or absolute_row > selection.head.row) return false;

    var start_col: u16 = 0;
    var end_col: u16 = cols;
    if (absolute_row == selection.anchor.row) start_col = @min(selection.anchor.col, cols);
    if (absolute_row == selection.head.row) end_col = @min(selection.head.col, cols);

    const cell_start = col;
    const cell_end = @min(cols, col + width);
    return cell_start < end_col and cell_end > start_col;
}

fn terminalCellRect(crs: dvui.RectScale, row: f32, col: u16, width: u16) dvui.Rect.Physical {
    const cell_width = terminalCellWidth() * crs.s;
    const text_rect = terminalTextRect(crs, row);
    return .{
        .x = text_rect.x + @as(f32, @floatFromInt(col)) * cell_width,
        .y = text_rect.y,
        .w = @as(f32, @floatFromInt(width)) * cell_width,
        .h = text_rect.h,
    };
}

fn terminalTextRect(crs: dvui.RectScale, row: f32) dvui.Rect.Physical {
    return .{
        .x = crs.r.x,
        .y = crs.r.y + row * terminal_line_height * crs.s,
        .w = crs.r.w,
        .h = terminal_line_height * crs.s,
    };
}

fn renderCursor(snapshot: terminal.Snapshot, crs: dvui.RectScale, start_row: usize, rows: usize, scroll_offset: usize, palette: theme.Palette, id: dvui.Id) void {
    if (dvui.focusedWidgetId() != id) return;
    if (scroll_offset != 0) return;
    if (!snapshot.cursor.visible or rows == 0 or crs.r.empty()) return;

    const cursor_row = snapshot.scrollback_rows + @as(usize, snapshot.cursor.row);
    if (cursor_row < start_row or cursor_row >= start_row + rows) return;

    dvui.timer(id, cursor_blink_timer_us);
    const frame_time = dvui.frameTimeNS();
    if (@mod(@divFloor(frame_time, cursor_blink_period_ns / 2), 2) != 0) return;

    const visible_row = cursor_row - start_row;
    const cell_width = terminalCellWidth() * crs.s;
    const x = crs.r.x + @as(f32, @floatFromInt(snapshot.cursor.col)) * cell_width;
    const line_top = crs.r.y + @as(f32, @floatFromInt(visible_row)) * terminal_line_height * crs.s;
    const glyph_height = theme.textFont("M", terminal_font_size).textSize("M").h * crs.s;
    const y = line_top + glyph_height - (cursor_underline_height + cursor_underline_lift) * crs.s;
    const underline = dvui.Rect.Physical{
        .x = x,
        .y = y,
        .w = @max(1, cell_width * 0.8),
        .h = @max(1, cursor_underline_height * crs.s),
    };
    underline.fill(.{}, .{ .color = palette.text, .fade = 0 });
}

fn scrollbar(
    app: *App,
    tab: workspace.WorkspaceTab,
    data: *dvui.WidgetData,
    viewport: *TerminalViewport,
    crs: dvui.RectScale,
    total_rows: usize,
    visible_rows: usize,
    start_row: usize,
    palette: theme.Palette,
) void {
    _ = app;
    _ = tab;
    const geometry = scrollbarGeometry(crs, total_rows, visible_rows, start_row) orelse return;
    processScrollbarEvents(data, viewport, crs, geometry);

    const track_color = scrollbarColor(palette.border_subtle, viewport);
    const thumb_color = scrollbarColor(palette.text_subtle, viewport);
    geometry.track.fill(.{ .x = geometry.track.w / 2, .y = geometry.track.w / 2, .w = geometry.track.w / 2, .h = geometry.track.w / 2 }, .{ .color = track_color, .fade = 0 });
    geometry.thumb.fill(.{ .x = geometry.thumb.w / 2, .y = geometry.thumb.w / 2, .w = geometry.thumb.w / 2, .h = geometry.thumb.w / 2 }, .{ .color = thumb_color, .fade = 0 });
}

fn scrollbarColor(color: dvui.Color, viewport: *TerminalViewport) dvui.Color {
    if (!scrollbarActive(viewport)) return color.opacity(scrollbar_idle_opacity);
    return color;
}

fn scrollbarActive(viewport: *TerminalViewport) bool {
    if (viewport.last_scroll_interaction_ns == 0) return false;
    return dvui.frameTimeNS() - viewport.last_scroll_interaction_ns <= scrollbar_idle_fade_delay_ns;
}

fn scrollbarGeometry(crs: dvui.RectScale, total_rows: usize, visible_rows: usize, start_row: usize) ?ScrollbarGeometry {
    if (crs.r.empty() or total_rows <= visible_rows or visible_rows == 0) return null;

    const width = scrollbar_width * crs.s;
    const margin = scrollbar_margin * crs.s;
    const track = dvui.Rect.Physical{
        .x = crs.r.x + crs.r.w - width - margin,
        .y = crs.r.y + margin,
        .w = width,
        .h = @max(1, crs.r.h - margin * 2),
    };
    if (track.h <= 0) return null;

    const total_float = @as(f32, @floatFromInt(total_rows));
    const visible_float = @as(f32, @floatFromInt(visible_rows));
    const max_start = total_rows - visible_rows;
    const thumb_h = @max(scrollbar_min_thumb_height * crs.s, track.h * visible_float / total_float);
    const travel = @max(0, track.h - thumb_h);
    const fraction = if (max_start == 0) 1 else @as(f32, @floatFromInt(start_row)) / @as(f32, @floatFromInt(max_start));
    const thumb = dvui.Rect.Physical{
        .x = track.x,
        .y = track.y + travel * fraction,
        .w = track.w,
        .h = thumb_h,
    };
    const extra = @max(0, (scrollbar_hit_width * crs.s - width) / 2);

    return .{
        .track = track,
        .thumb = thumb,
        .hit_rect = track.outset(.{ .x = extra, .w = extra }),
        .max_start = max_start,
        .travel = travel,
    };
}

fn processScrollbarEvents(data: *dvui.WidgetData, viewport: *TerminalViewport, crs: dvui.RectScale, geometry: ScrollbarGeometry) void {
    for (dvui.events()) |*event| {
        if (!dvui.eventMatch(event, .{ .id = data.id, .r = geometry.hit_rect })) continue;
        switch (event.evt) {
            .mouse => |mouse| if (!dvui.captured(data.id) and pointInTerminalSearchBar(viewport, crs, mouse.p)) continue,
            else => {},
        }

        switch (event.evt) {
            .mouse => |mouse| {
                if (mouse.action == .press and mouse.button.pointer()) {
                    event.handle(@src(), data);
                    noteScrollInteraction(viewport);
                    dvui.focusWidget(data.id, null, event.num);
                    dvui.captureMouse(data, event.num);
                    if (geometry.thumb.contains(mouse.p)) {
                        viewport.scrollbar_grab_y = mouse.p.y - geometry.thumb.y;
                    } else {
                        viewport.scrollbar_grab_y = geometry.thumb.h / 2;
                        viewport.scroll_offset = scrollOffsetFromThumbY(mouse.p.y - viewport.scrollbar_grab_y, geometry);
                    }
                    dvui.dragPreStart(mouse.p, .{ .cursor = .hand });
                    dvui.refresh(null, @src(), data.id);
                } else if (mouse.action == .release and mouse.button.pointer()) {
                    event.handle(@src(), data);
                    noteScrollInteraction(viewport);
                    dvui.captureMouse(null, event.num);
                    dvui.dragEnd();
                } else if (mouse.action == .motion and dvui.captured(data.id)) {
                    event.handle(@src(), data);
                    if (dvui.dragging(mouse.p, null) != null) {
                        noteScrollInteraction(viewport);
                        viewport.scroll_offset = scrollOffsetFromThumbY(mouse.p.y - viewport.scrollbar_grab_y, geometry);
                        dvui.refresh(null, @src(), data.id);
                    }
                } else if (mouse.action == .position) {
                    dvui.cursorSet(.hand);
                }
            },
            else => {},
        }
    }
}

fn processTerminalSelection(
    app: *App,
    tab: workspace.WorkspaceTab,
    data: *dvui.WidgetData,
    viewport: *TerminalViewport,
    crs: dvui.RectScale,
    snapshot: terminal.Snapshot,
    start_row: usize,
    visible_rows: usize,
    total_rows: usize,
) void {
    if (crs.r.empty() or visible_rows == 0 or total_rows == 0) return;

    for (dvui.events()) |*event| {
        if (!dvui.eventMatch(event, .{ .id = data.id, .r = crs.r })) continue;
        switch (event.evt) {
            .mouse => |mouse| if (!dvui.captured(data.id) and pointInTerminalSearchBar(viewport, crs, mouse.p)) continue,
            else => {},
        }

        switch (event.evt) {
            .mouse => |mouse| switch (mouse.action) {
                .press => {
                    if (pointInScrollbarHit(mouse.p, crs, total_rows, visible_rows, start_row)) continue;
                    if (terminalMouseReportingActive(snapshot)) {
                        const button = terminalMouseButtonFromDvui(mouse.button) orelse continue;
                        reportTerminalMouseButton(app, tab, snapshot, crs, start_row, visible_rows, total_rows, mouse.p, button, mouse.mod, true);
                        event.handle(@src(), data);
                        dvui.focusWidget(data.id, null, event.num);
                        dvui.captureMouse(data, event.num);
                        dvui.refresh(null, @src(), data.id);
                        continue;
                    }
                    if (mouse.button == .right) continue;
                    if (!mouse.button.pointer()) continue;
                    const point = terminalPointFromMouse(mouse.p, crs, snapshot, start_row, visible_rows, total_rows);
                    const click_count = terminalClickCount(viewport, point);
                    if (click_count >= 3) {
                        selectTerminalLine(viewport, snapshot, point.row);
                        viewport.selecting = false;
                    } else if (click_count == 2) {
                        selectTerminalWord(viewport, snapshot, point);
                        viewport.selecting = false;
                    } else {
                        viewport.selection = .{ .anchor = point, .head = point };
                        viewport.selecting = true;
                    }
                    event.handle(@src(), data);
                    dvui.focusWidget(data.id, null, event.num);
                    dvui.captureMouse(data, event.num);
                    if (viewport.selecting) dvui.dragPreStart(mouse.p, .{ .cursor = .ibeam });
                    dvui.refresh(null, @src(), data.id);
                },
                .release => {
                    if (terminalMouseReportingActive(snapshot) and dvui.captured(data.id)) {
                        const button = terminalMouseButtonFromDvui(mouse.button) orelse continue;
                        reportTerminalMouseButton(app, tab, snapshot, crs, start_row, visible_rows, total_rows, mouse.p, button, mouse.mod, false);
                        event.handle(@src(), data);
                        dvui.captureMouse(null, event.num);
                        dvui.refresh(null, @src(), data.id);
                        continue;
                    }
                    if (mouse.button.pointer() and dvui.captured(data.id) and !viewport.selecting) {
                        event.handle(@src(), data);
                        dvui.captureMouse(null, event.num);
                        dvui.refresh(null, @src(), data.id);
                        continue;
                    }
                    if (!mouse.button.pointer() or !viewport.selecting) continue;
                    viewport.selecting = false;
                    event.handle(@src(), data);
                    dvui.captureMouse(null, event.num);
                    dvui.dragEnd();
                    clearEmptySelection(viewport);
                    dvui.refresh(null, @src(), data.id);
                },
                .motion => {
                    if (terminalMouseReportingActive(snapshot) and dvui.captured(data.id)) {
                        reportTerminalMouseMove(app, tab, snapshot, crs, start_row, visible_rows, total_rows, mouse.p, mouse.mod);
                        event.handle(@src(), data);
                        dvui.refresh(null, @src(), data.id);
                        continue;
                    }
                    if (!viewport.selecting or !dvui.captured(data.id)) continue;
                    if (dvui.dragging(mouse.p, null) != null) {
                        const point = terminalPointFromMouse(mouse.p, crs, snapshot, start_row, visible_rows, total_rows);
                        if (viewport.selection) |*selection| selection.head = point;
                        event.handle(@src(), data);
                        dvui.refresh(null, @src(), data.id);
                    }
                },
                .position => {
                    if (terminalMouseReportingActive(snapshot)) {
                        dvui.cursorSet(.arrow);
                    } else if (!pointInScrollbarHit(mouse.p, crs, total_rows, visible_rows, start_row)) {
                        dvui.cursorSet(.ibeam);
                    }
                },
                else => {},
            },
            else => {},
        }
    }
}

fn terminalMouseReportingActive(snapshot: terminal.Snapshot) bool {
    return snapshot.mouse_mode != .none;
}

fn terminalMouseButtonFromDvui(button: dvui.enums.Button) ?u8 {
    return switch (button) {
        .left => 1,
        .middle => 2,
        .right => 3,
        else => null,
    };
}

fn terminalMouseModifiersFromDvui(modifiers: dvui.enums.Mod) terminal.MouseModifiers {
    return .{
        .shift = modifiers.shift(),
        .alt = modifiers.alt(),
        .control = modifiers.control(),
    };
}

fn handleTerminalMouseWheel(app: *App, tab: workspace.WorkspaceTab, snapshot: terminal.Snapshot, crs: dvui.RectScale, ticks: f32, point: dvui.Point.Physical, modifiers: terminal.MouseModifiers) void {
    const wheel_steps = @max(@as(usize, 1), @min(@as(usize, 3), @as(usize, @intFromFloat(@ceil(@abs(ticks) / 50)))));
    const button: u8 = if (ticks > 0) 4 else 5;
    const screen_point = terminalScreenPointFromMouse(point, crs, snapshot, 0, visibleRows(crs, @as(usize, snapshot.size.rows)), @as(usize, snapshot.size.rows));
    for (0..wheel_steps) |_| {
        app.sendTerminalMouse(tab.id, .{ .button = .{
            .row = @intCast(screen_point.row),
            .col = screen_point.col,
            .button = button,
            .pressed = true,
            .modifiers = modifiers,
        } });
    }
}

fn reportTerminalMouseButton(
    app: *App,
    tab: workspace.WorkspaceTab,
    snapshot: terminal.Snapshot,
    crs: dvui.RectScale,
    start_row: usize,
    visible_rows: usize,
    total_rows: usize,
    point: dvui.Point.Physical,
    button: u8,
    modifiers: dvui.enums.Mod,
    pressed: bool,
) void {
    const screen_point = terminalScreenPointFromMouse(point, crs, snapshot, start_row, visible_rows, total_rows);
    app.sendTerminalMouse(tab.id, .{ .button = .{
        .row = @intCast(screen_point.row),
        .col = screen_point.col,
        .button = button,
        .pressed = pressed,
        .modifiers = terminalMouseModifiersFromDvui(modifiers),
    } });
}

fn reportTerminalMouseMove(
    app: *App,
    tab: workspace.WorkspaceTab,
    snapshot: terminal.Snapshot,
    crs: dvui.RectScale,
    start_row: usize,
    visible_rows: usize,
    total_rows: usize,
    point: dvui.Point.Physical,
    modifiers: dvui.enums.Mod,
) void {
    const screen_point = terminalScreenPointFromMouse(point, crs, snapshot, start_row, visible_rows, total_rows);
    app.sendTerminalMouse(tab.id, .{ .move = .{
        .row = @intCast(screen_point.row),
        .col = screen_point.col,
        .modifiers = terminalMouseModifiersFromDvui(modifiers),
    } });
}

fn terminalPointFromMouse(mouse: dvui.Point.Physical, crs: dvui.RectScale, snapshot: terminal.Snapshot, start_row: usize, visible_rows: usize, total_rows: usize) TerminalPoint {
    const rel_x = std.math.clamp(mouse.x - crs.r.x, 0, @max(0, crs.r.w));
    const rel_y = std.math.clamp(mouse.y - crs.r.y, 0, @max(0, crs.r.h));
    const row_delta: usize = @intFromFloat(@min(@floor(rel_y / (terminal_line_height * crs.s)), @as(f32, @floatFromInt(visible_rows -| 1))));
    const absolute_row = @min(total_rows -| 1, start_row + row_delta);
    const col_float = @floor(rel_x / (terminalCellWidth() * crs.s));
    const col: u16 = @intFromFloat(@min(col_float, @as(f32, @floatFromInt(snapshot.size.cols))));
    return .{ .row = absolute_row, .col = col };
}

fn terminalScreenPointFromMouse(mouse: dvui.Point.Physical, crs: dvui.RectScale, snapshot: terminal.Snapshot, start_row: usize, visible_rows: usize, total_rows: usize) TerminalPoint {
    const point = terminalPointFromMouse(mouse, crs, snapshot, start_row, visible_rows, total_rows);
    const screen_row = point.row -| snapshot.scrollback_rows;
    return .{
        .row = @min(screen_row, @as(usize, snapshot.size.rows -| 1)),
        .col = @min(point.col, snapshot.size.cols -| 1),
    };
}

fn pointInScrollbarHit(point: dvui.Point.Physical, crs: dvui.RectScale, total_rows: usize, visible_rows: usize, start_row: usize) bool {
    const geometry = scrollbarGeometry(crs, total_rows, visible_rows, start_row) orelse return false;
    return geometry.hit_rect.contains(point);
}

fn clearEmptySelection(viewport: *TerminalViewport) void {
    const selection = viewport.selection orelse return;
    if (selection.anchor.row == selection.head.row and selection.anchor.col == selection.head.col) {
        viewport.selection = null;
    }
}

fn clearTerminalSelection(viewport: *TerminalViewport) void {
    viewport.selection = null;
    viewport.selecting = false;
}

fn terminalClickCount(viewport: *TerminalViewport, point: TerminalPoint) u8 {
    const now = dvui.frameTimeNS();
    const same_point = if (viewport.last_click_point) |last| last.row == point.row and last.col == point.col else false;
    if (same_point and now - viewport.last_click_ns <= multi_click_window_ns) {
        viewport.click_count = @min(viewport.click_count + 1, 3);
    } else {
        viewport.click_count = 1;
    }
    viewport.last_click_point = point;
    viewport.last_click_ns = now;
    return viewport.click_count;
}

fn selectTerminalWord(viewport: *TerminalViewport, snapshot: terminal.Snapshot, point: TerminalPoint) void {
    const cols = snapshot.size.cols;
    if (cols == 0) return;
    if (!isWordSelectionCell(snapshotDisplayCell(snapshot, point.row, @min(point.col, cols - 1)))) {
        viewport.selection = .{ .anchor = point, .head = point };
        return;
    }

    var start = @min(point.col, cols - 1);
    while (start > 0 and isWordSelectionCell(snapshotDisplayCell(snapshot, point.row, start - 1))) {
        start -= 1;
    }

    var end = @min(point.col, cols - 1);
    while (end < cols and isWordSelectionCell(snapshotDisplayCell(snapshot, point.row, end))) {
        end += 1;
    }

    viewport.selection = .{
        .anchor = .{ .row = point.row, .col = start },
        .head = .{ .row = point.row, .col = end },
    };
}

fn selectTerminalLine(viewport: *TerminalViewport, snapshot: terminal.Snapshot, row: usize) void {
    viewport.selection = .{
        .anchor = .{ .row = row, .col = 0 },
        .head = .{ .row = row, .col = trimmedLineEnd(snapshot, row) },
    };
}

fn trimmedLineEnd(snapshot: terminal.Snapshot, row: usize) u16 {
    var end = snapshot.size.cols;
    while (end > 0) {
        const cell = snapshotDisplayCell(snapshot, row, end - 1) orelse break;
        if (!isBlankCell(cell)) break;
        end -= 1;
    }
    return end;
}

fn isWordSelectionCell(cell: ?terminal.Cell) bool {
    const c = cell orelse return false;
    if (c.width == 0 or isBlankCell(c)) return false;
    return switch (c.codepoint) {
        ' ', '\t', '\r', '\n' => false,
        else => true,
    };
}

fn normalizedSelection(selection: ?TerminalSelection) ?TerminalSelection {
    const sel = selection orelse return null;
    if (pointLessThan(sel.head, sel.anchor)) {
        return .{ .anchor = sel.head, .head = sel.anchor };
    }
    return sel;
}

fn pointLessThan(a: TerminalPoint, b: TerminalPoint) bool {
    return a.row < b.row or (a.row == b.row and a.col < b.col);
}

fn scrollOffsetFromThumbY(y: f32, geometry: ScrollbarGeometry) usize {
    if (geometry.travel <= 0) return 0;
    const thumb_y = std.math.clamp(y - geometry.track.y, 0, geometry.travel);
    const start_row_float = thumb_y / geometry.travel * @as(f32, @floatFromInt(geometry.max_start));
    const start_row: usize = @intFromFloat(@round(start_row_float));
    return geometry.max_start - @min(start_row, geometry.max_start);
}

fn viewportState(data: *dvui.WidgetData) *TerminalViewport {
    return dvui.dataGetPtrDefault(null, data.id, "viewport", TerminalViewport, .{});
}

fn syncTerminalResize(app: *App, tab: workspace.WorkspaceTab, viewport: *TerminalViewport, crs: dvui.RectScale) void {
    if (tab.session_type != .ssh) return;
    const size = terminalGridSize(crs) orelse return;
    if (sameTerminalSize(viewport.last_size, size)) return;

    viewport.last_size = size;
    app.resizeTerminal(tab.id, .{
        .cols = size.cols,
        .rows = size.rows,
    });
}

fn terminalGridSize(crs: dvui.RectScale) ?terminal.Size {
    if (crs.r.empty() or crs.s <= 0) return null;

    const width = crs.r.w / crs.s;
    const height = crs.r.h / crs.s;
    if (width <= 0 or height <= 0) return null;

    return .{
        .cols = dimensionToCells(width / terminalCellWidth(), min_terminal_cols),
        .rows = dimensionToCells(height / terminal_line_height, min_terminal_rows),
    };
}

fn terminalCellWidth() f32 {
    return @max(theme.textFont("M", terminal_font_size).textSize("M").w, terminal_font_size * 0.6);
}

fn dimensionToCells(value: f32, min: u16) u16 {
    if (value <= @as(f32, @floatFromInt(min))) return min;
    const floored = @floor(value);
    const max_u16_float = @as(f32, @floatFromInt(std.math.maxInt(u16)));
    return @intFromFloat(@min(floored, max_u16_float));
}

fn sameTerminalSize(a: ?terminal.Size, b: terminal.Size) bool {
    const existing = a orelse return false;
    return existing.cols == b.cols and existing.rows == b.rows;
}

fn visibleRows(crs: dvui.RectScale, max_rows: usize) usize {
    if (max_rows == 0 or crs.r.h <= 0 or crs.s <= 0) return 0;

    const row_height = terminal_line_height * crs.s;
    if (row_height <= 0) return 0;

    const capacity_float = @floor(crs.r.h / row_height);
    if (capacity_float <= 0) return 1;

    const capacity: usize = @intFromFloat(@min(capacity_float, @as(f32, @floatFromInt(std.math.maxInt(u16)))));
    return @min(max_rows, capacity);
}

fn visibleStartRow(total_rows: usize, rows: usize, scroll_offset: usize) usize {
    if (total_rows <= rows) return 0;
    const max_start = total_rows - rows;
    const offset = @min(scroll_offset, max_start);
    return max_start - offset;
}

fn processTerminalInput(app: *App, tab: workspace.WorkspaceTab, data: *dvui.WidgetData, viewport: *TerminalViewport, snapshot: ?terminal.Snapshot) void {
    if (tab.session_type != .ssh) return;

    dvui.tabIndexSet(data.id, data.options.tab_index, data.rectScale().r);
    if (dvui.focusedWidgetId() == data.id) {
        dvui.wantTextInput(terminalTextInputRect(data, snapshot, viewport).toNatural());
    }

    for (dvui.events()) |*event| {
        if (!dvui.eventMatchSimple(event, data)) continue;
        switch (event.evt) {
            .mouse => |mouse| if (pointInTerminalSearchBar(viewport, data.contentRectScale(), mouse.p)) continue,
            else => {},
        }

        switch (event.evt) {
            .mouse => |mouse| switch (mouse.action) {
                .focus => {
                    event.handle(@src(), data);
                    dvui.focusWidget(data.id, null, event.num);
                },
                .wheel_y => |ticks| {
                    if (snapshot != null and terminalMouseReportingActive(snapshot.?)) {
                        handleTerminalMouseWheel(app, tab, snapshot.?, data.contentRectScale(), ticks, mouse.p, terminalMouseModifiersFromDvui(mouse.mod));
                    } else if (snapshot != null and snapshot.?.alternate_screen) {
                        handleAlternateScreenWheel(app, tab, viewport, ticks);
                    } else {
                        updateScrollOffset(viewport, ticks);
                    }
                    noteScrollInteraction(viewport);
                    event.handle(@src(), data);
                    dvui.refresh(null, @src(), data.id);
                },
                else => {},
            },
            .text => |text| switch (text.action) {
                .value => |value| {
                    if (value.selected) {
                        setImeComposition(viewport, value.txt);
                        event.handle(@src(), data);
                        dvui.refresh(null, @src(), data.id);
                        continue;
                    }
                    clearImeComposition(viewport);
                    clearTerminalSelection(viewport);
                    viewport.scroll_offset = 0;
                    handleTerminalBytes(app, tab, value.txt);
                    event.handle(@src(), data);
                },
                else => {},
            },
            .key => |key| {
                if (key.action == .up) continue;
                if (key.action == .down) {
                    if (handleTerminalShortcut(app, tab, key, snapshot, viewport, data.id)) {
                        event.handle(@src(), data);
                        dvui.refresh(null, @src(), data.id);
                        continue;
                    }
                }
                if (handleTerminalKey(app, tab, key)) {
                    viewport.scroll_offset = 0;
                    clearTerminalSelection(viewport);
                    event.handle(@src(), data);
                }
            },
            else => {},
        }
    }
}

fn noteScrollInteraction(viewport: *TerminalViewport) void {
    viewport.last_scroll_interaction_ns = dvui.frameTimeNS();
}

fn terminalTextInputRect(data: *dvui.WidgetData, snapshot: ?terminal.Snapshot, viewport: *TerminalViewport) dvui.Rect.Physical {
    const fallback = data.borderRectScale().r;
    const snap = snapshot orelse return fallback;
    if (viewport.scroll_offset != 0 or !snap.cursor.visible) return fallback;

    const crs = data.contentRectScale();
    if (crs.r.empty()) return fallback;

    const total_rows = snap.scrollback_rows + @as(usize, snap.size.rows);
    const rows = visibleRows(crs, total_rows);
    if (rows == 0) return fallback;

    const start_row = visibleStartRow(total_rows, rows, viewport.scroll_offset);
    const cursor_row = snap.scrollback_rows + @as(usize, snap.cursor.row);
    if (cursor_row < start_row or cursor_row >= start_row + rows) return fallback;

    return terminalCellRect(crs, @as(f32, @floatFromInt(cursor_row - start_row)), snap.cursor.col, 1);
}

fn setImeComposition(viewport: *TerminalViewport, text: []const u8) void {
    const len = @min(text.len, viewport.ime_composition.len);
    @memcpy(viewport.ime_composition[0..len], text[0..len]);
    viewport.ime_composition_len = len;
}

fn clearImeComposition(viewport: *TerminalViewport) void {
    viewport.ime_composition_len = 0;
}

fn updateScrollOffset(viewport: *TerminalViewport, ticks: f32) void {
    const lines = wheelTicksToRows(viewport, ticks);
    if (lines == 0) return;
    if (ticks > 0) {
        viewport.scroll_offset +|= lines;
    } else {
        viewport.scroll_offset -|= lines;
    }
}

fn wheelTicksToRows(viewport: *TerminalViewport, ticks: f32) usize {
    viewport.wheel_remainder += @abs(ticks) / 50 * scroll_rows_per_wheel_tick;
    if (viewport.wheel_remainder < 1) return 0;

    const real_rows: usize = @intFromFloat(@floor(viewport.wheel_remainder));
    const rows: usize = @min(real_rows, 2);
    viewport.wheel_remainder -= @as(f32, @floatFromInt(rows));
    return rows;
}

fn clampScrollOffset(viewport: *TerminalViewport, max_rows: usize) void {
    viewport.scroll_offset = @min(viewport.scroll_offset, max_rows);
}

fn handleTerminalShortcut(app: *App, tab: workspace.WorkspaceTab, key: dvui.Event.Key, snapshot: ?terminal.Snapshot, viewport: *TerminalViewport, terminal_id: dvui.Id) bool {
    const shortcut = keybindings.terminalShortcut(key) orelse return false;
    switch (shortcut) {
        .copy_selection => {
            const snap = snapshot orelse return true;
            copySelectionToClipboard(app.allocator, snap, viewport);
        },
        .paste_clipboard => {
            pasteClipboard(app, tab, snapshot, viewport, terminal_id);
        },
        .terminal_search => {
            viewport.search_open = true;
            viewport.search_focus_requested = true;
        },
    }
    return true;
}

fn handleAlternateScreenWheel(app: *App, tab: workspace.WorkspaceTab, viewport: *TerminalViewport, ticks: f32) void {
    const lines = wheelTicksToRows(viewport, ticks);
    if (lines == 0) return;

    const bytes = if (ticks > 0) "\x1b[A" else "\x1b[B";
    for (0..lines) |_| {
        handleTerminalBytes(app, tab, bytes);
    }
}

fn pasteClipboard(app: *App, tab: workspace.WorkspaceTab, snapshot: ?terminal.Snapshot, viewport: *TerminalViewport, terminal_id: dvui.Id) void {
    const text = dvui.clipboardText();
    if (text.len == 0) return;
    queuePasteText(app, tab, viewport, terminal_id, text, if (snapshot) |snap| snap.bracketed_paste else false);
}

fn queuePasteText(app: *App, tab: workspace.WorkspaceTab, viewport: *TerminalViewport, terminal_id: dvui.Id, text: []const u8, bracketed: bool) void {
    if (text.len == 0) return;
    viewport.scroll_offset = 0;
    const paste_len = text.len + if (bracketed) bracketed_paste_start.len + bracketed_paste_end.len else 0;
    if (paste_len > paste_queue_capacity) {
        clearPendingPaste(viewport);
        app.message = "Clipboard text is too large to paste";
        return;
    }

    clearPendingPaste(viewport);
    if (bracketed) appendPendingPaste(viewport, bracketed_paste_start);
    appendPendingPaste(viewport, text);
    if (bracketed) appendPendingPaste(viewport, bracketed_paste_end);
    drainPendingPaste(app, tab, terminal_id, viewport);
}

fn appendPendingPaste(viewport: *TerminalViewport, bytes: []const u8) void {
    if (bytes.len == 0) return;
    const end = viewport.pending_paste_len + bytes.len;
    std.debug.assert(end <= viewport.pending_paste.len);
    @memcpy(viewport.pending_paste[viewport.pending_paste_len..end], bytes);
    viewport.pending_paste_len = end;
}

fn drainPendingPaste(app: *App, tab: workspace.WorkspaceTab, terminal_id: dvui.Id, viewport: *TerminalViewport) void {
    if (viewport.pending_paste_offset >= viewport.pending_paste_len) {
        clearPendingPaste(viewport);
        return;
    }
    if (tab.status == .failed or tab.status == .closed) {
        clearPendingPaste(viewport);
        app.reconnectTab(tab.id);
        return;
    }
    if (tab.status != .connected) return;

    const end = @min(viewport.pending_paste_len, viewport.pending_paste_offset + paste_chunk_size);
    app.sendTerminalBytes(tab.id, viewport.pending_paste[viewport.pending_paste_offset..end]);
    viewport.pending_paste_offset = end;
    if (viewport.pending_paste_offset >= viewport.pending_paste_len) {
        clearPendingPaste(viewport);
    } else {
        dvui.timer(terminal_id, paste_queue_timer_us);
        dvui.refresh(null, @src(), terminal_id);
    }
}

fn clearPendingPaste(viewport: *TerminalViewport) void {
    viewport.pending_paste_len = 0;
    viewport.pending_paste_offset = 0;
}

fn copySelectionToClipboard(allocator: std.mem.Allocator, snapshot: terminal.Snapshot, viewport: *TerminalViewport) void {
    const text = selectedText(allocator, snapshot, viewport) catch return;
    defer allocator.free(text);
    if (text.len > 0) dvui.clipboardTextSet(text);
}

fn selectedText(allocator: std.mem.Allocator, snapshot: terminal.Snapshot, viewport: *TerminalViewport) ![]u8 {
    const selection = normalizedSelection(viewport.selection) orelse return allocator.dupe(u8, "");

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    const cols = snapshot.size.cols;
    var row = selection.anchor.row;
    while (row <= selection.head.row) : (row += 1) {
        const line_start = output.items.len;
        const start_col: u16 = if (row == selection.anchor.row) @min(selection.anchor.col, cols) else 0;
        const end_col: u16 = if (row == selection.head.row) @min(selection.head.col, cols) else cols;

        var col = start_col;
        while (col < end_col) : (col += 1) {
            const cell = snapshotDisplayCell(snapshot, row, col) orelse break;
            if (cell.width == 0) continue;
            try appendCodepointUtf8(allocator, &output, cell.codepoint);
        }

        trimSelectionLine(&output, line_start);
        if (row != selection.head.row) try output.append(allocator, '\n');
    }

    return output.toOwnedSlice(allocator);
}

fn snapshotDisplayCell(snapshot: terminal.Snapshot, row: usize, col: u16) ?terminal.Cell {
    if (row < snapshot.scrollback_rows) {
        return snapshot.scrollbackCellAt(row, col);
    }
    return snapshot.cellAt(@intCast(row - snapshot.scrollback_rows), col);
}

fn appendCodepointUtf8(allocator: std.mem.Allocator, output: *std.ArrayList(u8), cp: u21) !void {
    var buffer: [4]u8 = undefined;
    const text = codepointToUtf8(cp, &buffer);
    try output.appendSlice(allocator, text);
}

fn codepointToUtf8(cp: u21, buffer: *[4]u8) []const u8 {
    const printable = if (cp == 0) ' ' else cp;
    const len = std.unicode.utf8Encode(printable, buffer) catch {
        const replacement = std.unicode.replacement_character_utf8;
        @memcpy(buffer[0..replacement.len], replacement[0..]);
        return buffer[0..replacement.len];
    };
    return buffer[0..len];
}

fn trimSelectionLine(output: *std.ArrayList(u8), line_start: usize) void {
    while (output.items.len > line_start and std.ascii.isWhitespace(output.items[output.items.len - 1])) {
        output.shrinkRetainingCapacity(output.items.len - 1);
    }
}

fn isBlankCell(cell: terminal.Cell) bool {
    return cell.codepoint == ' ';
}

fn isSingleWidthAscii(cell: terminal.Cell) bool {
    return cell.width == 1 and cell.codepoint >= 0x20 and cell.codepoint <= 0x7e;
}

fn cellDisplayWidth(cell: terminal.Cell) u16 {
    return @max(@as(u16, cell.width), 1);
}

fn sameStyle(a: terminal.Style, b: terminal.Style) bool {
    return std.meta.eql(a, b);
}

fn terminalFont(text: []const u8, style: terminal.Style) dvui.Font {
    var font = theme.textFont(text, terminal_font_size);
    if (style.bold) font = font.withWeight(.bold);
    if (style.italic) font = font.withStyle(.italic);
    if (style.underline) font = font.withUnderline(.{});
    if (style.strike) font = font.withStrike(.{});
    return font;
}

fn terminalForegroundColor(style: terminal.Style, palette: theme.Palette) dvui.Color {
    if (style.reverse) {
        return terminalBackgroundColorValue(style, palette) orelse palette.app_bg;
    }
    return terminalColor(style.fg, palette.text);
}

fn terminalBackgroundColor(style: terminal.Style, palette: theme.Palette) ?dvui.Color {
    if (style.reverse) {
        return terminalColor(style.fg, palette.text);
    }
    return terminalBackgroundColorValue(style, palette);
}

fn terminalBackgroundColorValue(style: terminal.Style, palette: theme.Palette) ?dvui.Color {
    return switch (style.bg) {
        .default => null,
        else => terminalColor(style.bg, palette.app_bg),
    };
}

fn selectedTerminalBackground(background: dvui.Color, palette: theme.Palette) dvui.Color {
    return darkenColor(blendColor(background, palette.surface_active, selection_background_mix), selection_background_darken);
}

fn blendColor(a: dvui.Color, b: dvui.Color, t: f32) dvui.Color {
    return .{
        .r = blendChannel(a.r, b.r, t),
        .g = blendChannel(a.g, b.g, t),
        .b = blendChannel(a.b, b.b, t),
        .a = blendChannel(a.a, b.a, t),
    };
}

fn blendChannel(a: u8, b: u8, t: f32) u8 {
    const af = @as(f32, @floatFromInt(a));
    const bf = @as(f32, @floatFromInt(b));
    return @intFromFloat(std.math.clamp(af + (bf - af) * t, 0, 255));
}

fn darkenColor(color: dvui.Color, factor: f32) dvui.Color {
    return .{
        .r = darkenChannel(color.r, factor),
        .g = darkenChannel(color.g, factor),
        .b = darkenChannel(color.b, factor),
        .a = color.a,
    };
}

fn darkenChannel(value: u8, factor: f32) u8 {
    return @intFromFloat(std.math.clamp(@as(f32, @floatFromInt(value)) * factor, 0, 255));
}

fn terminalColor(color: terminal.Color, default_color: dvui.Color) dvui.Color {
    return switch (color) {
        .default => default_color,
        .rgb => |rgb| .{ .r = rgb.r, .g = rgb.g, .b = rgb.b },
        .indexed => |index| indexedTerminalColor(index),
    };
}

fn indexedTerminalColor(index: u8) dvui.Color {
    if (index < 16) return ansi16[index];
    if (index >= 16 and index <= 231) {
        const n = index - 16;
        return .{
            .r = colorCubeValue(n / 36),
            .g = colorCubeValue((n / 6) % 6),
            .b = colorCubeValue(n % 6),
        };
    }
    if (index >= 232) {
        const value: u8 = 8 + (index - 232) * 10;
        return .{ .r = value, .g = value, .b = value };
    }
    return .{};
}

fn colorCubeValue(component: u8) u8 {
    return if (component == 0) 0 else 55 + component * 40;
}

const ansi16 = [_]dvui.Color{
    .{ .r = 0x1e, .g = 0x1e, .b = 0x1e },
    .{ .r = 0xcd, .g = 0x31, .b = 0x31 },
    .{ .r = 0x0d, .g = 0xa7, .b = 0x0d },
    .{ .r = 0xe5, .g = 0xe5, .b = 0x10 },
    .{ .r = 0x24, .g = 0x71, .b = 0xc8 },
    .{ .r = 0xbc, .g = 0x3f, .b = 0xbc },
    .{ .r = 0x11, .g = 0xa8, .b = 0xcd },
    .{ .r = 0xe5, .g = 0xe5, .b = 0xe5 },
    .{ .r = 0x66, .g = 0x66, .b = 0x66 },
    .{ .r = 0xf1, .g = 0x4c, .b = 0x4c },
    .{ .r = 0x23, .g = 0xd1, .b = 0x8b },
    .{ .r = 0xf5, .g = 0xf5, .b = 0x43 },
    .{ .r = 0x3b, .g = 0x8e, .b = 0xde },
    .{ .r = 0xd6, .g = 0x70, .b = 0xd6 },
    .{ .r = 0x29, .g = 0xb8, .b = 0xdb },
    .{ .r = 0xff, .g = 0xff, .b = 0xff },
};

fn handleTerminalBytes(app: *App, tab: workspace.WorkspaceTab, bytes: []const u8) void {
    if (bytes.len == 0) return;
    if (tab.status == .failed or tab.status == .closed) {
        app.reconnectTab(tab.id);
        return;
    }
    if (tab.status != .connected) return;
    app.sendTerminalBytes(tab.id, bytes);
}

fn handleTerminalKey(app: *App, tab: workspace.WorkspaceTab, key: dvui.Event.Key) bool {
    var bytes: []const u8 = "";
    var ctrl_buf: [1]u8 = undefined;

    if (key.mod.control() and !key.mod.command()) {
        if (controlByte(key.code)) |byte| {
            ctrl_buf[0] = byte;
            bytes = ctrl_buf[0..1];
        }
    }

    if (bytes.len == 0) {
        bytes = switch (key.code) {
            .enter, .kp_enter => "\r",
            .backspace => "\x7f",
            .tab => "\t",
            .escape => "\x1b",
            .up => "\x1b[A",
            .down => "\x1b[B",
            .right => "\x1b[C",
            .left => "\x1b[D",
            .home => "\x1b[H",
            .end => "\x1b[F",
            .page_up => "\x1b[5~",
            .page_down => "\x1b[6~",
            .delete => "\x1b[3~",
            else => return false,
        };
    }

    handleTerminalBytes(app, tab, bytes);
    return true;
}

fn controlByte(key: dvui.enums.Key) ?u8 {
    return switch (key) {
        .a => 0x01,
        .b => 0x02,
        .c => 0x03,
        .d => 0x04,
        .e => 0x05,
        .f => 0x06,
        .g => 0x07,
        .h => 0x08,
        .i => 0x09,
        .j => 0x0a,
        .k => 0x0b,
        .l => 0x0c,
        .m => 0x0d,
        .n => 0x0e,
        .o => 0x0f,
        .p => 0x10,
        .q => 0x11,
        .r => 0x12,
        .s => 0x13,
        .t => 0x14,
        .u => 0x15,
        .v => 0x16,
        .w => 0x17,
        .x => 0x18,
        .y => 0x19,
        .z => 0x1a,
        .left_bracket => 0x1b,
        .backslash => 0x1c,
        .right_bracket => 0x1d,
        else => null,
    };
}
