const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");

const search_icon_bytes = @embedFile("shellowo-search-icon");
const search_prev_icon_bytes = @embedFile("shellowo-search-prev-icon");
const search_next_icon_bytes = @embedFile("shellowo-search-next-icon");
const replace_next_icon_bytes = @embedFile("shellowo-replace-next-icon");
const replace_all_icon_bytes = @embedFile("shellowo-replace-all-icon");

const remote_file = @import("../../../core/remote_file.zig");
const ui_fonts = @import("../../fonts.zig");
const theme = @import("../../theme.zig");

const editor_title: [:0]const u8 = "Shellowo Editor";
const editor_initial_size: dvui.Size = .{ .w = 860, .h = 620 };
const editor_min_size: dvui.Size = .{ .w = 460, .h = 320 };
const search_capacity = 128;
const replace_capacity = 256;

const ConfirmAction = enum { cancel, discard, save };
const SearchAction = enum { find_nearest, find_prev, find_next, replace_next, replace_all };

pub const State = struct {
    open: bool = false,
    initialized: bool = false,
    positioned: bool = false,
    fonts_loaded: bool = false,
    loaded_version: u64 = 0,
    dirty: bool = false,
    confirm_close: bool = false,
    close_after_save: bool = false,
    save_requested: bool = false,
    close_requested: bool = false,
    search_focus_requested: bool = false,
    search_action: ?SearchAction = null,
    search_query: [search_capacity]u8 = std.mem.zeroes([search_capacity]u8),
    replace_text: [replace_capacity]u8 = std.mem.zeroes([replace_capacity]u8),
    search_active_start: usize = 0,
    search_active_end: usize = 0,
    search_has_match: bool = false,
    search_match_count: usize = 0,
    search_active_index: usize = 0,
    search_target_y: ?f32 = null,
};

pub fn show(state: *State, snapshot: remote_file.FileEditorSnapshot, palette: theme.Palette, id_extra: usize) ?remote_file.FilePanelIntent {
    if (!snapshot.isOpen()) {
        state.* = .{};
        return null;
    }

    if (!state.initialized) {
        state.open = true;
        state.initialized = true;
    } else if (!state.open) {
        if (state.dirty) {
            state.open = true;
            state.confirm_close = true;
        } else {
            return .{ .close_edit = .remote };
        }
    }

    state.save_requested = false;
    state.close_requested = false;

    const parent_window = dvui.currentWindow().backend.impl.window;
    var os_win = dvui.osWindow(@src(), .{
        .title = editor_title,
        .size = editor_initial_size,
        .min_size = editor_min_size,
    }, .{
        .open_flag = &state.open,
        .id_extra = id_extra,
    });
    defer os_win.deinit();
    loadEditorFontsOnce(state, os_win);
    centerEditorWindowOnce(state, os_win, parent_window);

    var root = dvui.box(@src(), .{ .dir = .vertical }, theme.panel(.{
        .expand = .both,
        .padding = .all(0),
        .id_extra = id_extra + 1,
    }, palette).override(.{
        .color_fill = palette.app_bg,
        .color_border = palette.app_bg,
    }));
    defer root.deinit();

    header(state, snapshot, state.dirty, palette, id_extra + 10);
    separator(palette, id_extra + 20);
    progressBar(snapshot, palette, id_extra + 24);

    var action: ?remote_file.FilePanelIntent = null;
    var current_text: []const u8 = "";
    var dirty = false;
    switch (snapshot.state) {
        .loading => loading(palette, id_extra + 30),
        .failed => failed(snapshot, palette, id_extra + 30),
        .ready => {
            current_text = editorBody(state, snapshot, palette, id_extra + 30);
            dirty = !std.mem.eql(u8, current_text, snapshot.content);
        },
        .closed => {},
    }
    handleEditorShortcuts(root.data(), state);
    state.dirty = dirty;

    if (state.close_after_save and snapshot.state == .ready and !dirty) {
        state.close_after_save = false;
        state.confirm_close = false;
        action = .{ .close_edit = .remote };
    }

    if (action == null and snapshot.state == .ready and !state.confirm_close and state.save_requested) {
        action = .{ .save_edit = .{
            .pane = .remote,
            .path = snapshot.path,
            .content = current_text,
        } };
    }

    if (action == null and !state.confirm_close and state.close_requested) {
        action = requestClose(state, dirty);
    }

    if (action == null and !state.open) {
        action = requestClose(state, dirty);
    }

    if (action == null and state.confirm_close) {
        if (!dirty) {
            state.confirm_close = false;
            action = .{ .close_edit = .remote };
        } else if (unsavedPrompt(palette, id_extra + 90)) |confirm_action| {
            switch (confirm_action) {
                .cancel => {
                    state.confirm_close = false;
                    state.open = true;
                },
                .discard => {
                    state.confirm_close = false;
                    action = .{ .close_edit = .remote };
                },
                .save => if (snapshot.state == .ready) {
                    state.confirm_close = false;
                    state.close_after_save = true;
                    action = .{ .save_edit = .{
                        .pane = .remote,
                        .path = snapshot.path,
                        .content = current_text,
                    } };
                },
            }
        }
    }

    if (action != null) {
        switch (action.?) {
            .close_edit => state.open = false,
            else => {},
        }
    }
    return action;
}

fn loadEditorFontsOnce(state: *State, os_win: anytype) void {
    if (state.fonts_loaded) return;
    if (dvui.Backend.support_child_os_wins) {
        ui_fonts.loadEmbedded(os_win.inner.dvui_win);
    }
    state.fonts_loaded = true;
}

fn centerEditorWindowOnce(state: *State, os_win: anytype, parent_window: anytype) void {
    if (state.positioned) return;
    state.positioned = true;

    if (comptime !dvui.Backend.support_child_os_wins) return;

    var parent_x: i32 = 0;
    var parent_y: i32 = 0;
    var parent_w: i32 = 0;
    var parent_h: i32 = 0;
    _ = dvui.backend.c.SDL_GetWindowPosition(parent_window, &parent_x, &parent_y);
    _ = dvui.backend.c.SDL_GetWindowSize(parent_window, &parent_w, &parent_h);

    var editor_w: i32 = 0;
    var editor_h: i32 = 0;
    const editor_window = os_win.inner.backend.window;
    _ = dvui.backend.c.SDL_GetWindowSize(editor_window, &editor_w, &editor_h);
    if (editor_w <= 0) editor_w = @intFromFloat(editor_initial_size.w);
    if (editor_h <= 0) editor_h = @intFromFloat(editor_initial_size.h);

    const x = parent_x + @divTrunc(parent_w - editor_w, 2);
    const y = parent_y + @divTrunc(parent_h - editor_h, 2);
    _ = dvui.backend.c.SDL_SetWindowPosition(editor_window, x, y);
}

fn header(state: *State, snapshot: remote_file.FileEditorSnapshot, dirty: bool, palette: theme.Palette, id_extra: usize) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, theme.panel(.{
        .expand = .horizontal,
        .min_size_content = .height(38),
        .max_size_content = .height(38),
        .padding = .{ .x = 14, .y = 0, .w = 14, .h = 0 },
        .margin = .all(0),
        .id_extra = id_extra,
    }, palette).override(.{ .color_fill = palette.panel_bg }));
    defer row.deinit();

    const name = if (snapshot.name.len > 0) snapshot.name else "Remote file";
    var title_buf: [320]u8 = undefined;
    const title = if (dirty)
        std.fmt.bufPrint(&title_buf, "{s}*", .{name}) catch name
    else
        name;
    dvui.label(@src(), "{s}", .{title}, .{
        .font = theme.textFont(title, 12),
        .color_text = palette.text,
        .expand = .horizontal,
        .gravity_y = 0.5,
        .id_extra = id_extra + 1,
    });

    // const status = snapshot.error_summary orelse switch (snapshot.state) {
    //     .loading => "Loading",
    //     .ready => "",
    //     .failed => "Failed",
    //     .closed => "",
    // };
    // if (status.len > 0) {
    //     dvui.label(@src(), "{s}", .{status}, .{
    //         .font = theme.textFont(status, 9),
    //         .color_text = palette.muted_text,
    //         .gravity_y = 0.5,
    //         .id_extra = id_extra + 2,
    //     });
    // }

    searchBox(state, palette, id_extra + 20);
}

fn searchBox(state: *State, palette: theme.Palette, id_extra: usize) void {
    var box = dvui.box(@src(), .{ .dir = .horizontal }, theme.panel(.{
        .min_size_content = .{ .w = 286, .h = 34 },
        .max_size_content = .{ .w = 286, .h = 34 },
        .margin = .all(0),
        .corner_radius = .all(4),
        .id_extra = id_extra,
        .gravity_y = 0.5,
    }, palette).override(.{
        .color_border = palette.border_subtle,
    }));
    defer box.deinit();

    var te: theme.TextEntry = undefined;
    theme.textEntry(@src(), &te, .{
        .text = .{ .buffer = &state.search_query },
        .placeholder = "Search",
    }, searchEntryOptions(palette, id_extra + 1), palette);
    if (state.search_focus_requested) {
        dvui.focusWidget(te.data().id, null, null);
        state.search_focus_requested = false;
    }
    if (te.enterPressed()) state.search_action = .find_nearest;
    if (te.textChanged()) {
        clearSearchMatch(state);
    }
    te.deinit();

    if (iconButton(search_icon_bytes, "search.png", palette, id_extra + 2)) {
        state.search_action = .find_nearest;
    }

    var label_buf: [32]u8 = undefined;
    const label = if (state.search_match_count == 0)
        "0/0"
    else
        std.fmt.bufPrint(&label_buf, "{d}/{d}", .{ state.search_active_index, state.search_match_count }) catch "";
    dvui.label(@src(), "{s}", .{label}, .{
        .font = theme.textFont(label, 9),
        .color_text = palette.muted_text,
        .gravity_y = 0.5,
        .padding = .{ .x = 3, .w = 5 },
        .margin = .all(0),
        .id_extra = id_extra + 2,
    });

    searchNavigator(state, palette, id_extra + 3);

    replacePopup(state, palette, id_extra + 30);
}

fn searchNavigator(state: *State, palette: theme.Palette, id_extra: usize) void {
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 38, .h = 30 },
        .max_size_content = .{ .w = 38, .h = 30 },
        .padding = .all(0),
        .margin = .all(0),
        .id_extra = id_extra,
    });
    defer col.deinit();

    if (tinyIconButton(search_prev_icon_bytes, "search_prev.png", palette, id_extra + 1)) {
        state.search_action = .find_prev;
    }
    if (tinyIconButton(search_next_icon_bytes, "search_next.png", palette, id_extra + 3)) {
        state.search_action = .find_next;
    }
}

fn tinyIconButton(bytes: []const u8, name: []const u8, palette: theme.Palette, id_extra: usize) bool {
    var bw: theme.ButtonWidget = undefined;
    bw.init(@src(), .{
        .min_size_content = .{ .w = 22, .h = 11 },
        .max_size_content = .{ .w = 22, .h = 11 },
        .padding = .all(0),
        .margin = .{ .y = 3 },
        .corner_radius = .all(2),
        .id_extra = id_extra,
    }, palette, .{ .variant = .ghost, .font_size = 7 }, .{});
    bw.processEvents();
    bw.drawBackground();
    renderPng(bytes, name, bw.data().contentRectScale(), bw.style().color(.text));
    const clicked = bw.clicked();
    bw.deinit();
    return clicked;
}

fn searchEntryOptions(palette: theme.Palette, id_extra: usize) dvui.Options {
    return theme.panel(.{
        .expand = .horizontal,
        .gravity_y = 0.5,
        .min_size_content = .{ .h = 22, .w = 120 },
        .max_size_content = .height(22),
        .background = false,
        .border = .all(0),
        .padding = .{ .x = 5, .y = 6 },
        .corner_radius = .all(4),
        .id_extra = id_extra,
    }, palette).override(.{
        .color_fill = dvui.Color.transparent,
        .color_border = palette.border_subtle,
        .font = theme.textFont("Search", 9),
    });
}

fn replacePopup(state: *State, palette: theme.Palette, id_extra: usize) void {
    if (searchQuery(state).len == 0) return;
    const rect = replacePopupRect();
    var panel: dvui.FloatingWidget = undefined;
    panel.init(@src(), .{}, theme.panel(.{
        .rect = .cast(rect),
        .min_size_content = .{ .w = rect.w, .h = rect.h },
        .max_size_content = .{ .w = rect.w, .h = rect.h },
        .padding = .all(2),
        .border = .all(1),
        .corner_radius = .all(5),
        .id_extra = id_extra,
        .gravity_x = 1,
    }, palette).override(.{
        .color_fill = palette.panel_bg.opacity(0.86),
        .color_border = palette.border_subtle.opacity(0.78),
    }));
    defer panel.deinit();
    focusReplacePopupOnClick(&panel);

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .padding = .all(0),
        .id_extra = id_extra + 1,
    });
    defer row.deinit();

    var te: theme.TextEntry = undefined;
    theme.textEntry(@src(), &te, .{
        .text = .{ .buffer = &state.replace_text },
        .placeholder = "Replace",
    }, replaceEntryOptions(palette, id_extra + 2), palette);
    te.deinit();

    if (iconButton(replace_next_icon_bytes, "replace_next.png", palette, id_extra + 3)) {
        state.search_action = .replace_next;
    }
    if (iconButton(replace_all_icon_bytes, "replace_all.png", palette, id_extra + 4)) {
        state.search_action = .replace_all;
    }
}

fn replacePopupRect() dvui.Rect.Natural {
    const window_rect = dvui.windowRect();
    const popup_w: f32 = 286;
    const popup_h: f32 = 34;
    const margin: f32 = 8;
    return .{
        .x = @max(margin, window_rect.w - popup_w - margin),
        .y = 42,
        .w = popup_w,
        .h = popup_h,
    };
}

fn focusReplacePopupOnClick(panel: *dvui.FloatingWidget) void {
    const rs = panel.data().rectScale();
    for (dvui.events()) |*event| {
        if (event.handled or event.evt != .mouse) continue;
        const mouse = event.evt.mouse;
        if (mouse.action != .focus and mouse.action != .press) continue;
        if (mouse.floating_win != panel.data().id) continue;
        if (!rs.r.contains(mouse.p)) continue;
        dvui.focusSubwindow(panel.data().id, null);
        return;
    }
}

fn replaceEntryOptions(palette: theme.Palette, id_extra: usize) dvui.Options {
    return theme.panel(.{
        .expand = .horizontal,
        .gravity_y = 0.5,
        .min_size_content = .{ .h = 22, .w = 110 },
        .max_size_content = .height(22),
        .padding = .{ .x = 6, .y = 5.5, .w = 6, .h = 1 },
        .margin = .all(0),
        .corner_radius = .all(3),
        .id_extra = id_extra,
    }, palette).override(.{
        .color_fill = palette.surface_bg.opacity(0.92),
        .color_border = palette.border_subtle,
        .font = theme.textFont("Replace", 9),
    });
}

fn iconButton(bytes: []const u8, name: []const u8, palette: theme.Palette, id_extra: usize) bool {
    var bw: theme.ButtonWidget = undefined;
    bw.init(@src(), .{
        .min_size_content = .{ .w = 24, .h = 24 },
        .max_size_content = .{ .w = 24, .h = 24 },
        .padding = .all(0),
        .margin = .all(0),
        .corner_radius = .all(3),
        .id_extra = id_extra,
        .gravity_y = 0.5,
    }, palette, .{ .variant = .ghost, .font_size = 9 }, .{});
    bw.processEvents();
    bw.drawBackground();
    renderPng(bytes, name, bw.data().contentRectScale(), bw.style().color(.text));
    const clicked = bw.clicked();
    bw.deinit();
    return clicked;
}

fn renderPng(bytes: []const u8, name: []const u8, rs: dvui.RectScale, color: dvui.Color) void {
    const source: dvui.ImageSource = .{ .imageFile = .{
        .bytes = bytes,
        .name = name,
        .interpolation = .linear,
    } };
    dvui.renderImage(source, rs, .{ .colormod = color }) catch {};
}

fn progressBar(snapshot: remote_file.FileEditorSnapshot, palette: theme.Palette, id_extra: usize) void {
    if (snapshot.state != .loading) return;

    var box = dvui.box(@src(), .{ .dir = .vertical }, theme.panel(.{
        .expand = .horizontal,
        .min_size_content = .height(20),
        .max_size_content = .height(20),
        .padding = .{ .x = 14, .y = 6, .w = 14, .h = 5 },
        .id_extra = id_extra,
    }, palette).override(.{
        .color_fill = palette.panel_bg,
        .color_border = palette.panel_bg,
    }));
    defer box.deinit();

    var track = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .height(5),
        .max_size_content = .height(5),
        .padding = .all(0),
        .corner_radius = .all(3),
        .background = true,
        .color_fill = palette.surface_bg,
        .color_border = palette.surface_bg,
        .id_extra = id_extra + 1,
    });
    defer track.deinit();

    const crs = track.data().contentRectScale();
    const fraction = loadFraction(snapshot);
    const filled_w = @round(crs.r.w * fraction);
    if (filled_w > 0) {
        const fill_rect = dvui.Rect.Physical{
            .x = crs.r.x,
            .y = crs.r.y,
            .w = filled_w,
            .h = crs.r.h,
        };
        fill_rect.fill(.all(@min(crs.r.h / 2, 3 * crs.s)), .{ .color = palette.accent.opacity(0.68) });
    }
}

fn loadFraction(snapshot: remote_file.FileEditorSnapshot) f32 {
    if (snapshot.progress_total) |total| {
        if (total > 0) {
            const done = @min(snapshot.progress_done, total);
            return @as(f32, @floatFromInt(done)) / @as(f32, @floatFromInt(total));
        }
    }
    if (snapshot.progress_done == 0) return 0.08;
    const step: u64 = 512 * 1024;
    const slot = (snapshot.progress_done / step) % 10;
    return 0.15 + @as(f32, @floatFromInt(slot)) * 0.07;
}

fn editorBody(state: *State, snapshot: remote_file.FileEditorSnapshot, palette: theme.Palette, id_extra: usize) []const u8 {
    var body = dvui.box(@src(), .{ .dir = .vertical }, theme.panel(.{
        .expand = .both,
        .padding = .all(0),
        .corner_radius = .all(0),
        .id_extra = id_extra,
    }, palette).override(.{
        .color_fill = palette.app_bg,
        .color_border = palette.app_bg,
    }));
    defer body.deinit();

    handleEditorShortcuts(body.data(), state);

    var naked_theme = dvui.themeGet();
    naked_theme.focus = dvui.Color.transparent;

    var te_storage: dvui.TextEntryWidget = undefined;
    te_storage.init(@src(), .{
        .multiline = true,
        .cache_layout = true,
        .break_lines = true,
        .scroll_vertical = true,
        .scroll_vertical_bar = .auto_overlay,
        .scroll_horizontal = false,
        .scroll_horizontal_bar = .hide,
        .text = .{ .internal = .{ .limit = remote_file.max_editor_bytes } },
    }, editorTextOptions(palette, &naked_theme, id_extra + 1));
    var te = &te_storage;
    defer te.deinit();

    if (dvui.firstFrame(te.data().id) or state.loaded_version != snapshot.version) {
        te.textSet(snapshot.content, false);
        state.loaded_version = snapshot.version;
        clearSearchMatch(state);
    }

    applySearchAction(state, te);
    applyPendingSearchScroll(state, te);
    te.processEvents();
    te.draw();
    updateSearchStats(state, te.textGet());
    return te.textGet();
}

const SearchMatch = struct {
    start: usize,
    end: usize,
};

fn applySearchAction(state: *State, te: *dvui.TextEntryWidget) void {
    const action = state.search_action orelse return;
    state.search_action = null;

    if (searchQuery(state).len == 0) {
        clearSearchMatch(state);
        return;
    }

    switch (action) {
        .find_nearest => {
            _ = selectNearestMatch(state, te, te.textLayout.selection.cursor);
        },
        .find_prev => {
            const start = if (state.search_has_match) state.search_active_start else te.textLayout.selection.cursor;
            _ = selectPrevMatch(state, te, start);
        },
        .find_next => {
            const start = if (state.search_has_match) state.search_active_end else te.textLayout.selection.cursor;
            _ = selectNextMatch(state, te, start);
        },
        .replace_next => replaceNextMatch(state, te),
        .replace_all => replaceAllMatches(state, te),
    }
}

fn replaceNextMatch(state: *State, te: *dvui.TextEntryWidget) void {
    const query = searchQuery(state);
    const replacement = replacementText(state);
    if (query.len == 0) return;

    if (!activeMatchValid(state, te.textGet(), query)) {
        if (!selectNextMatch(state, te, if (state.search_has_match) state.search_active_end else 0)) return;
    }

    const replace_start = state.search_active_start;
    selectMatch(state, te, replace_start, state.search_active_end);
    te.textTyped(replacement, false);
    clearSearchMatch(state);
    _ = selectNextMatch(state, te, replace_start + replacement.len);
}

fn replaceAllMatches(state: *State, te: *dvui.TextEntryWidget) void {
    const query = searchQuery(state);
    const replacement = replacementText(state);
    if (query.len == 0) return;

    const text = te.textGet();
    var out = std.ArrayList(u8).empty;
    const allocator = dvui.currentWindow().lifo();
    defer out.deinit(allocator);

    var pos: usize = 0;
    var count: usize = 0;
    while (std.mem.indexOfPos(u8, text, pos, query)) |idx| {
        out.appendSlice(allocator, text[pos..idx]) catch return;
        out.appendSlice(allocator, replacement) catch return;
        pos = idx + query.len;
        count += 1;
        if (out.items.len > remote_file.max_editor_bytes) return;
    }
    if (count == 0) {
        clearSearchMatch(state);
        return;
    }
    out.appendSlice(allocator, text[pos..]) catch return;
    if (out.items.len > remote_file.max_editor_bytes) return;

    te.textSet(out.items, false);
    clearSearchMatch(state);
    _ = selectNextMatch(state, te, 0);
}

fn selectNextMatch(state: *State, te: *dvui.TextEntryWidget, start: usize) bool {
    const query = searchQuery(state);
    if (findNextMatch(te.textGet(), query, start)) |match| {
        selectMatch(state, te, match.start, match.end);
        return true;
    }
    clearSearchMatch(state);
    return false;
}

fn selectPrevMatch(state: *State, te: *dvui.TextEntryWidget, start: usize) bool {
    const query = searchQuery(state);
    if (findPrevMatch(te.textGet(), query, start)) |match| {
        selectMatch(state, te, match.start, match.end);
        return true;
    }
    clearSearchMatch(state);
    return false;
}

fn selectNearestMatch(state: *State, te: *dvui.TextEntryWidget, cursor: usize) bool {
    const text = te.textGet();
    const query = searchQuery(state);
    const safe_cursor = @min(cursor, text.len);
    const next = findNextMatch(text, query, safe_cursor);
    const prev = findPrevMatch(text, query, safe_cursor);
    const match = nearestMatch(prev, next, safe_cursor) orelse {
        clearSearchMatch(state);
        return false;
    };
    selectMatch(state, te, match.start, match.end);
    return true;
}

fn findNextMatch(text: []const u8, query: []const u8, start: usize) ?SearchMatch {
    if (query.len == 0 or text.len < query.len) return null;

    const safe_start = @min(start, text.len);
    if (std.mem.indexOfPos(u8, text, safe_start, query)) |idx| {
        return .{ .start = idx, .end = idx + query.len };
    }
    if (safe_start > 0) {
        if (std.mem.indexOf(u8, text[0..safe_start], query)) |idx| {
            return .{ .start = idx, .end = idx + query.len };
        }
    }
    return null;
}

fn findPrevMatch(text: []const u8, query: []const u8, start: usize) ?SearchMatch {
    if (query.len == 0 or text.len < query.len) return null;

    const safe_start = @min(start, text.len);
    if (lastIndexBefore(text, query, safe_start)) |idx| {
        return .{ .start = idx, .end = idx + query.len };
    }
    if (safe_start < text.len) {
        if (lastIndexBefore(text, query, text.len)) |idx| {
            return .{ .start = idx, .end = idx + query.len };
        }
    }
    return null;
}

fn lastIndexBefore(text: []const u8, query: []const u8, end: usize) ?usize {
    const safe_end = @min(end, text.len);
    if (query.len == 0 or safe_end < query.len) return null;

    var pos: usize = 0;
    var last: ?usize = null;
    while (std.mem.indexOfPos(u8, text[0..safe_end], pos, query)) |idx| {
        last = idx;
        pos = idx + query.len;
    }
    return last;
}

fn nearestMatch(prev: ?SearchMatch, next: ?SearchMatch, cursor: usize) ?SearchMatch {
    if (prev == null) return next;
    if (next == null) return prev;

    const prev_distance = cursor -| prev.?.start;
    const next_distance = next.?.start -| cursor;
    return if (next_distance < prev_distance) next else prev;
}

fn selectMatch(state: *State, te: *dvui.TextEntryWidget, start: usize, end: usize) void {
    var sel = te.textLayout.selectionGet(te.len);
    sel.start = start;
    sel.cursor = start;
    sel.end = end;
    te.textLayout.scroll_to_cursor = true;

    state.search_active_start = start;
    state.search_active_end = end;
    state.search_has_match = true;
    state.search_target_y = visualYOfOffset(te, start);
    updateSearchStats(state, te.textGet());
    dvui.refresh(null, @src(), te.data().id);
}

fn activeMatchValid(state: *const State, text: []const u8, query: []const u8) bool {
    return state.search_has_match and
        state.search_active_start <= state.search_active_end and
        state.search_active_end <= text.len and
        std.mem.eql(u8, text[state.search_active_start..state.search_active_end], query);
}

fn clearSearchMatch(state: *State) void {
    state.search_active_start = 0;
    state.search_active_end = 0;
    state.search_has_match = false;
    state.search_active_index = 0;
    state.search_target_y = null;
}

fn applyPendingSearchScroll(state: *State, te: *dvui.TextEntryWidget) void {
    const target_y = state.search_target_y orelse return;
    state.search_target_y = null;

    const line_h = editorLineHeight(te);
    const viewport_h = te.scroll.si.viewport.h;
    if (viewport_h <= 0) return;

    const margin = @min(viewport_h * 0.25, line_h * 3);
    const next_offset = target_y - margin;
    te.scroll.si.virtual_size.h = @max(te.scroll.si.virtual_size.h, target_y + viewport_h);
    te.scroll.si.viewport.y = @max(0, next_offset);
    te.scroll.si.velocity.y = 0;
    if (te.scroll.scroll) |*scroll| {
        scroll.frame_viewport.y = te.scroll.si.viewport.y;
        scroll.frame_viewport.x = te.scroll.si.viewport.x;
    }
    te.init_opts.cache_layout = false;
    te.textLayout.cache_layout = false;
    te.textLayout.scroll_to_cursor = false;
    dvui.refresh(null, @src(), te.data().id);
}

fn editorLineHeight(te: *dvui.TextEntryWidget) f32 {
    return @max(te.textLayout.data().options.fontGet().lineHeight(), 1);
}

fn visualYOfOffset(te: *dvui.TextEntryWidget, offset: usize) f32 {
    const text = te.textGet()[0..@min(offset, te.len)];
    if (text.len == 0) return 0;

    const font = te.textLayout.data().options.fontGet();
    const line_h = editorLineHeight(te);
    const content_w = @max(te.textLayout.data().contentRect().w, font.sizeM(1, 1).w);
    const break_width = content_w + 0.001;
    const m_width = font.sizeM(1, 1).w;

    var y: f32 = 0;
    var pos: usize = 0;
    while (pos < text.len) {
        var end: usize = 0;
        _ = font.textSizeEx(text[pos..], .{
            .kerning = te.textLayout.kerning,
            .max_width = break_width,
            .end_idx = &end,
        });
        if (end == 0) {
            end = std.unicode.utf8ByteSequenceLength(text[pos]) catch 1;
        }

        var line_end = end;
        const newline = text[pos + line_end - 1] == '\n';
        if (line_end < text.len - pos and !newline and break_width > (10 * m_width)) {
            if (std.mem.findLastLinear(u8, text[pos .. pos + line_end + 1], " ")) |space_idx| {
                line_end = space_idx + 1;
            }
        }

        if (pos + line_end >= text.len) {
            if (newline) y += line_h;
            break;
        }

        y += line_h;
        pos += line_end;
    }
    return y;
}

fn updateSearchStats(state: *State, text: []const u8) void {
    const query = searchQuery(state);
    state.search_match_count = countMatches(text, query);
    if (state.search_match_count == 0 or !activeMatchValid(state, text, query)) {
        state.search_active_index = 0;
        if (state.search_match_count == 0) state.search_has_match = false;
        return;
    }
    state.search_active_index = matchIndex(text, query, state.search_active_start) orelse 0;
}

fn countMatches(text: []const u8, query: []const u8) usize {
    if (query.len == 0) return 0;
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, text, pos, query)) |idx| {
        count += 1;
        pos = idx + query.len;
    }
    return count;
}

fn matchIndex(text: []const u8, query: []const u8, match_start: usize) ?usize {
    if (query.len == 0) return null;
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, text, pos, query)) |idx| {
        count += 1;
        if (idx == match_start) return count;
        pos = idx + query.len;
    }
    return null;
}

fn searchQuery(state: *const State) []const u8 {
    return std.mem.sliceTo(state.search_query[0..], 0);
}

fn replacementText(state: *const State) []const u8 {
    return std.mem.sliceTo(state.replace_text[0..], 0);
}

fn editorTextOptions(palette: theme.Palette, naked_theme: *const dvui.Theme, id_extra: usize) dvui.Options {
    return theme.panel(.{
        .expand = .both,
        .min_size_content = .{ .w = 640, .h = 460 },
        .background = false,
        .border = .all(0),
        .padding = .all(0),
        .corner_radius = .all(0),
        .theme = naked_theme,
        .id_extra = id_extra,
    }, palette).override(.{
        .color_fill = dvui.Color.transparent,
        .color_fill_hover = dvui.Color.transparent,
        .color_fill_press = dvui.Color.transparent,
        .color_border = dvui.Color.transparent,
        .font = theme.textFont("editor", 10),
    });
}

fn loading(palette: theme.Palette, id_extra: usize) void {
    centerLabel("Loading file...", palette, id_extra);
}

fn failed(snapshot: remote_file.FileEditorSnapshot, palette: theme.Palette, id_extra: usize) void {
    centerLabel(snapshot.error_summary orelse "Editor failed", palette, id_extra);
}

fn centerLabel(text: []const u8, palette: theme.Palette, id_extra: usize) void {
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .all(16),
        .id_extra = id_extra,
    });
    defer box.deinit();
    dvui.label(@src(), "{s}", .{text}, .{
        .font = theme.textFont(text, 10),
        .color_text = palette.muted_text,
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .expand = .both,
        .id_extra = id_extra + 1,
    });
}

fn handleEditorShortcuts(data: *dvui.WidgetData, state: *State) void {
    for (dvui.events()) |*event| {
        if (event.handled or event.evt != .key) continue;
        const key = event.evt.key;
        if (key.action != .down and key.action != .repeat) continue;
        const is_save = key.code == .s and primaryShortcutModifier(key);
        const is_find = key.code == .f and primaryShortcutModifier(key);
        const is_close = key.code == .escape;
        if (!is_save and !is_find and !is_close) continue;

        if (is_save) state.save_requested = true;
        if (is_find) state.search_focus_requested = true;
        if (is_close) state.close_requested = true;

        event.handle(@src(), data);
        dvui.refresh(null, @src(), data.id);
    }
}

fn primaryShortcutModifier(key: dvui.Event.Key) bool {
    return switch (builtin.os.tag) {
        .macos => key.mod.command() and !key.mod.control() and !key.mod.shift() and !key.mod.alt(),
        else => key.mod.control() and !key.mod.command() and !key.mod.shift() and !key.mod.alt(),
    };
}

fn closeShortcut(data: *dvui.WidgetData) bool {
    for (dvui.events()) |*event| {
        if (event.handled or event.evt != .key) continue;
        const key = event.evt.key;
        if (key.action != .down and key.action != .repeat) continue;
        if (key.code != .escape) continue;
        event.handle(@src(), data);
        dvui.refresh(null, @src(), data.id);
        return true;
    }
    return false;
}

fn requestClose(state: *State, dirty: bool) ?remote_file.FilePanelIntent {
    state.open = true;
    if (dirty) {
        state.confirm_close = true;
        return null;
    }
    state.confirm_close = false;
    return .{ .close_edit = .remote };
}

fn unsavedPrompt(palette: theme.Palette, id_extra: usize) ?ConfirmAction {
    const window_rect = dvui.windowRect();
    const popup_w = 350;
    const popup_h = 126;
    const rect: dvui.Rect.Natural = .{
        .x = @max(12, @round((window_rect.w - popup_w) / 2)),
        .y = @max(12, @round((window_rect.h - popup_h) / 2)),
        .w = popup_w,
        .h = popup_h,
    };

    var panel: dvui.FloatingWidget = undefined;
    panel.init(@src(), .{}, theme.panel(.{
        .rect = .cast(rect),
        .min_size_content = .{ .w = rect.w, .h = rect.h },
        .max_size_content = .{ .w = rect.w, .h = rect.h },
        .padding = .all(0),
        .border = .all(1),
        .corner_radius = .all(6),
        .id_extra = id_extra,
    }, palette).override(.{
        .color_fill = palette.panel_bg,
        .color_border = palette.border_subtle,
    }));
    defer panel.deinit();
    dvui.focusSubwindow(panel.data().id, null);

    if (closeShortcut(panel.data())) return .cancel;

    var content = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 16, .y = 14, .w = 16, .h = 12 },
        .id_extra = id_extra + 1,
    });
    defer content.deinit();

    dvui.label(@src(), "Unsaved Changes", .{}, .{
        .font = theme.textFont("Unsaved Changes", 12),
        .color_text = palette.text,
        .expand = .horizontal,
        .id_extra = id_extra + 2,
    });
    dvui.label(@src(), "Save changes before closing?", .{}, .{
        .font = theme.textFont("Save changes before closing?", 9),
        .color_text = palette.muted_text,
        .expand = .horizontal,
        .min_size_content = .height(20),
        .margin = .all(0),
        .id_extra = id_extra + 3,
    });

    var buttons = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .margin = .all(0),
        .padding = .all(0),
        .id_extra = id_extra + 10,
    });
    defer buttons.deinit();

    _ = dvui.spacer(@src(), .{ .expand = .horizontal, .id_extra = id_extra + 11 });
    if (theme.button(@src(), "Cancel", .{
        .min_size_content = .{ .w = 76, .h = 24 },
        .id_extra = id_extra + 12,
    }, palette, .{ .variant = .ghost, .font_size = 10 })) return .cancel;
    if (theme.button(@src(), "Discard", .{
        .min_size_content = .{ .w = 82, .h = 24 },
        .id_extra = id_extra + 13,
    }, palette, .{ .intent = .danger, .variant = .ghost, .font_size = 10 })) return .discard;
    if (theme.button(@src(), "Save", .{
        .min_size_content = .{ .w = 76, .h = 24 },
        .id_extra = id_extra + 14,
    }, palette, .{ .intent = .primary, .variant = .solid, .font_size = 10 })) return .save;
    return null;
}

fn separator(palette: theme.Palette, id_extra: usize) void {
    _ = dvui.separator(@src(), .{
        .expand = .horizontal,
        .min_size_content = .height(1),
        .max_size_content = .height(1),
        .padding = .all(0),
        .id_extra = id_extra,
        .color_fill = palette.border_subtle,
    });
}
