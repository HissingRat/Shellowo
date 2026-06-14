const std = @import("std");

const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const Argon2 = std.crypto.pwhash.argon2;

pub const Error = error{
    InvalidVault,
    UnsupportedVault,
    AuthenticationFailed,
};

const format_name = "shellowo-profile-vault";
const version: u32 = 1;
const kdf_name = "argon2id";
const aead_name = "xchacha20-poly1305";
const salt_len = 16;
const ad = "Shellowo profile vault v1";
const kdf_params = Argon2.Params.owasp_2id;

const VaultFile = struct {
    encrypted: bool = false,
    format: []const u8 = "",
    version: u32 = 0,
    kdf: Kdf = .{},
    aead: AeadConfig = .{},
    ciphertext: []const u8 = "",
};

const Kdf = struct {
    name: []const u8 = "",
    mem_kib: u32 = 0,
    iterations: u32 = 0,
    parallelism: u24 = 0,
    salt: []const u8 = "",
};

const AeadConfig = struct {
    name: []const u8 = "",
    nonce: []const u8 = "",
};

pub fn isVaultJson(allocator: std.mem.Allocator, bytes: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, bytes, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '{') return false;

    const parsed = std.json.parseFromSlice(VaultFile, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return false;
    defer parsed.deinit();

    return parsed.value.encrypted and std.mem.eql(u8, parsed.value.format, format_name);
}

pub fn encryptProfilesJson(allocator: std.mem.Allocator, io: std.Io, profiles_json: []const u8, password: []const u8) ![]u8 {
    var salt: [salt_len]u8 = undefined;
    io.random(&salt);
    var nonce: [Aead.nonce_length]u8 = undefined;
    io.random(&nonce);

    var key: [Aead.key_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &key);
    try deriveKey(allocator, io, &key, password, &salt, kdf_params);

    var sealed = try allocator.alloc(u8, profiles_json.len + Aead.tag_length);
    errdefer allocator.free(sealed);
    var tag: [Aead.tag_length]u8 = undefined;
    Aead.encrypt(sealed[0..profiles_json.len], &tag, profiles_json, ad, nonce, key);
    @memcpy(sealed[profiles_json.len..], &tag);
    defer allocator.free(sealed);

    const salt_b64 = try base64Alloc(allocator, &salt);
    defer allocator.free(salt_b64);
    const nonce_b64 = try base64Alloc(allocator, &nonce);
    defer allocator.free(nonce_b64);
    const ciphertext_b64 = try base64Alloc(allocator, sealed);
    defer allocator.free(ciphertext_b64);

    const vault = VaultFile{
        .encrypted = true,
        .format = format_name,
        .version = version,
        .kdf = .{
            .name = kdf_name,
            .mem_kib = kdf_params.m,
            .iterations = kdf_params.t,
            .parallelism = kdf_params.p,
            .salt = salt_b64,
        },
        .aead = .{
            .name = aead_name,
            .nonce = nonce_b64,
        },
        .ciphertext = ciphertext_b64,
    };
    return std.json.Stringify.valueAlloc(allocator, vault, .{ .whitespace = .indent_2 });
}

pub fn decryptProfilesJson(allocator: std.mem.Allocator, io: std.Io, vault_json: []const u8, password: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(VaultFile, allocator, vault_json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return Error.InvalidVault;
    defer parsed.deinit();

    const vault = parsed.value;
    if (!vault.encrypted) return Error.InvalidVault;
    if (!std.mem.eql(u8, vault.format, format_name) or vault.version != version) return Error.UnsupportedVault;
    if (!std.mem.eql(u8, vault.kdf.name, kdf_name)) return Error.UnsupportedVault;
    if (!std.mem.eql(u8, vault.aead.name, aead_name)) return Error.UnsupportedVault;
    if (vault.kdf.mem_kib == 0 or vault.kdf.iterations == 0 or vault.kdf.parallelism == 0) return Error.InvalidVault;

    const salt = try base64DecodeAlloc(allocator, vault.kdf.salt);
    defer allocator.free(salt);
    const nonce_bytes = try base64DecodeAlloc(allocator, vault.aead.nonce);
    defer allocator.free(nonce_bytes);
    const sealed = try base64DecodeAlloc(allocator, vault.ciphertext);
    defer allocator.free(sealed);
    if (nonce_bytes.len != Aead.nonce_length or sealed.len < Aead.tag_length) return Error.InvalidVault;

    var nonce: [Aead.nonce_length]u8 = undefined;
    @memcpy(&nonce, nonce_bytes[0..Aead.nonce_length]);
    const ciphertext_len = sealed.len - Aead.tag_length;
    const ciphertext = sealed[0..ciphertext_len];
    const tag = sealed[ciphertext_len..][0..Aead.tag_length].*;

    var key: [Aead.key_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &key);
    try deriveKey(allocator, io, &key, password, salt, .{
        .m = vault.kdf.mem_kib,
        .t = vault.kdf.iterations,
        .p = vault.kdf.parallelism,
    });

    const profiles_json = try allocator.alloc(u8, ciphertext_len);
    errdefer allocator.free(profiles_json);
    Aead.decrypt(profiles_json, ciphertext, tag, ad, nonce, key) catch return Error.AuthenticationFailed;
    return profiles_json;
}

fn deriveKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    key: *[Aead.key_length]u8,
    password: []const u8,
    salt: []const u8,
    params: Argon2.Params,
) !void {
    try Argon2.kdf(allocator, key, password, salt, params, .argon2id, io);
}

fn base64Alloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const len = std.base64.standard.Encoder.calcSize(bytes.len);
    const out = try allocator.alloc(u8, len);
    _ = std.base64.standard.Encoder.encode(out, bytes);
    return out;
}

fn base64DecodeAlloc(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const len = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    const out = try allocator.alloc(u8, len);
    errdefer allocator.free(out);
    try std.base64.standard.Decoder.decode(out, encoded);
    return out;
}

test "profile vault round trips json and rejects wrong password" {
    const allocator = std.testing.allocator;
    const plain = "[{\"name\":\"lab\",\"password\":\"pw\"}]";
    const vault = try encryptProfilesJson(allocator, std.testing.io, plain, "correct horse");
    defer allocator.free(vault);

    try std.testing.expect(isVaultJson(allocator, vault));

    const decrypted = try decryptProfilesJson(allocator, std.testing.io, vault, "correct horse");
    defer allocator.free(decrypted);
    try std.testing.expectEqualStrings(plain, decrypted);

    try std.testing.expectError(Error.AuthenticationFailed, decryptProfilesJson(allocator, std.testing.io, vault, "wrong horse"));
}
