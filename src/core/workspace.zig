pub const WorkspaceLayout = enum {
    terminal_file,

    pub fn label(self: WorkspaceLayout) []const u8 {
        return switch (self) {
            .terminal_file => "Terminal + Files",
        };
    }
};

pub const TabStatus = enum {
    idle,
    resolving,
    connecting,
    verifying_host_key,
    authenticating,
    opening_shell,
    connected,
    failed,
    closed,

    pub fn label(self: TabStatus) []const u8 {
        return switch (self) {
            .idle => "idle",
            .resolving => "resolving",
            .connecting => "connecting",
            .verifying_host_key => "verifying host",
            .authenticating => "authenticating",
            .opening_shell => "opening shell",
            .connected => "connected",
            .failed => "failed",
            .closed => "closed",
        };
    }
};

pub const WorkspaceTab = struct {
    id: u64,
    profile_id: u64,
    title: []const u8,
    layout: WorkspaceLayout,
    status: TabStatus = .connected,
};
