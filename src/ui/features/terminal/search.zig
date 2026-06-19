const std = @import("std");
const terminal = @import("../../../contracts/terminal_emulator.zig");
const state = @import("viewport_state.zig");

pub fn cachedMatches(snapshot: terminal.Snapshot, viewport: *state.Viewport) state.SearchMatches {
    const query = queryText(viewport);
    if (viewport.search_cache_generation == snapshot.generation and
        viewport.search_cache_query_len == query.len and
        std.mem.eql(u8, viewport.search_cache_query[0..viewport.search_cache_query_len], query))
    {
        return viewport.search_cache_matches;
    }
    const total_rows = snapshot.scrollback_rows + @as(usize, snapshot.size.rows);
    if (canUpdateIncrementally(snapshot, viewport, query, total_rows)) {
        updateDirtyRows(snapshot, viewport, query);
        viewport.search_cache_generation = snapshot.generation;
        return viewport.search_cache_matches;
    }
    viewport.search_cache_generation = snapshot.generation;
    viewport.search_cache_query_len = @min(query.len, viewport.search_cache_query.len);
    if (viewport.search_cache_query_len > 0) {
        @memcpy(viewport.search_cache_query[0..viewport.search_cache_query_len], query[0..viewport.search_cache_query_len]);
    }
    viewport.search_cache_matches = compute(snapshot, query);
    viewport.search_cache_total_rows = total_rows;
    viewport.search_cache_cols = snapshot.size.cols;
    return viewport.search_cache_matches;
}

pub fn queryText(viewport: *state.Viewport) []const u8 {
    return std.mem.sliceTo(viewport.search_query[0..], 0);
}

pub fn clampActiveIndex(viewport: *state.Viewport, matches: state.SearchMatches) void {
    if (matches.len == 0) {
        viewport.search_active_index = 0;
        return;
    }
    viewport.search_active_index = @min(viewport.search_active_index, matches.len - 1);
}

fn canUpdateIncrementally(snapshot: terminal.Snapshot, viewport: *state.Viewport, query: []const u8, total_rows: usize) bool {
    if (viewport.search_cache_generation == std.math.maxInt(u64)) return false;
    if (viewport.search_cache_query_len != query.len) return false;
    if (!std.mem.eql(u8, viewport.search_cache_query[0..viewport.search_cache_query_len], query)) return false;
    if (query.len == 0 or snapshot.scrollback_dirty or snapshot.dirty_rows.empty()) return false;
    if (viewport.search_cache_total_rows != total_rows or viewport.search_cache_cols != snapshot.size.cols) return false;
    return !viewport.search_cache_matches.overflow;
}

fn updateDirtyRows(snapshot: terminal.Snapshot, viewport: *state.Viewport, query: []const u8) void {
    const dirty_start = snapshot.scrollback_rows + @as(usize, snapshot.dirty_rows.start);
    const dirty_end = snapshot.scrollback_rows + @as(usize, snapshot.dirty_rows.end);
    removeRows(&viewport.search_cache_matches, dirty_start, dirty_end);
    var row = dirty_start;
    while (row < dirty_end and !viewport.search_cache_matches.overflow) : (row += 1) {
        appendRow(snapshot, row, query, &viewport.search_cache_matches);
    }
    std.mem.sort(state.SearchMatch, viewport.search_cache_matches.items[0..viewport.search_cache_matches.len], {}, lessThan);
}

fn removeRows(matches: *state.SearchMatches, start_row: usize, end_row: usize) void {
    var write_idx: usize = 0;
    for (matches.items[0..matches.len]) |item| {
        if (item.row >= start_row and item.row < end_row) continue;
        matches.items[write_idx] = item;
        write_idx += 1;
    }
    matches.len = write_idx;
}

fn lessThan(_: void, a: state.SearchMatch, b: state.SearchMatch) bool {
    if (a.row != b.row) return a.row < b.row;
    return a.col < b.col;
}

fn compute(snapshot: terminal.Snapshot, query: []const u8) state.SearchMatches {
    var matches = state.SearchMatches{};
    if (query.len == 0) return matches;
    const total_rows = snapshot.scrollback_rows + @as(usize, snapshot.size.rows);
    for (0..total_rows) |row| appendRow(snapshot, row, query, &matches);
    return matches;
}

fn appendRow(snapshot: terminal.Snapshot, row: usize, query: []const u8, matches: *state.SearchMatches) void {
    var text_buf: [4096]u8 = undefined;
    var byte_cols: [4096]u16 = undefined;
    var col_widths: [4096]u16 = undefined;
    var text_len: usize = 0;
    var col: u16 = 0;
    while (col < snapshot.size.cols and text_len < text_buf.len) : (col += 1) {
        const cell = displayCell(snapshot, row, col) orelse break;
        if (cell.width == 0) continue;
        var cp_buf: [4]u8 = undefined;
        const text = codepointUtf8(cell.codepoint, &cp_buf);
        if (text_len + text.len > text_buf.len) break;
        for (text) |byte| {
            text_buf[text_len] = byte;
            byte_cols[text_len] = col;
            col_widths[text_len] = @max(@as(u16, cell.width), 1);
            text_len += 1;
        }
    }
    var start: usize = 0;
    while (start < text_len) {
        const found = std.mem.indexOfPos(u8, text_buf[0..text_len], start, query) orelse break;
        if (matches.len >= matches.items.len) {
            matches.overflow = true;
            return;
        }
        const end_byte = found + query.len -| 1;
        const start_col = byte_cols[found];
        const end_col = byte_cols[end_byte] + col_widths[end_byte];
        matches.items[matches.len] = .{ .row = row, .col = start_col, .len = @max(@as(u16, 1), end_col -| start_col) };
        matches.len += 1;
        start = found + @max(query.len, 1);
    }
}

fn displayCell(snapshot: terminal.Snapshot, row: usize, col: u16) ?terminal.Cell {
    if (row < snapshot.scrollback_rows) return snapshot.scrollbackCellAt(row, col);
    const screen_row = row - snapshot.scrollback_rows;
    if (screen_row >= snapshot.size.rows) return null;
    return snapshot.cellAt(@intCast(screen_row), col);
}

fn codepointUtf8(cp: u21, buffer: *[4]u8) []const u8 {
    const len = std.unicode.utf8Encode(cp, buffer) catch {
        buffer[0] = '?';
        return buffer[0..1];
    };
    return buffer[0..len];
}
