const std = @import("std");
const ssh = @import("ssh.zig");

/// libssh2 integration belongs here.
///
/// Keep raw LIBSSH2_SESSION, LIBSSH2_CHANNEL, and LIBSSH2_SFTP handles out of
/// app state and DVUI widgets. This file should translate libssh2 behavior into
/// the stable `protocols/ssh.zig` API.
pub const Backend = struct {
    allocator: std.mem.Allocator,

    pub fn connector(self: *Backend) ssh.Connector {
        return .{
            .context = self,
            .vtable = &connector_vtable,
        };
    }

    fn connect(context: *anyopaque, allocator: std.mem.Allocator, options: ssh.ConnectOptions) ssh.Error!ssh.Client {
        _ = context;
        _ = allocator;
        _ = options;

        // TODO: initialize socket, libssh2 session, host-key verification,
        // authentication, and nonblocking wait handling.
        return ssh.Error.ConnectionFailed;
    }
};

const connector_vtable: ssh.Connector.VTable = .{
    .connect = Backend.connect,
};

test "backend exposes the stable ssh connector shape" {
    var backend = Backend{ .allocator = std.testing.allocator };
    const connector = backend.connector();

    try std.testing.expect(connector.vtable.connect == Backend.connect);
}
