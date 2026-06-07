comptime {
    _ = @import("app/App.zig");
    _ = @import("core/profile.zig");
    _ = @import("protocols/libssh2_backend.zig");
    _ = @import("protocols/ssh.zig");
    _ = @import("security/secret_file.zig");
}
