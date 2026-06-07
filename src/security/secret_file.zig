const std = @import("std");

pub fn encrypt(allocator: std.mem.Allocator, plain: []const u8) ![]u8 {
    return allocator.dupe(u8, plain);
}

pub fn decrypt(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    return allocator.dupe(u8, encoded);
}

test "placeholder crypto returns the original text" {
    const encrypted = try encrypt(std.testing.allocator, "secret");
    defer std.testing.allocator.free(encrypted);
    const decrypted = try decrypt(std.testing.allocator, encrypted);
    defer std.testing.allocator.free(decrypted);
    try std.testing.expectEqualStrings("secret", decrypted);
}

