const std = @import("std");

const remote_file = @import("../../../core/remote_file.zig");

pub fn sizeText(entry: remote_file.RemoteFileEntry, buf: []u8) []const u8 {
    if (entry.kind == .directory) return "-";
    const size = entry.size orelse return "-";
    if (size < 1024) return std.fmt.bufPrint(buf, "{d} B", .{size}) catch "-";
    if (size < 1024 * 1024) return std.fmt.bufPrint(buf, "{d} KB", .{(size + 1023) / 1024}) catch "-";
    if (size < 1024 * 1024 * 1024) return std.fmt.bufPrint(buf, "{d} MB", .{(size + 1024 * 1024 - 1) / (1024 * 1024)}) catch "-";
    return std.fmt.bufPrint(buf, "{d} GB", .{(size + 1024 * 1024 * 1024 - 1) / (1024 * 1024 * 1024)}) catch "-";
}

pub fn modifiedText(entry: remote_file.RemoteFileEntry, buf: []u8) []const u8 {
    const modified_unix = entry.modified_unix orelse return "-";
    if (modified_unix < 0) return "-";
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(modified_unix) };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        year_day.year,
        @intFromEnum(month_day.month),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
    }) catch "-";
}

pub fn permissionText(entry: remote_file.RemoteFileEntry, buf: *[12]u8) []const u8 {
    const permissions = entry.permissions orelse return "-";
    buf[0] = switch (entry.kind) {
        .directory => 'd',
        .symlink => 'l',
        else => '-',
    };
    const bits = permissions & 0o777;
    const chars = "rwxrwxrwx";
    for (0..9) |idx| {
        const bit: u32 = @as(u32, 1) << @intCast(8 - idx);
        buf[idx + 1] = if ((bits & bit) != 0) chars[idx] else '-';
    }
    return buf[0..10];
}

pub fn ownerText(entry: remote_file.RemoteFileEntry, buf: []u8) []const u8 {
    if (entry.uid) |uid| {
        if (entry.gid) |gid| return std.fmt.bufPrint(buf, "{d}/{d}", .{ uid, gid }) catch "-";
        return std.fmt.bufPrint(buf, "{d}/-", .{uid}) catch "-";
    }
    if (entry.gid) |gid| return std.fmt.bufPrint(buf, "-/{d}", .{gid}) catch "-";
    return "-";
}
