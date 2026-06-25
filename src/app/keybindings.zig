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
    editor,
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
    reconnect,
    clear_scrollback,
    save_session,
    save_session_as,
    open_session,
    upload_file,
    upload_directory,
    download_file,
    editor_undo,
    editor_redo,
    editor_save,
    editor_find,
    editor_close,
};

pub const TerminalShortcut = enum {
    copy_selection,
    paste_clipboard,
    terminal_search,
};

pub const EditorShortcut = enum {
    undo,
    redo,
    save,
    find,
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

pub fn editorShortcut(key: dvui.Event.Key) ?EditorShortcut {
    return editorShortcutForPlatform(currentPlatform(), fromEvent(key));
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

pub fn editorShortcutForPlatform(platform: Platform, stroke: KeyStroke) ?EditorShortcut {
    return switch (platform) {
        .macos => editorShortcutMacos(stroke),
        .windows, .linux => editorShortcutWindowsLinux(stroke),
    };
}

fn editorShortcutMacos(stroke: KeyStroke) ?EditorShortcut {
    if (plainControl(stroke)) {
        return switch (stroke.key) {
            .z => .undo,
            .y => .redo,
            else => null,
        };
    }
    if (plainCommand(stroke)) {
        return switch (stroke.key) {
            .z => .undo,
            .y => .redo,
            .s => .save,
            .f => .find,
            else => null,
        };
    }
    if (!stroke.control and !stroke.alt and stroke.command and stroke.shift and stroke.key == .z) return .redo;
    return null;
}

fn editorShortcutWindowsLinux(stroke: KeyStroke) ?EditorShortcut {
    if (!plainControl(stroke)) return null;
    return switch (stroke.key) {
        .z => .undo,
        .y => .redo,
        .s => .save,
        .f => .find,
        else => null,
    };
}

fn plainControl(stroke: KeyStroke) bool {
    return stroke.control and !stroke.command and !stroke.shift and !stroke.alt;
}

fn plainCommand(stroke: KeyStroke) bool {
    return stroke.command and !stroke.control and !stroke.shift and !stroke.alt;
}

pub const shortcuts = [_]Shortcut{
    .{ .action = .editor_undo, .scope = .editor, .status = .implemented, .category = "Editor", .label = "Undo edit", .macos = "Command+Z / Ctrl+Z", .windows_linux = "Ctrl+Z" },
    .{ .action = .editor_redo, .scope = .editor, .status = .implemented, .category = "Editor", .label = "Redo edit", .macos = "Command+Shift+Z / Command+Y / Ctrl+Y", .windows_linux = "Ctrl+Y" },
    .{ .action = .editor_save, .scope = .editor, .status = .implemented, .category = "Editor", .label = "Save remote file", .macos = "Command+S", .windows_linux = "Ctrl+S" },
    .{ .action = .editor_find, .scope = .editor, .status = .implemented, .category = "Editor", .label = "Find in editor", .macos = "Command+F", .windows_linux = "Ctrl+F" },
    .{ .action = .editor_close, .scope = .editor, .status = .implemented, .category = "Editor", .label = "Close editor prompt", .macos = "Esc", .windows_linux = "Esc" },
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
    .{ .action = .reconnect, .scope = .terminal, .status = .planned, .category = "Terminal", .label = "Reconnect session", .macos = "Command+Shift+R", .windows_linux = "Ctrl+Shift+R" },
    .{ .action = .clear_scrollback, .scope = .terminal, .status = .planned, .category = "Terminal", .label = "Clear scrollback", .macos = "Command+Shift+L", .windows_linux = "Ctrl+Shift+L" },
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

test "editor undo and redo shortcuts include requested control keys" {
    try std.testing.expectEqual(@as(?EditorShortcut, .undo), editorShortcutForPlatform(.macos, .{ .key = .z, .control = true }));
    try std.testing.expectEqual(@as(?EditorShortcut, .redo), editorShortcutForPlatform(.macos, .{ .key = .y, .control = true }));
    try std.testing.expectEqual(@as(?EditorShortcut, .undo), editorShortcutForPlatform(.macos, .{ .key = .z, .command = true }));
    try std.testing.expectEqual(@as(?EditorShortcut, .redo), editorShortcutForPlatform(.macos, .{ .key = .z, .command = true, .shift = true }));

    try std.testing.expectEqual(@as(?EditorShortcut, .undo), editorShortcutForPlatform(.linux, .{ .key = .z, .control = true }));
    try std.testing.expectEqual(@as(?EditorShortcut, .redo), editorShortcutForPlatform(.linux, .{ .key = .y, .control = true }));
    try std.testing.expectEqual(@as(?EditorShortcut, null), editorShortcutForPlatform(.linux, .{ .key = .z, .control = true, .shift = true }));
}
