const dvui = @import("dvui");
const std = @import("std");
const terminal = @import("../../../contracts/terminal_emulator.zig");

pub const search_max_matches: usize = 512;
pub const local_echo_capacity: usize = 512;
pub const ime_composition_capacity: usize = 128;
pub const search_query_capacity: usize = 128;
pub const row_render_cache_capacity: usize = 256;
pub const paste_queue_capacity: usize = 512 * 1024;

pub const Run = struct {
    row: f32,
    start_col: u16,
    end_col: u16,
    style: terminal.Style,
    text: []const u8,
};

pub const Point = struct {
    row: usize,
    col: u16,
};

pub const Selection = struct {
    anchor: Point,
    head: Point,
};

pub const SearchMatch = struct {
    row: usize,
    col: u16,
    len: u16,
};

pub const SearchMatches = struct {
    items: [search_max_matches]SearchMatch = undefined,
    len: usize = 0,
    overflow: bool = false,
};

pub const RowRenderCacheEntry = struct {
    generation: u64 = std.math.maxInt(u64),
    absolute_row: usize = std.math.maxInt(usize),
    scrollback_rows: usize = std.math.maxInt(usize),
    cols: u16 = 0,
    has_backgrounds: bool = true,
};

pub const LocalEcho = struct {
    active: bool = false,
    base_generation: u64 = 0,
    base_scrollback_rows: usize = 0,
    row: u16 = 0,
    start_col: u16 = 0,
    text: [local_echo_capacity]u8 = std.mem.zeroes([local_echo_capacity]u8),
    len: usize = 0,
};

pub const Viewport = struct {
    last_size: ?terminal.Size = null,
    scroll_offset: usize = 0,
    wheel_remainder: f32 = 0,
    scrollbar_grab_y: f32 = 0,
    last_scroll_interaction_ns: i128 = 0,
    selection_auto_scroll_remainder: f32 = 0,
    selection: ?Selection = null,
    selecting: bool = false,
    last_click_point: ?Point = null,
    last_click_ns: i128 = 0,
    click_count: u8 = 0,
    ime_composition: [ime_composition_capacity]u8 = std.mem.zeroes([ime_composition_capacity]u8),
    ime_composition_len: usize = 0,
    search_open: bool = false,
    search_focus_requested: bool = false,
    search_scroll_to_active: bool = false,
    search_query: [search_query_capacity]u8 = std.mem.zeroes([search_query_capacity]u8),
    search_active_index: usize = 0,
    search_cache_generation: u64 = std.math.maxInt(u64),
    search_cache_query: [search_query_capacity]u8 = std.mem.zeroes([search_query_capacity]u8),
    search_cache_query_len: usize = 0,
    search_cache_total_rows: usize = 0,
    search_cache_cols: u16 = 0,
    search_cache_matches: SearchMatches = .{},
    row_render_cache: [row_render_cache_capacity]RowRenderCacheEntry = [_]RowRenderCacheEntry{.{}} ** row_render_cache_capacity,
    local_echo: LocalEcho = .{},
    pending_paste: [paste_queue_capacity]u8 = std.mem.zeroes([paste_queue_capacity]u8),
    pending_paste_len: usize = 0,
    pending_paste_offset: usize = 0,
};

pub const ScrollbarGeometry = struct {
    track: dvui.Rect.Physical,
    thumb: dvui.Rect.Physical,
    hit_rect: dvui.Rect.Physical,
    max_start: usize,
    travel: f32,
};
