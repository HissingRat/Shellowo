pub const TransferDirection = enum {
    upload,
    download,
};

pub const TransferStatus = enum {
    pending,
    running,
    completed,
    failed,
    canceled,

    pub fn label(self: TransferStatus) []const u8 {
        return switch (self) {
            .pending => "pending",
            .running => "running",
            .completed => "completed",
            .failed => "failed",
            .canceled => "canceled",
        };
    }
};

pub const TransferTask = struct {
    id: u64,
    title: []const u8,
    direction: TransferDirection,
    status: TransferStatus,
    progress: f32,
};

