comptime {
    _ = @import("app/App.zig");
    _ = @import("app/keybindings.zig");
    _ = @import("core/profile.zig");
    _ = @import("core/terminal_slot.zig");
    _ = @import("protocols/libssh2_backend.zig");
    _ = @import("protocols/ssh.zig");
    _ = @import("security/known_hosts.zig");
    _ = @import("security/secret_file.zig");
    _ = @import("services/ssh_session.zig");
    _ = @import("services/ssh_session_worker.zig");
    _ = @import("services/ssh_workspace_worker.zig");
    _ = @import("terminal/libvterm_backend.zig");
    _ = @import("terminal/terminal.zig");
}
