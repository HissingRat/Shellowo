const ssh = @import("../contracts/ssh.zig");
const terminal = @import("../contracts/terminal_emulator.zig");

pub fn sendTerminalBytes(app: anytype, tab_id: u64, bytes: []const u8) void {
    if (bytes.len == 0) return;
    app.sessions.sendSshInput(tab_id, bytes) catch {
        app.message = "Could not send terminal input";
    };
}

pub fn sendTerminalMouse(app: anytype, tab_id: u64, event: terminal.MouseEvent) void {
    app.sessions.sendSshMouse(tab_id, event) catch {
        app.message = "Could not send terminal mouse event";
    };
}

pub fn resizeTerminal(app: anytype, tab_id: u64, size: ssh.PtySize) void {
    app.sessions.resizeSshTerminal(tab_id, size) catch {
        app.message = "Could not resize terminal";
    };
}

pub fn clearScrollback(app: anytype, tab_id: u64) void {
    app.sessions.clearSshScrollback(tab_id) catch {
        app.message = "Could not clear terminal scrollback";
    };
}

pub fn createTerminalSlot(app: anytype, tab_id: u64) void {
    app.terminal_snapshot_cache.clear();
    _ = app.sessions.createTerminalSlot(tab_id) catch {
        app.message = "Could not create terminal";
        return;
    };
    app.message = "Terminal created";
}

pub fn activateTerminalSlot(app: anytype, tab_id: u64, slot_id: u64) void {
    app.terminal_snapshot_cache.clear();
    if (!app.sessions.activateTerminalSlot(tab_id, slot_id)) {
        app.message = "Terminal not found";
        return;
    }
    app.message = "Terminal selected";
}
