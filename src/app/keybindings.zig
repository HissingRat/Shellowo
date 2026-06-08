const builtin = @import("builtin");
const dvui = @import("dvui");
const std = @import("std");

pub const Platform = enum {
    macos,
    windows,
    linux,
};

pub const Scope = enum {
    app,
    terminal,
};

pub const Status = enum {
    implemented,
    planned,
};

pub const ShortcutAction = enum {
    copy_selection,
    paste_clipboard,
    new_tab,
    close_tab,
    restore_closed_tab,
    next_tab,
    previous_tab,
    tab_1_to_9,
    new_connection,
    new_window,
    quit,
    force_quit,
    fullscreen,
    terminal_search,
    settings,
    command_palette,
    global_search,
    palette,
    font_increase,
    font_decrease,
    font_reset,
    reconnect,
    clear_scrollback,
    split_horizontal,
    split_vertical,
    save_session,
    save_session_as,
    open_session,
    upload_file,
    upload_directory,
    download_file,
};

pub const TerminalShortcut = enum {
    copy_selection,
    paste_clipboard,
    terminal_search,
};

pub const Shortcut = struct {
    action: ShortcutAction,
    scope: Scope,
    status: Status,
    category: []const u8,
    label: []const u8,
    macos: []const u8,
    windows_linux: []const u8,
};

pub const KeyStroke = struct {
    key: dvui.enums.Key,
    control: bool = false,
    shift: bool = false,
    alt: bool = false,
    command: bool = false,
};

pub fn currentPlatform() Platform {
    return switch (builtin.os.tag) {
        .macos => .macos,
        .windows => .windows,
        else => .linux,
    };
}

pub fn all() []const Shortcut {
    return shortcuts[0..];
}

pub fn fromEvent(key: dvui.Event.Key) KeyStroke {
    return .{
        .key = key.code,
        .control = key.mod.control(),
        .shift = key.mod.shift(),
        .alt = key.mod.alt(),
        .command = key.mod.command(),
    };
}

pub fn terminalShortcut(key: dvui.Event.Key) ?TerminalShortcut {
    return terminalShortcutForPlatform(currentPlatform(), fromEvent(key));
}

pub fn terminalShortcutForPlatform(platform: Platform, stroke: KeyStroke) ?TerminalShortcut {
    return switch (platform) {
        .macos => terminalShortcutMacos(stroke),
        .windows, .linux => terminalShortcutWindowsLinux(stroke),
    };
}

fn terminalShortcutMacos(stroke: KeyStroke) ?TerminalShortcut {
    if (stroke.control or stroke.alt or !stroke.command) return null;
    return switch (stroke.key) {
        .c => if (!stroke.shift) .copy_selection else null,
        .f => if (!stroke.shift) .terminal_search else null,
        .v => if (!stroke.shift) .paste_clipboard else null,
        else => null,
    };
}

fn terminalShortcutWindowsLinux(stroke: KeyStroke) ?TerminalShortcut {
    if (stroke.command or stroke.alt) return null;
    if (stroke.control and !stroke.shift and stroke.key == .f) return .terminal_search;
    if (stroke.control and stroke.shift) {
        return switch (stroke.key) {
            .c => .copy_selection,
            .v => .paste_clipboard,
            else => null,
        };
    }
    if (!stroke.shift and stroke.control and stroke.key == .insert) return .copy_selection;
    if (stroke.shift and !stroke.control and stroke.key == .insert) return .paste_clipboard;
    return null;
}

pub const shortcuts = [_]Shortcut{
    .{ .action = .copy_selection, .scope = .terminal, .status = .implemented, .category = "Copy and Paste", .label = "Copy selection", .macos = "Command+C", .windows_linux = "Ctrl+Shift+C / Ctrl+Insert" },
    .{ .action = .paste_clipboard, .scope = .terminal, .status = .implemented, .category = "Copy and Paste", .label = "Paste", .macos = "Command+V", .windows_linux = "Ctrl+Shift+V / Shift+Insert" },
    .{ .action = .new_tab, .scope = .app, .status = .planned, .category = "Tabs", .label = "New tab", .macos = "Command+T", .windows_linux = "Ctrl+T" },
    .{ .action = .close_tab, .scope = .app, .status = .planned, .category = "Tabs", .label = "Close current tab", .macos = "Command+W", .windows_linux = "Ctrl+W" },
    .{ .action = .restore_closed_tab, .scope = .app, .status = .planned, .category = "Tabs", .label = "Restore closed tab", .macos = "Command+Shift+T", .windows_linux = "Ctrl+Shift+T" },
    .{ .action = .next_tab, .scope = .app, .status = .planned, .category = "Tabs", .label = "Next tab", .macos = "Command+Tab / Command+Right", .windows_linux = "Ctrl+Tab / Ctrl+Right" },
    .{ .action = .previous_tab, .scope = .app, .status = .planned, .category = "Tabs", .label = "Previous tab", .macos = "Command+Shift+Tab / Command+Left", .windows_linux = "Ctrl+Shift+Tab / Ctrl+Left" },
    .{ .action = .tab_1_to_9, .scope = .app, .status = .planned, .category = "Tabs", .label = "Switch to tab 1-9", .macos = "Command+1-9", .windows_linux = "Ctrl+1-9" },
    .{ .action = .new_connection, .scope = .app, .status = .planned, .category = "Window", .label = "New connection", .macos = "Command+N", .windows_linux = "Ctrl+N" },
    .{ .action = .new_window, .scope = .app, .status = .planned, .category = "Window", .label = "New window", .macos = "Command+Shift+N", .windows_linux = "Ctrl+Shift+N" },
    .{ .action = .quit, .scope = .app, .status = .planned, .category = "Window", .label = "Quit", .macos = "Command+Q", .windows_linux = "Ctrl+Q" },
    .{ .action = .force_quit, .scope = .app, .status = .planned, .category = "Window", .label = "Force quit", .macos = "Command+Shift+Q", .windows_linux = "Ctrl+Shift+Q" },
    .{ .action = .fullscreen, .scope = .app, .status = .planned, .category = "Window", .label = "Fullscreen", .macos = "Control+Command+F", .windows_linux = "F11" },
    .{ .action = .terminal_search, .scope = .terminal, .status = .implemented, .category = "Search and Settings", .label = "Search terminal", .macos = "Command+F", .windows_linux = "Ctrl+F" },
    .{ .action = .settings, .scope = .app, .status = .planned, .category = "Search and Settings", .label = "Open settings", .macos = "Command+,", .windows_linux = "Ctrl+," },
    .{ .action = .command_palette, .scope = .app, .status = .planned, .category = "Search and Settings", .label = "Command palette", .macos = "Command+P", .windows_linux = "Ctrl+P" },
    .{ .action = .global_search, .scope = .app, .status = .planned, .category = "Search and Settings", .label = "Global search", .macos = "Command+Shift+F", .windows_linux = "Ctrl+Shift+F" },
    .{ .action = .palette, .scope = .app, .status = .planned, .category = "Search and Settings", .label = "Palette", .macos = "Command+Shift+P", .windows_linux = "Ctrl+Shift+P" },
    .{ .action = .font_increase, .scope = .terminal, .status = .planned, .category = "Font", .label = "Increase font size", .macos = "Command+=", .windows_linux = "Ctrl+=" },
    .{ .action = .font_decrease, .scope = .terminal, .status = .planned, .category = "Font", .label = "Decrease font size", .macos = "Command+-", .windows_linux = "Ctrl+-" },
    .{ .action = .font_reset, .scope = .terminal, .status = .planned, .category = "Font", .label = "Reset font size", .macos = "Command+0", .windows_linux = "Ctrl+0" },
    .{ .action = .reconnect, .scope = .terminal, .status = .planned, .category = "Terminal", .label = "Reconnect session", .macos = "Command+Shift+R", .windows_linux = "Ctrl+Shift+R" },
    .{ .action = .clear_scrollback, .scope = .terminal, .status = .planned, .category = "Terminal", .label = "Clear scrollback", .macos = "Command+Shift+L", .windows_linux = "Ctrl+Shift+L" },
    .{ .action = .split_horizontal, .scope = .terminal, .status = .planned, .category = "Terminal", .label = "Split horizontal", .macos = "Command+D", .windows_linux = "Ctrl+D" },
    .{ .action = .split_vertical, .scope = .terminal, .status = .planned, .category = "Terminal", .label = "Split vertical", .macos = "Command+Shift+D", .windows_linux = "Ctrl+Shift+D" },
    .{ .action = .save_session, .scope = .app, .status = .planned, .category = "Session", .label = "Save session", .macos = "Command+S", .windows_linux = "Ctrl+S" },
    .{ .action = .save_session_as, .scope = .app, .status = .planned, .category = "Session", .label = "Save session as", .macos = "Command+Shift+S", .windows_linux = "Ctrl+Shift+S" },
    .{ .action = .open_session, .scope = .app, .status = .planned, .category = "Session", .label = "Open session", .macos = "Command+O", .windows_linux = "Ctrl+O" },
    .{ .action = .upload_file, .scope = .app, .status = .planned, .category = "File Transfer", .label = "Upload file", .macos = "Command+U", .windows_linux = "Ctrl+U" },
    .{ .action = .upload_directory, .scope = .app, .status = .planned, .category = "File Transfer", .label = "Upload directory", .macos = "Command+Shift+U", .windows_linux = "Ctrl+Shift+U" },
    .{ .action = .download_file, .scope = .app, .status = .planned, .category = "File Transfer", .label = "Download file", .macos = "Command+J", .windows_linux = "Ctrl+J" },
};

test "terminal copy and paste shortcuts preserve remote control keys" {
    try std.testing.expectEqual(@as(?TerminalShortcut, .copy_selection), terminalShortcutForPlatform(.macos, .{ .key = .c, .command = true }));
    try std.testing.expectEqual(@as(?TerminalShortcut, .paste_clipboard), terminalShortcutForPlatform(.macos, .{ .key = .v, .command = true }));
    try std.testing.expectEqual(@as(?TerminalShortcut, .terminal_search), terminalShortcutForPlatform(.macos, .{ .key = .f, .command = true }));
    try std.testing.expectEqual(@as(?TerminalShortcut, null), terminalShortcutForPlatform(.macos, .{ .key = .c, .control = true }));

    try std.testing.expectEqual(@as(?TerminalShortcut, .copy_selection), terminalShortcutForPlatform(.linux, .{ .key = .c, .control = true, .shift = true }));
    try std.testing.expectEqual(@as(?TerminalShortcut, .paste_clipboard), terminalShortcutForPlatform(.linux, .{ .key = .v, .control = true, .shift = true }));
    try std.testing.expectEqual(@as(?TerminalShortcut, .terminal_search), terminalShortcutForPlatform(.linux, .{ .key = .f, .control = true }));
    try std.testing.expectEqual(@as(?TerminalShortcut, null), terminalShortcutForPlatform(.linux, .{ .key = .c, .control = true }));
}

test "terminal insert compatibility shortcuts" {
    try std.testing.expectEqual(@as(?TerminalShortcut, .copy_selection), terminalShortcutForPlatform(.windows, .{ .key = .insert, .control = true }));
    try std.testing.expectEqual(@as(?TerminalShortcut, .paste_clipboard), terminalShortcutForPlatform(.windows, .{ .key = .insert, .shift = true }));
}
