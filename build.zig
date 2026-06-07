const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const stack_size = b.option(u64, "stack-size", "Executable stack size in bytes") orelse 16 * 1024 * 1024;
    const native_deps = addNativeDeps(b, target, optimize);

    const exe = b.addExecutable(.{
        .name = "Shellowo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.stack_size = stack_size;
    attachNativeDeps(b, exe, native_deps);

    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3,
    });
    exe.root_module.addImport("dvui", dvui_dep.module("dvui_sdl3"));
    exe.root_module.addAnonymousImport("shellowo-zed-font", .{
        .root_source_file = b.path("assets/fonts/zed-mono-extended.ttf"),
    });
    exe.root_module.addAnonymousImport("shellowo-cjk-font", .{
        .root_source_file = b.path("assets/fonts/NotoSansCJKsc-Medium.otf"),
    });
    exe.root_module.addAnonymousImport("shellowo-server-icon", .{
        .root_source_file = b.path("assets/server.png"),
    });
    exe.root_module.addAnonymousImport("shellowo-settings-icon", .{
        .root_source_file = b.path("assets/settings.png"),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const tests = b.addTest(.{
        .name = "shellow-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    attachNativeDeps(b, tests, native_deps);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

const NativeDeps = struct {
    mbedcrypto: *std.Build.Step.Compile,
    libssh2: *std.Build.Step.Compile,
};

fn addNativeDeps(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) NativeDeps {
    const mbedcrypto_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const mbedcrypto = b.addLibrary(.{
        .name = "shellow_mbedcrypto",
        .root_module = mbedcrypto_module,
    });
    mbedcrypto.root_module.addIncludePath(b.path("third_party/mbedtls-3.6.6/include"));
    mbedcrypto.root_module.addIncludePath(b.path("third_party/mbedtls-3.6.6/library"));
    mbedcrypto.root_module.addCSourceFiles(.{
        .root = b.path("third_party/mbedtls-3.6.6/library"),
        .files = &mbedcrypto_sources,
        .flags = &.{
            "-D_FILE_OFFSET_BITS=64",
        },
    });

    const libssh2_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const libssh2 = b.addLibrary(.{
        .name = "shellow_libssh2",
        .root_module = libssh2_module,
    });
    libssh2.root_module.linkLibrary(mbedcrypto);
    libssh2.root_module.addIncludePath(b.path("third_party/libssh2-1.11.1/include"));
    libssh2.root_module.addIncludePath(b.path("third_party/libssh2-1.11.1/src"));
    libssh2.root_module.addIncludePath(b.path("third_party/mbedtls-3.6.6/include"));
    libssh2.root_module.addIncludePath(b.path("third_party/mbedtls-3.6.6/library"));
    libssh2.root_module.addCSourceFiles(.{
        .root = b.path("third_party/libssh2-1.11.1/src"),
        .files = &libssh2_sources,
        .flags = &.{
            "-DLIBSSH2_MBEDTLS",
            "-DLIBSSH2_LIBRARY",
            "-D_FILE_OFFSET_BITS=64",
        },
    });

    return .{
        .mbedcrypto = mbedcrypto,
        .libssh2 = libssh2,
    };
}

fn attachNativeDeps(b: *std.Build, compile: *std.Build.Step.Compile, native_deps: NativeDeps) void {
    compile.root_module.link_libc = true;
    compile.root_module.linkLibrary(native_deps.libssh2);
    compile.root_module.linkLibrary(native_deps.mbedcrypto);
    compile.root_module.addIncludePath(b.path("third_party/libssh2-1.11.1/include"));
    compile.root_module.addIncludePath(b.path("third_party/mbedtls-3.6.6/include"));

    if (compile.root_module.resolved_target.?.result.os.tag == .windows) {
        compile.root_module.linkSystemLibrary("bcrypt", .{});
        compile.root_module.linkSystemLibrary("ws2_32", .{});
    }
}

const libssh2_sources = [_][]const u8{
    "agent.c",
    "bcrypt_pbkdf.c",
    "channel.c",
    "comp.c",
    "chacha.c",
    "cipher-chachapoly.c",
    "crypt.c",
    "crypto.c",
    "global.c",
    "hostkey.c",
    "keepalive.c",
    "kex.c",
    "knownhost.c",
    "mac.c",
    "misc.c",
    "packet.c",
    "pem.c",
    "poly1305.c",
    "publickey.c",
    "scp.c",
    "session.c",
    "sftp.c",
    "transport.c",
    "userauth.c",
    "userauth_kbd_packet.c",
    "version.c",
};

const mbedcrypto_sources = [_][]const u8{
    "aes.c",
    "aesni.c",
    "aesce.c",
    "aria.c",
    "asn1parse.c",
    "asn1write.c",
    "base64.c",
    "bignum.c",
    "bignum_core.c",
    "bignum_mod.c",
    "bignum_mod_raw.c",
    "block_cipher.c",
    "camellia.c",
    "ccm.c",
    "chacha20.c",
    "chachapoly.c",
    "cipher.c",
    "cipher_wrap.c",
    "constant_time.c",
    "cmac.c",
    "ctr_drbg.c",
    "des.c",
    "dhm.c",
    "ecdh.c",
    "ecdsa.c",
    "ecjpake.c",
    "ecp.c",
    "ecp_curves.c",
    "ecp_curves_new.c",
    "entropy.c",
    "entropy_poll.c",
    "error.c",
    "gcm.c",
    "hkdf.c",
    "hmac_drbg.c",
    "lmots.c",
    "lms.c",
    "md.c",
    "md5.c",
    "memory_buffer_alloc.c",
    "nist_kw.c",
    "oid.c",
    "padlock.c",
    "pem.c",
    "pk.c",
    "pk_ecc.c",
    "pk_wrap.c",
    "pkcs12.c",
    "pkcs5.c",
    "pkparse.c",
    "pkwrite.c",
    "platform.c",
    "platform_util.c",
    "poly1305.c",
    "psa_crypto.c",
    "psa_crypto_aead.c",
    "psa_crypto_cipher.c",
    "psa_crypto_client.c",
    "psa_crypto_driver_wrappers_no_static.c",
    "psa_crypto_ecp.c",
    "psa_crypto_ffdh.c",
    "psa_crypto_hash.c",
    "psa_crypto_mac.c",
    "psa_crypto_pake.c",
    "psa_crypto_random.c",
    "psa_crypto_rsa.c",
    "psa_crypto_se.c",
    "psa_crypto_slot_management.c",
    "psa_crypto_storage.c",
    "psa_its_file.c",
    "psa_util.c",
    "ripemd160.c",
    "rsa.c",
    "rsa_alt_helpers.c",
    "sha1.c",
    "sha256.c",
    "sha512.c",
    "sha3.c",
    "threading.c",
    "timing.c",
    "version.c",
    "version_features.c",
};
