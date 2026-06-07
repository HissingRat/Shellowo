const profile = @import("profile.zig");

pub const WorkspaceLayout = enum {
    terminal_file,
    file_only,

    pub fn label(self: WorkspaceLayout) []const u8 {
        return switch (self) {
            .terminal_file => "Terminal + Files",
            .file_only => "Files",
        };
    }
};

pub const TabStatus = enum {
    idle,
    connecting,
    connected,
    failed,
    closed,

    pub fn label(self: TabStatus) []const u8 {
        return switch (self) {
            .idle => "idle",
            .connecting => "connecting",
            .connected => "connected",
            .failed => "failed",
            .closed => "closed",
        };
    }
};

pub const WorkspaceTab = struct {
    id: u64,
    profile_id: u64,
    session_type: profile.SessionType,
    title: []const u8,
    layout: WorkspaceLayout,
    status: TabStatus = .connected,
};

pub fn layoutFor(session_type: profile.SessionType) WorkspaceLayout {
    return switch (session_type) {
        .ssh => .terminal_file,
        .ftp => .file_only,
    };
}
