const std = @import("std");
const terminal = @import("terminal.zig");

pub const max_diff_rects = terminal.max_dirty_rects;
pub const max_pending_input_bytes = 64 * 1024;
pub const default_prediction_cooldown_ms: u64 = 500;
pub const default_full_rollback_threshold: u32 = 64;
pub const default_disable_threshold: u32 = 256;

pub const PredictionKind = enum {
    printable_char,
    backspace,
    enter,
    tab,
    arrow_key,
    readline_control,
    unknown,
};

pub const PredictionLevel = enum(u8) {
    safe_shell = 0,
    readline = 1,
    tui_insert = 2,
    disabled = 3,
};

pub const PredictionContext = struct {
    shell_prompt: bool = false,
    sensitive_prompt: bool = false,
    cursor_at_line_end: bool = false,
    selection_active: bool = false,
    search_active: bool = false,
    scrolled_back: bool = false,
    paste_active: bool = false,
};

pub const PredictionDecision = struct {
    allowed: bool,
    level: PredictionLevel,
    kind: PredictionKind,
};

pub const PredictionMode = enum {
    off,
    safe,
    auto,
    aggressive,
};

pub const PredictionConfig = struct {
    enabled: bool = true,
    mode: PredictionMode = .auto,
    max_pending_inputs: usize = 256,
    max_pending_bytes: usize = max_pending_input_bytes,
    rollback_threshold: u32 = default_full_rollback_threshold,
    disable_threshold: u32 = default_disable_threshold,
    cooldown_ms: u64 = default_prediction_cooldown_ms,
    predict_in_alt_screen: bool = true,
    predict_printable: bool = true,
    predict_backspace: bool = true,
    predict_enter: bool = true,
    predict_tab: bool = false,
    predict_arrow_keys: bool = false,

    pub fn baseLevel(self: PredictionConfig) PredictionLevel {
        if (!self.enabled or self.mode == .off) return .disabled;
        return switch (self.mode) {
            .off => .disabled,
            .safe => .safe_shell,
            .auto => .safe_shell,
            .aggressive => .tui_insert,
        };
    }
};

pub const ReconcileAction = enum {
    none,
    patch,
    partial_rollback,
    full_rollback,
    disable_temporarily,
};

pub const DiffAssessment = struct {
    score: u32 = 0,
    action: ReconcileAction = .none,
};

pub const RttSampler = struct {
    sample_count: u32 = 0,
    smoothed_ms: u32 = 0,
    last_sample_ms: u32 = 0,

    pub fn observe(self: *RttSampler, sample_ms: u32) void {
        self.last_sample_ms = sample_ms;
        if (self.sample_count == 0) {
            self.smoothed_ms = sample_ms;
        } else {
            self.smoothed_ms = @intCast((@as(u64, self.smoothed_ms) * 7 + sample_ms) / 8);
        }
        self.sample_count +|= 1;
    }

    pub fn suggestedLevel(self: RttSampler, config: PredictionConfig) PredictionLevel {
        if (!config.enabled or config.mode == .off) return .disabled;
        if (config.mode == .safe) return .safe_shell;
        if (config.mode == .aggressive) return .tui_insert;
        if (self.sample_count == 0) return config.baseLevel();
        if (self.smoothed_ms < 30) return .safe_shell;
        if (self.smoothed_ms < 100) return .safe_shell;
        if (self.smoothed_ms < 300) return .tui_insert;
        return .tui_insert;
    }
};

pub const RemoteAgentMode = enum {
    disabled,
    proposed,
};

pub const RemoteAgentPlan = struct {
    mode: RemoteAgentMode = .disabled,
    protocol_version: u16 = 0,
    supports_state_diff: bool = false,
    supports_reconnect: bool = false,

    pub fn available(self: RemoteAgentPlan) bool {
        return self.mode == .proposed and self.supports_state_diff;
    }
};

pub const PredictionPolicyState = struct {
    level: PredictionLevel = .safe_shell,
    conflict_score: u8 = 0,
    stable_score: u8 = 0,
    disabled_until_ms: u64 = 0,
    rollback_count: u32 = 0,
    rtt: RttSampler = .{},
    config: PredictionConfig = .{},
    remote_agent: RemoteAgentPlan = .{},

    pub fn observeDiff(self: *PredictionPolicyState, diff: ScreenDiff, now_ms: u64) void {
        const assessment = assessDiff(diff, self.config);
        if (diff.empty()) {
            self.stable_score = @min(self.stable_score +| 1, 20);
            if (self.conflict_score > 0) self.conflict_score -= 1;
            if (self.stable_score >= 12) self.upgrade();
            return;
        }

        self.stable_score = 0;
        self.conflict_score = @min(self.conflict_score +| conflictWeight(diff, assessment), 20);
        if (assessment.action == .disable_temporarily or self.conflict_score >= 6) {
            self.level = .disabled;
            self.disabled_until_ms = now_ms + self.config.cooldown_ms;
            self.conflict_score = 0;
            self.rollback_count +|= 1;
        } else if (assessment.action == .full_rollback or self.conflict_score >= 3) {
            const before = self.level;
            self.downgrade();
            if (before != .disabled and self.level == .disabled) {
                self.disabled_until_ms = now_ms + self.config.cooldown_ms;
            }
            self.rollback_count +|= 1;
        }
    }

    pub fn refresh(self: *PredictionPolicyState, now_ms: u64) void {
        if (self.level == .disabled and self.disabled_until_ms != 0 and now_ms >= self.disabled_until_ms) {
            self.level = .safe_shell;
            self.disabled_until_ms = 0;
            self.stable_score = 0;
        }
    }

    pub fn observeRtt(self: *PredictionPolicyState, sample_ms: u32) void {
        self.rtt.observe(sample_ms);
        if (self.level != .disabled) {
            self.level = self.rtt.suggestedLevel(self.config);
        }
    }

    pub fn applyConfig(self: *PredictionPolicyState, config: PredictionConfig) void {
        self.config = config;
        self.level = config.baseLevel();
        self.conflict_score = 0;
        self.stable_score = 0;
        self.disabled_until_ms = 0;
    }

    fn downgrade(self: *PredictionPolicyState) void {
        self.level = switch (self.level) {
            .tui_insert => .readline,
            .readline => .safe_shell,
            .safe_shell => .disabled,
            .disabled => .disabled,
        };
        self.stable_score = 0;
    }

    fn upgrade(self: *PredictionPolicyState) void {
        self.level = switch (self.level) {
            .safe_shell => .readline,
            .readline => .tui_insert,
            .tui_insert => .tui_insert,
            .disabled => .disabled,
        };
        self.stable_score = 0;
        self.conflict_score = 0;
    }
};

pub const PendingInput = struct {
    id: u64,
    timestamp_ms: u64,
    bytes: []u8,
    prediction_kind: PredictionKind,

    pub fn deinit(self: *PendingInput, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const ScreenDiff = struct {
    dirty_rects: terminal.DirtyRects = .{},
    cell_mismatches: usize = 0,
    cursor_changed: bool = false,
    mode_changed: bool = false,
    size_changed: bool = false,
    scrollback_changed: bool = false,

    pub fn empty(self: ScreenDiff) bool {
        return self.cell_mismatches == 0 and
            !self.cursor_changed and
            !self.mode_changed and
            !self.size_changed and
            !self.scrollback_changed;
    }

    pub fn structural(self: ScreenDiff) bool {
        return self.size_changed or self.scrollback_changed or self.mode_changed;
    }
};

pub const DualState = struct {
    allocator: std.mem.Allocator,
    real: ?terminal.Snapshot = null,
    predicted: ?terminal.Snapshot = null,
    pending_inputs: std.ArrayList(PendingInput) = .empty,
    pending_input_bytes: usize = 0,
    next_input_id: u64 = 1,
    prediction_policy: PredictionPolicyState = .{},

    pub fn init(allocator: std.mem.Allocator) DualState {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DualState) void {
        if (self.real) |*real| real.deinit();
        if (self.predicted) |*predicted| predicted.deinit();
        self.clearPendingInputs();
        self.pending_inputs.deinit(self.allocator);
        self.* = .{ .allocator = self.allocator };
    }

    pub fn syncReal(self: *DualState, real_snapshot: terminal.Snapshot) !ScreenDiff {
        return self.syncRealAt(real_snapshot, 0);
    }

    pub fn syncRealAt(self: *DualState, real_snapshot: terminal.Snapshot, now_ms: u64) !ScreenDiff {
        const next_real = try cloneSnapshot(self.allocator, real_snapshot);
        errdefer deinitSnapshot(&next_real);

        if (self.real) |*old_real| old_real.deinit();
        self.real = next_real;

        if (self.predicted == null) {
            self.predicted = try cloneSnapshot(self.allocator, real_snapshot);
            return .{};
        }

        const diff = diffSnapshots(real_snapshot, self.predicted.?);
        self.prediction_policy.observeDiff(diff, now_ms);
        if (diff.empty()) {
            self.confirmPendingInputs();
        } else {
            try self.patchPredictedFromReal(diff);
            self.clearPendingInputs();
        }
        return diff;
    }

    pub fn realSnapshot(self: *const DualState) ?*const terminal.Snapshot {
        return if (self.real) |*real| real else null;
    }

    pub fn predictedSnapshot(self: *const DualState) ?*const terminal.Snapshot {
        return if (self.predicted) |*predicted| predicted else null;
    }

    pub fn resetPredictedToReal(self: *DualState) !void {
        const real = self.real orelse return;
        const next_predicted = try cloneSnapshot(self.allocator, real);
        if (self.predicted) |*old_predicted| old_predicted.deinit();
        self.predicted = next_predicted;
    }

    pub fn feedLocalInput(self: *DualState, bytes: []const u8) void {
        if (self.predicted) |*predicted| {
            applyLocalInput(predicted, bytes, self.prediction_policy.level, self.prediction_policy.config);
        }
    }

    pub fn recordLocalInput(self: *DualState, bytes: []const u8, timestamp_ms: u64) !?u64 {
        if (bytes.len == 0) return null;
        if (self.pending_inputs.items.len >= self.prediction_policy.config.max_pending_inputs or
            self.pending_input_bytes + bytes.len > self.prediction_policy.config.max_pending_bytes)
        {
            try self.resetPredictedToReal();
            self.clearPendingInputs();
            return error.PendingInputOverflow;
        }

        const owned = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(owned);

        const id = self.next_input_id;
        self.next_input_id +%= 1;
        try self.pending_inputs.append(self.allocator, .{
            .id = id,
            .timestamp_ms = timestamp_ms,
            .bytes = owned,
            .prediction_kind = classifyPrediction(bytes),
        });
        self.pending_input_bytes += owned.len;
        if (self.predicted) |*predicted| {
            applyLocalInput(predicted, bytes, self.prediction_policy.level, self.prediction_policy.config);
        }
        return id;
    }

    pub fn decideCurrentPrediction(self: *DualState, snapshot: terminal.Snapshot, context: PredictionContext, bytes: []const u8, now_ms: u64) PredictionDecision {
        self.prediction_policy.refresh(now_ms);
        return decidePrediction(snapshot, context, bytes, self.prediction_policy.level, self.prediction_policy.config);
    }

    pub fn pendingInputCount(self: *const DualState) usize {
        return self.pending_inputs.items.len;
    }

    pub fn pendingInputBytes(self: *const DualState) usize {
        return self.pending_input_bytes;
    }

    pub fn expirePendingInputs(self: *DualState, now_ms: u64, timeout_ms: u64) !bool {
        for (self.pending_inputs.items) |pending| {
            if (now_ms -% pending.timestamp_ms >= timeout_ms) {
                try self.resetPredictedToReal();
                self.clearPendingInputs();
                return true;
            }
        }
        return false;
    }

    fn confirmPendingInputs(self: *DualState) void {
        self.clearPendingInputs();
    }

    fn clearPendingInputs(self: *DualState) void {
        for (self.pending_inputs.items) |*pending| {
            pending.deinit(self.allocator);
        }
        self.pending_inputs.clearRetainingCapacity();
        self.pending_input_bytes = 0;
    }

    fn patchPredictedFromReal(self: *DualState, diff: ScreenDiff) !void {
        const assessment = assessDiff(diff, self.prediction_policy.config);
        if (assessment.action == .disable_temporarily or assessment.action == .full_rollback or diff.structural() or diff.dirty_rects.overflow) {
            try self.resetPredictedToReal();
            return;
        }
        const real = self.real orelse return;
        const predicted = if (self.predicted) |*predicted_snapshot| predicted_snapshot else return;

        for (diff.dirty_rects.items[0..diff.dirty_rects.len]) |rect| {
            var row = rect.start_row;
            while (row < rect.end_row) : (row += 1) {
                var col = rect.start_col;
                while (col < rect.end_col) : (col += 1) {
                    const idx = @as(usize, row) * @as(usize, real.size.cols) + @as(usize, col);
                    predicted.cells[idx] = real.cells[idx];
                }
            }
        }
        predicted.cursor = real.cursor;
        predicted.generation = real.generation;
        predicted.dirty_rows = diffRows(diff.dirty_rects, real.size.rows);
        predicted.dirty_rects = diff.dirty_rects;
        predicted.cursor_dirty = diff.cursor_changed;
    }
};

pub fn decidePrediction(snapshot: terminal.Snapshot, context: PredictionContext, bytes: []const u8, level: PredictionLevel, config: PredictionConfig) PredictionDecision {
    const kind = classifyPrediction(bytes);
    if (!predictionEnvironmentSafe(snapshot, context, level, config)) {
        return .{ .allowed = false, .level = level, .kind = kind };
    }

    const allowed = switch (level) {
        .safe_shell => context.shell_prompt and context.cursor_at_line_end and switch (kind) {
            .printable_char => config.predict_printable,
            .backspace => config.predict_backspace,
            .enter => config.predict_enter,
            else => false,
        },
        .readline => context.shell_prompt and switch (kind) {
            .printable_char => config.predict_printable,
            .backspace => config.predict_backspace,
            .enter => config.predict_enter,
            .arrow_key => config.predict_arrow_keys,
            .readline_control => true,
            else => false,
        },
        .tui_insert => switch (kind) {
            .printable_char => config.predict_printable,
            .backspace => config.predict_backspace,
            .enter => config.predict_enter,
            .tab => config.predict_tab,
            .arrow_key => config.predict_arrow_keys,
            else => false,
        },
        .disabled => false,
    };
    return .{ .allowed = allowed, .level = level, .kind = kind };
}

fn predictionEnvironmentSafe(snapshot: terminal.Snapshot, context: PredictionContext, level: PredictionLevel, config: PredictionConfig) bool {
    if (!config.enabled or config.mode == .off) return false;
    if (level == .disabled) return false;
    if (context.sensitive_prompt or context.selection_active or context.search_active or context.scrolled_back or context.paste_active) return false;
    if (!snapshot.cursor.visible) return false;
    if (snapshot.bracketed_paste or snapshot.mouse_mode != .none) return false;
    if (snapshot.alternate_screen and (level != .tui_insert or !config.predict_in_alt_screen)) return false;
    return true;
}

fn conflictWeight(diff: ScreenDiff, assessment: DiffAssessment) u8 {
    if (assessment.action == .disable_temporarily) return 6;
    if (assessment.action == .full_rollback) return 4;
    if (diff.size_changed or diff.scrollback_changed) return 6;
    if (diff.mode_changed) return 4;
    if (diff.cell_mismatches > 32) return 4;
    if (diff.cell_mismatches > 4) return 2;
    if (diff.cell_mismatches > 0 or diff.cursor_changed) return 1;
    return 0;
}

pub fn assessDiff(diff: ScreenDiff, config: PredictionConfig) DiffAssessment {
    const score = diffScore(diff);
    const action: ReconcileAction = if (score == 0)
        .none
    else if (score >= config.disable_threshold)
        .disable_temporarily
    else if (score >= config.rollback_threshold or diff.structural())
        .full_rollback
    else if (score >= config.rollback_threshold / 2)
        .partial_rollback
    else
        .patch;
    return .{ .score = score, .action = action };
}

pub fn diffScore(diff: ScreenDiff) u32 {
    var score: u32 = @intCast(@min(diff.cell_mismatches, std.math.maxInt(u32)));
    if (diff.cursor_changed) score +|= 2;
    if (diff.mode_changed) score +|= 32;
    if (diff.scrollback_changed) score +|= 96;
    if (diff.size_changed) score +|= 128;
    if (diff.dirty_rects.overflow) score +|= 64;
    return score;
}

pub fn classifyPrediction(bytes: []const u8) PredictionKind {
    if (bytes.len == 0) return .unknown;
    if (bytes.len == 1) {
        return switch (bytes[0]) {
            0x20...0x7e => .printable_char,
            0x7f, 0x08 => .backspace,
            '\r', '\n' => .enter,
            '\t' => .tab,
            0x01...0x07, 0x0b, 0x0c, 0x0e...0x1a => .readline_control,
            else => .unknown,
        };
    }
    if (std.mem.eql(u8, bytes, "\x1b[A") or
        std.mem.eql(u8, bytes, "\x1b[B") or
        std.mem.eql(u8, bytes, "\x1b[C") or
        std.mem.eql(u8, bytes, "\x1b[D"))
    {
        return .arrow_key;
    }
    for (bytes) |byte| {
        if (byte < 0x20 or byte > 0x7e) return .unknown;
    }
    return .printable_char;
}

pub fn cloneSnapshot(allocator: std.mem.Allocator, snapshot: terminal.Snapshot) !terminal.Snapshot {
    const cells = try allocator.dupe(terminal.Cell, snapshot.cells);
    errdefer allocator.free(cells);

    const scrollback_cells = try allocator.dupe(terminal.Cell, snapshot.scrollback_cells);
    errdefer allocator.free(scrollback_cells);

    const title = if (snapshot.title) |title_bytes| try allocator.dupe(u8, title_bytes) else null;
    errdefer if (title) |title_bytes| allocator.free(title_bytes);

    return .{
        .allocator = allocator,
        .generation = snapshot.generation,
        .size = snapshot.size,
        .cells = cells,
        .scrollback_cells = scrollback_cells,
        .scrollback_rows = snapshot.scrollback_rows,
        .dirty_rows = snapshot.dirty_rows,
        .dirty_rects = snapshot.dirty_rects,
        .scrollback_dirty = snapshot.scrollback_dirty,
        .cursor_dirty = snapshot.cursor_dirty,
        .alternate_screen = snapshot.alternate_screen,
        .bracketed_paste = snapshot.bracketed_paste,
        .mouse_mode = snapshot.mouse_mode,
        .cursor = snapshot.cursor,
        .title = title,
    };
}

pub fn diffSnapshots(real: terminal.Snapshot, predicted: terminal.Snapshot) ScreenDiff {
    var diff: ScreenDiff = .{};
    if (real.size.cols != predicted.size.cols or real.size.rows != predicted.size.rows) {
        diff.size_changed = true;
        return diff;
    }
    if (real.scrollback_rows != predicted.scrollback_rows or real.scrollback_cells.len != predicted.scrollback_cells.len) {
        diff.scrollback_changed = true;
        return diff;
    }
    diff.mode_changed = real.alternate_screen != predicted.alternate_screen or
        real.bracketed_paste != predicted.bracketed_paste or
        real.mouse_mode != predicted.mouse_mode;
    diff.cursor_changed = !std.meta.eql(real.cursor, predicted.cursor);

    for (real.scrollback_cells, predicted.scrollback_cells) |real_cell, predicted_cell| {
        if (!std.meta.eql(real_cell, predicted_cell)) {
            diff.scrollback_changed = true;
            return diff;
        }
    }

    var row: u16 = 0;
    while (row < real.size.rows) : (row += 1) {
        var col: u16 = 0;
        while (col < real.size.cols) : (col += 1) {
            const idx = @as(usize, row) * @as(usize, real.size.cols) + @as(usize, col);
            if (!std.meta.eql(real.cells[idx], predicted.cells[idx])) {
                diff.cell_mismatches += 1;
                appendDiffRect(&diff.dirty_rects, .{
                    .start_row = row,
                    .end_row = row + 1,
                    .start_col = col,
                    .end_col = col + 1,
                });
            }
        }
    }
    return diff;
}

fn applyLocalInput(snapshot: *terminal.Snapshot, bytes: []const u8, level: PredictionLevel, config: PredictionConfig) void {
    if (snapshot.bracketed_paste or snapshot.mouse_mode != .none) return;
    if (snapshot.alternate_screen and (level != .tui_insert or !config.predict_in_alt_screen)) return;
    for (bytes) |byte| {
        switch (byte) {
            0x20...0x7e => if (config.predict_printable) putAscii(snapshot, byte),
            0x7f, 0x08 => if (config.predict_backspace) backspace(snapshot),
            '\r', '\n' => {
                if (config.predict_enter) predictEnter(snapshot);
                return;
            },
            else => return,
        }
    }
}

fn putAscii(snapshot: *terminal.Snapshot, byte: u8) void {
    if (snapshot.cursor.row >= snapshot.size.rows or snapshot.cursor.col >= snapshot.size.cols) return;
    const idx = @as(usize, snapshot.cursor.row) * @as(usize, snapshot.size.cols) + @as(usize, snapshot.cursor.col);
    snapshot.cells[idx] = .{ .codepoint = byte, .width = 1, .style = .{} };
    appendDiffRect(&snapshot.dirty_rects, .{
        .start_row = snapshot.cursor.row,
        .end_row = snapshot.cursor.row + 1,
        .start_col = snapshot.cursor.col,
        .end_col = snapshot.cursor.col + 1,
    });
    snapshot.dirty_rows = mergeRows(snapshot.dirty_rows, .{ .start = snapshot.cursor.row, .end = snapshot.cursor.row + 1 });
    snapshot.cursor.col += 1;
    snapshot.cursor_dirty = true;
}

fn backspace(snapshot: *terminal.Snapshot) void {
    if (snapshot.cursor.col == 0 or snapshot.cursor.row >= snapshot.size.rows) return;
    snapshot.cursor.col -= 1;
    const idx = @as(usize, snapshot.cursor.row) * @as(usize, snapshot.size.cols) + @as(usize, snapshot.cursor.col);
    snapshot.cells[idx] = .{};
    appendDiffRect(&snapshot.dirty_rects, .{
        .start_row = snapshot.cursor.row,
        .end_row = snapshot.cursor.row + 1,
        .start_col = snapshot.cursor.col,
        .end_col = snapshot.cursor.col + 1,
    });
    snapshot.dirty_rows = mergeRows(snapshot.dirty_rows, .{ .start = snapshot.cursor.row, .end = snapshot.cursor.row + 1 });
    snapshot.cursor_dirty = true;
}

fn predictEnter(snapshot: *terminal.Snapshot) void {
    if (snapshot.cursor.row + 1 >= snapshot.size.rows) return;
    const old_row = snapshot.cursor.row;
    snapshot.cursor.row += 1;
    snapshot.cursor.col = 0;
    snapshot.cursor_dirty = true;
    snapshot.dirty_rows = mergeRows(snapshot.dirty_rows, .{ .start = old_row, .end = snapshot.cursor.row + 1 });
}

fn appendDiffRect(rects: *terminal.DirtyRects, rect: terminal.DirtyRect) void {
    if (rect.empty() or rects.overflow) return;
    for (rects.items[0..rects.len]) |*existing| {
        if (rectsOverlapOrTouch(existing.*, rect)) {
            existing.* = mergeRects(existing.*, rect);
            return;
        }
    }
    if (rects.len >= rects.items.len) {
        rects.overflow = true;
        return;
    }
    rects.items[rects.len] = rect;
    rects.len += 1;
}

fn rectsOverlapOrTouch(a: terminal.DirtyRect, b: terminal.DirtyRect) bool {
    if (a.end_row < b.start_row or b.end_row < a.start_row) return false;
    if (a.end_col < b.start_col or b.end_col < a.start_col) return false;
    return true;
}

fn mergeRects(a: terminal.DirtyRect, b: terminal.DirtyRect) terminal.DirtyRect {
    return .{
        .start_row = @min(a.start_row, b.start_row),
        .end_row = @max(a.end_row, b.end_row),
        .start_col = @min(a.start_col, b.start_col),
        .end_col = @max(a.end_col, b.end_col),
    };
}

fn mergeRows(a: terminal.DirtyRows, b: terminal.DirtyRows) terminal.DirtyRows {
    if (a.empty()) return b;
    if (b.empty()) return a;
    return .{ .start = @min(a.start, b.start), .end = @max(a.end, b.end) };
}

fn diffRows(rects: terminal.DirtyRects, rows: u16) terminal.DirtyRows {
    if (rects.overflow) return .{ .start = 0, .end = rows };
    var out: terminal.DirtyRows = .{};
    for (rects.items[0..rects.len]) |rect| {
        out = mergeRows(out, .{ .start = rect.start_row, .end = rect.end_row });
    }
    return out;
}

fn deinitSnapshot(snapshot: *const terminal.Snapshot) void {
    var mutable = snapshot.*;
    mutable.deinit();
}

fn testSnapshot(allocator: std.mem.Allocator, text: []const u8) !terminal.Snapshot {
    const cells = try allocator.alloc(terminal.Cell, 8);
    errdefer allocator.free(cells);
    @memset(cells, .{});
    for (text, 0..) |byte, i| {
        if (i >= cells.len) break;
        cells[i] = .{ .codepoint = byte, .width = 1 };
    }
    return .{
        .allocator = allocator,
        .size = .{ .cols = 8, .rows = 1 },
        .cells = cells,
        .cursor = .{ .col = @intCast(@min(text.len, 8)), .row = 0 },
    };
}

test "diff snapshots reports cell and cursor changes" {
    var real = try testSnapshot(std.testing.allocator, "abc");
    defer real.deinit();
    var predicted = try testSnapshot(std.testing.allocator, "axc");
    defer predicted.deinit();

    const diff = diffSnapshots(real, predicted);
    try std.testing.expectEqual(@as(usize, 1), diff.cell_mismatches);
    try std.testing.expect(!diff.dirty_rects.empty());
    try std.testing.expect(!diff.empty());
}

test "dual state rolls prediction forward and patches from real" {
    var real = try testSnapshot(std.testing.allocator, "ab");
    defer real.deinit();

    var state = DualState.init(std.testing.allocator);
    defer state.deinit();
    _ = try state.syncReal(real);
    const id = try state.recordLocalInput("c", 1000);
    try std.testing.expectEqual(@as(u64, 1), id.?);
    try std.testing.expectEqual(@as(usize, 1), state.pendingInputCount());
    try std.testing.expectEqual(@as(usize, 1), state.pendingInputBytes());
    try std.testing.expectEqual(@as(u21, 'c'), state.predictedSnapshot().?.cellAt(0, 2).?.codepoint);

    var confirmed = try testSnapshot(std.testing.allocator, "abc");
    defer confirmed.deinit();
    const diff = try state.syncReal(confirmed);
    try std.testing.expect(diff.empty());
    try std.testing.expectEqual(@as(usize, 0), state.pendingInputCount());
    try std.testing.expectEqual(@as(u21, 'c'), state.realSnapshot().?.cellAt(0, 2).?.codepoint);
}

test "dual state resets structural differences" {
    var real = try testSnapshot(std.testing.allocator, "ab");
    defer real.deinit();

    var state = DualState.init(std.testing.allocator);
    defer state.deinit();
    _ = try state.syncReal(real);

    var changed = try testSnapshot(std.testing.allocator, "ab");
    defer changed.deinit();
    changed.alternate_screen = true;

    const diff = try state.syncReal(changed);
    try std.testing.expect(diff.mode_changed);
    try std.testing.expect(state.predictedSnapshot().?.alternate_screen);
}

test "dual state clears pending input after remote conflict" {
    var real = try testSnapshot(std.testing.allocator, "ab");
    defer real.deinit();

    var state = DualState.init(std.testing.allocator);
    defer state.deinit();
    _ = try state.syncReal(real);
    _ = try state.recordLocalInput("c", 1000);

    var conflicted = try testSnapshot(std.testing.allocator, "abx");
    defer conflicted.deinit();
    const diff = try state.syncReal(conflicted);
    try std.testing.expect(!diff.empty());
    try std.testing.expectEqual(@as(usize, 0), state.pendingInputCount());
    try std.testing.expectEqual(@as(u21, 'x'), state.predictedSnapshot().?.cellAt(0, 2).?.codepoint);
}

test "dual state expires pending input and rolls back prediction" {
    var real = try testSnapshot(std.testing.allocator, "ab");
    defer real.deinit();

    var state = DualState.init(std.testing.allocator);
    defer state.deinit();
    _ = try state.syncReal(real);
    _ = try state.recordLocalInput("c", 1000);
    try std.testing.expectEqual(@as(u21, 'c'), state.predictedSnapshot().?.cellAt(0, 2).?.codepoint);

    try std.testing.expect(try state.expirePendingInputs(1301, 300));
    try std.testing.expectEqual(@as(usize, 0), state.pendingInputCount());
    try std.testing.expectEqual(@as(u21, ' '), state.predictedSnapshot().?.cellAt(0, 2).?.codepoint);
}

test "prediction classification covers phase five kinds" {
    try std.testing.expectEqual(PredictionKind.printable_char, classifyPrediction("abc"));
    try std.testing.expectEqual(PredictionKind.backspace, classifyPrediction("\x7f"));
    try std.testing.expectEqual(PredictionKind.enter, classifyPrediction("\r"));
    try std.testing.expectEqual(PredictionKind.tab, classifyPrediction("\t"));
    try std.testing.expectEqual(PredictionKind.arrow_key, classifyPrediction("\x1b[A"));
    try std.testing.expectEqual(PredictionKind.readline_control, classifyPrediction("\x01"));
}

test "prediction levels gate input kinds by context" {
    var shell = try testSnapshot(std.testing.allocator, "$ ");
    defer shell.deinit();
    var config: PredictionConfig = .{};

    const shell_context = PredictionContext{
        .shell_prompt = true,
        .cursor_at_line_end = true,
    };
    try std.testing.expect(decidePrediction(shell, shell_context, "a", .safe_shell, config).allowed);
    try std.testing.expect(decidePrediction(shell, shell_context, "\x7f", .safe_shell, config).allowed);
    try std.testing.expect(decidePrediction(shell, shell_context, "\r", .safe_shell, config).allowed);
    try std.testing.expect(!decidePrediction(shell, shell_context, "\x1b[A", .safe_shell, config).allowed);
    try std.testing.expect(!decidePrediction(shell, shell_context, "\x1b[A", .readline, config).allowed);
    config.predict_arrow_keys = true;
    try std.testing.expect(decidePrediction(shell, shell_context, "\x1b[A", .readline, config).allowed);
    try std.testing.expect(!decidePrediction(shell, shell_context, "a", .disabled, config).allowed);

    shell.alternate_screen = true;
    try std.testing.expect(!decidePrediction(shell, shell_context, "a", .safe_shell, config).allowed);
    try std.testing.expect(decidePrediction(shell, shell_context, "a", .tui_insert, config).allowed);
}

test "prediction policy downgrades on conflicts and recovers after cooldown" {
    var policy: PredictionPolicyState = .{};
    const diff: ScreenDiff = .{ .mode_changed = true };
    var cells = [_]terminal.Cell{.{}};
    const snapshot = terminal.Snapshot{
        .allocator = std.testing.allocator,
        .size = .{ .cols = 1, .rows = 1 },
        .cells = cells[0..],
        .cursor = .{},
    };

    policy.observeDiff(diff, 100);
    try std.testing.expectEqual(PredictionLevel.disabled, policy.level);
    try std.testing.expect(!decidePrediction(
        snapshot,
        .{ .shell_prompt = true, .cursor_at_line_end = true },
        "a",
        policy.level,
        policy.config,
    ).allowed);

    policy.refresh(1700);
    try std.testing.expectEqual(PredictionLevel.safe_shell, policy.level);
}

test "prediction policy upgrades after stable syncs" {
    var policy: PredictionPolicyState = .{};
    for (0..12) |_| {
        policy.observeDiff(.{}, 100);
    }
    try std.testing.expectEqual(PredictionLevel.readline, policy.level);
}

test "tui insert prediction writes alternate screen cells" {
    var real = try testSnapshot(std.testing.allocator, "");
    defer real.deinit();
    real.alternate_screen = true;

    var state = DualState.init(std.testing.allocator);
    defer state.deinit();
    state.prediction_policy.level = .tui_insert;
    _ = try state.syncReal(real);
    _ = try state.recordLocalInput("v", 100);

    try std.testing.expectEqual(@as(u21, 'v'), state.predictedSnapshot().?.cellAt(0, 0).?.codepoint);
    try std.testing.expectEqual(@as(u16, 1), state.predictedSnapshot().?.cursor.col);
}

test "enter prediction is conservative cursor movement" {
    var real = try testSnapshot(std.testing.allocator, "");
    defer real.deinit();
    const old_cells = real.cells;
    const cells = try std.testing.allocator.alloc(terminal.Cell, 16);
    @memset(cells, .{});
    std.testing.allocator.free(old_cells);
    real.cells = cells;
    real.size = .{ .cols = 8, .rows = 2 };

    var state = DualState.init(std.testing.allocator);
    defer state.deinit();
    state.prediction_policy.level = .tui_insert;
    _ = try state.syncReal(real);
    _ = try state.recordLocalInput("\r", 100);

    try std.testing.expectEqual(@as(u16, 1), state.predictedSnapshot().?.cursor.row);
    try std.testing.expectEqual(@as(u16, 0), state.predictedSnapshot().?.cursor.col);
}

test "diff score chooses rollback actions" {
    var diff: ScreenDiff = .{ .cell_mismatches = 2 };
    try std.testing.expectEqual(ReconcileAction.patch, assessDiff(diff, .{}).action);

    diff = .{ .cell_mismatches = 40 };
    try std.testing.expectEqual(ReconcileAction.partial_rollback, assessDiff(diff, .{}).action);

    diff = .{ .scrollback_changed = true };
    try std.testing.expectEqual(ReconcileAction.full_rollback, assessDiff(diff, .{}).action);

    diff = .{ .cell_mismatches = 300 };
    try std.testing.expectEqual(ReconcileAction.disable_temporarily, assessDiff(diff, .{}).action);
}

test "rtt sampler suggests prediction levels" {
    var sampler: RttSampler = .{};
    var config: PredictionConfig = .{};
    sampler.observe(20);
    try std.testing.expectEqual(PredictionLevel.safe_shell, sampler.suggestedLevel(config));
    sampler.observe(300);
    sampler.observe(300);
    sampler.observe(300);
    try std.testing.expectEqual(PredictionLevel.tui_insert, sampler.suggestedLevel(config));

    config.mode = .off;
    try std.testing.expectEqual(PredictionLevel.disabled, sampler.suggestedLevel(config));
}

test "prediction config controls policy and decisions" {
    var config: PredictionConfig = .{ .enabled = false };
    try std.testing.expectEqual(PredictionLevel.disabled, config.baseLevel());

    config = .{ .mode = .aggressive };
    try std.testing.expectEqual(PredictionLevel.tui_insert, config.baseLevel());

    var shell = try testSnapshot(std.testing.allocator, "$ ");
    defer shell.deinit();
    config.predict_printable = false;
    try std.testing.expect(!decidePrediction(shell, .{ .shell_prompt = true, .cursor_at_line_end = true }, "a", .safe_shell, config).allowed);
}

test "remote agent plan stays disabled unless state diff is available" {
    const disabled: RemoteAgentPlan = .{};
    try std.testing.expect(!disabled.available());

    const proposed: RemoteAgentPlan = .{
        .mode = .proposed,
        .protocol_version = 1,
        .supports_state_diff = true,
        .supports_reconnect = true,
    };
    try std.testing.expect(proposed.available());
}
