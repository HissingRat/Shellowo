const std = @import("std");
const predictive = @import("../core/terminal/predictive.zig");
const ui_theme = @import("../ui/theme.zig");

pub fn goHome(app: anytype) void {
    app.sessions.active_tab_id = null;
    app.message = "Home";
}

pub fn toggleTheme(app: anytype) void {
    setThemeMode(app, switch (app.theme_mode) {
        .dark => .light,
        .light => .dark,
    });
}

pub fn setThemeMode(app: anytype, mode: ui_theme.ThemeMode) void {
    app.theme_mode = mode;
    app.config.theme_mode = mode;
    persistConfig(app);
}

pub fn setDownloadPath(app: anytype, path: []const u8) void {
    if (path.len == 0) return;
    const owned = app.allocator.dupe(u8, path) catch {
        app.message = "Could not update download path";
        return;
    };
    app.allocator.free(app.config.download_path);
    app.config.download_path = owned;
    persistConfig(app);
}

pub fn setTerminalPredictionMode(app: anytype, mode: predictive.PredictionMode) void {
    app.config.terminal_prediction.mode = if (mode == .off) .off else .auto;
    applyTerminalPredictionConfig(app);
}

pub fn applyTerminalPredictionConfig(app: anytype) void {
    for (app.terminal_predictive_states.items) |*slot_state| {
        slot_state.state.prediction_policy.applyConfig(app.config.terminal_prediction.toCore());
    }
    persistConfig(app);
}

fn persistConfig(app: anytype) void {
    app.config.save(app.io) catch {
        app.message = "Config saved in memory, but disk write failed";
    };
}

test "settings module keeps concrete app type out of its boundary" {
    try std.testing.expect(@typeInfo(@TypeOf(goHome)).@"fn".params.len == 1);
}
