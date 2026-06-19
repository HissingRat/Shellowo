pub const State = enum(u8) {
    idle,
    starting,
    resolving,
    connecting,
    verifying_host_key,
    authenticating,
    opening_shell,
    connected,
    stopping,
    stopped,
    failed,
};
