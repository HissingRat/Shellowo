const dvui = @import("dvui");

pub fn keyBytes(key: dvui.Event.Key, control_buffer: *[1]u8) ?[]const u8 {
    if (controlByteForEvent(key)) |byte| {
        control_buffer[0] = byte;
        return control_buffer[0..1];
    }
    return switch (key.code) {
        .enter, .kp_enter => "\r",
        .backspace => "\x7f",
        .tab => "\t",
        .escape => "\x1b",
        .up => "\x1b[A",
        .down => "\x1b[B",
        .right => "\x1b[C",
        .left => "\x1b[D",
        .home => "\x1b[H",
        .end => "\x1b[F",
        .page_up => "\x1b[5~",
        .page_down => "\x1b[6~",
        .delete => "\x1b[3~",
        else => null,
    };
}

pub fn isControlBytes(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes) |byte| {
        if (byte == '\t' or byte == '\n' or byte == '\r') continue;
        if (byte >= 0x20 or byte == 0x1b) return false;
    }
    return true;
}

pub fn controlByteForEvent(key: dvui.Event.Key) ?u8 {
    if (!key.mod.control() or key.mod.alt()) return null;
    return controlByte(key.code);
}

fn controlByte(key: dvui.enums.Key) ?u8 {
    return switch (key) {
        .a => 0x01,
        .b => 0x02,
        .c => 0x03,
        .d => 0x04,
        .e => 0x05,
        .f => 0x06,
        .g => 0x07,
        .h => 0x08,
        .i => 0x09,
        .j => 0x0a,
        .k => 0x0b,
        .l => 0x0c,
        .m => 0x0d,
        .n => 0x0e,
        .o => 0x0f,
        .p => 0x10,
        .q => 0x11,
        .r => 0x12,
        .s => 0x13,
        .t => 0x14,
        .u => 0x15,
        .v => 0x16,
        .w => 0x17,
        .x => 0x18,
        .y => 0x19,
        .z => 0x1a,
        .left_bracket => 0x1b,
        .backslash => 0x1c,
        .right_bracket => 0x1d,
        else => null,
    };
}
