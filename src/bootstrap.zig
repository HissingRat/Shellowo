//! Application composition root.
//!
//! Concrete backends are assembled here so application state and runtime code
//! only depend on Shellow-owned contracts.

const std = @import("std");

const App = @import("app/App.zig");
const libssh2_backend = @import("backends/ssh/libssh2.zig");
const libvterm_backend = @import("backends/terminal/libvterm.zig");
const terminal = @import("contracts/terminal_emulator.zig");
const ssh_session = @import("runtime/sessions/ssh_session.zig");

pub const RuntimeBackends = struct {
    ssh: libssh2_backend.Backend,
    terminal: libvterm_backend.Backend,

    pub fn init(allocator: std.mem.Allocator) RuntimeBackends {
        return .{
            .ssh = .{ .allocator = allocator },
            .terminal = .{ .allocator = allocator },
        };
    }

    pub fn dependencies(self: *RuntimeBackends) App.Dependencies {
        return .{
            .ssh_connector = self.ssh.connector(),
            .terminal_factory = terminalFactory(&self.terminal),
        };
    }
};

fn terminalFactory(backend: *libvterm_backend.Backend) ssh_session.TerminalFactory {
    return .{
        .context = backend,
        .vtable = &terminal_factory_vtable,
    };
}

fn createTerminal(context: *anyopaque, allocator: std.mem.Allocator, size: terminal.Size) terminal.Error!terminal.Emulator {
    _ = allocator;
    const backend: *libvterm_backend.Backend = @ptrCast(@alignCast(context));
    return backend.create(size);
}

const terminal_factory_vtable: ssh_session.TerminalFactory.VTable = .{
    .create = createTerminal,
};
