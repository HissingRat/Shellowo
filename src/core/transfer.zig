pub const TransferDirection = enum {
    upload,
    download,
};

pub const max_error_summary: usize = 192;

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
    tab_id: u64,
    title: []const u8,
    direction: TransferDirection,
    status: TransferStatus,
    progress: f32,
    bytes_done: u64 = 0,
    bytes_total: ?u64 = null,
    bytes_per_sec: f32 = 0,
    started_ns: i128 = 0,
    finished_ns: ?i128 = null,
    last_sample_ns: i128 = 0,
    last_sample_bytes: u64 = 0,
    attempt: u16 = 1,
    error_summary: [max_error_summary]u8 = undefined,
    error_len: usize = 0,

    pub fn errorSummary(self: *const TransferTask) ?[]const u8 {
        return if (self.error_len > 0) self.error_summary[0..self.error_len] else null;
    }
};

pub const TransferProgress = struct {
    id: u64,
    status: TransferStatus,
    progress: f32,
    bytes_done: u64 = 0,
    bytes_total: ?u64 = null,
    error_summary: [max_error_summary]u8 = undefined,
    error_len: usize = 0,

    pub fn errorSummary(self: *const TransferProgress) ?[]const u8 {
        return if (self.error_len > 0) self.error_summary[0..self.error_len] else null;
    }
};
