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
    exe.root_module.addWin32ResourceFile(.{
        .file = b.path("assets/shellowo.rc"),
        .include_paths = &.{b.path("assets")},
    });
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
    exe.root_module.addAnonymousImport("shellowo-zed-italic-font", .{
        .root_source_file = b.path("assets/fonts/zed-mono-extendeditalic.ttf"),
    });
    exe.root_module.addAnonymousImport("shellowo-zed-bold-font", .{
        .root_source_file = b.path("assets/fonts/zed-mono-extendedbold.ttf"),
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
    exe.root_module.addAnonymousImport("shellowo-folder-icon", .{
        .root_source_file = b.path("assets/folder.png"),
    });
    exe.root_module.addAnonymousImport("shellowo-file-icon", .{
        .root_source_file = b.path("assets/file.png"),
    });
    exe.root_module.addAnonymousImport("shellowo-refresh-icon", .{
        .root_source_file = b.path("assets/refresh.png"),
    });
    exe.root_module.addAnonymousImport("shellowo-close-icon", .{
        .root_source_file = b.path("assets/close.png"),
    });
    exe.root_module.addAnonymousImport("shellowo-sun-icon", .{
        .root_source_file = b.path("assets/sun.png"),
    });
    exe.root_module.addAnonymousImport("shellowo-moon-icon", .{
        .root_source_file = b.path("assets/moon.png"),
    });
    exe.root_module.addAnonymousImport("shellowo-ssh-status-script", .{
        .root_source_file = b.path("assets/script/ssh_status_linux.sh"),
    });

    b.installArtifact(exe);

    const ssh_probe = b.addExecutable(.{
        .name = "shellow-ssh-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ssh_probe.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    attachNativeDeps(b, ssh_probe, native_deps);
    ssh_probe.root_module.addAnonymousImport("shellowo-ssh-status-script", .{
        .root_source_file = b.path("assets/script/ssh_status_linux.sh"),
    });

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const ssh_probe_step = b.step("ssh-probe", "Probe an SSH server through Shellow's libssh2 backend");
    const ssh_probe_cmd = b.addRunArtifact(ssh_probe);
    ssh_probe_step.dependOn(&ssh_probe_cmd.step);
    if (b.args) |args| {
        ssh_probe_cmd.addArgs(args);
    }

    const ssh_worker_probe = b.addExecutable(.{
        .name = "shellow-ssh-worker-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ssh_worker_probe.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    attachNativeDeps(b, ssh_worker_probe, native_deps);
    ssh_worker_probe.root_module.addAnonymousImport("shellowo-ssh-status-script", .{
        .root_source_file = b.path("assets/script/ssh_status_linux.sh"),
    });

    const ssh_worker_probe_step = b.step("ssh-worker-probe", "Probe an SSH server through Shellow's worker-backed runtime");
    const ssh_worker_probe_cmd = b.addRunArtifact(ssh_worker_probe);
    ssh_worker_probe_step.dependOn(&ssh_worker_probe_cmd.step);
    if (b.args) |args| {
        ssh_worker_probe_cmd.addArgs(args);
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
    tests.root_module.addImport("dvui", dvui_dep.module("dvui_sdl3"));
    tests.root_module.addAnonymousImport("shellowo-ssh-status-script", .{
        .root_source_file = b.path("assets/script/ssh_status_linux.sh"),
    });
    tests.root_module.addAnonymousImport("shellowo-folder-icon", .{
        .root_source_file = b.path("assets/folder.png"),
    });
    tests.root_module.addAnonymousImport("shellowo-file-icon", .{
        .root_source_file = b.path("assets/file.png"),
    });
    tests.root_module.addAnonymousImport("shellowo-refresh-icon", .{
        .root_source_file = b.path("assets/refresh.png"),
    });
    tests.root_module.addAnonymousImport("shellowo-close-icon", .{
        .root_source_file = b.path("assets/close.png"),
    });
    tests.root_module.addAnonymousImport("shellowo-sun-icon", .{
        .root_source_file = b.path("assets/sun.png"),
    });
    tests.root_module.addAnonymousImport("shellowo-moon-icon", .{
        .root_source_file = b.path("assets/moon.png"),
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

const NativeDeps = struct {
    mbedcrypto: *std.Build.Step.Compile,
    libssh2: *std.Build.Step.Compile,
    libvterm: *std.Build.Step.Compile,
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
        .flags = libssh2FlagsForTarget(target),
    });

    const libvterm_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const libvterm = b.addLibrary(.{
        .name = "shellow_libvterm",
        .root_module = libvterm_module,
    });
    libvterm.root_module.addIncludePath(b.path("third_party/libvterm-0.3.3/include"));
    libvterm.root_module.addIncludePath(b.path("third_party/libvterm-0.3.3/src"));
    libvterm.root_module.addIncludePath(b.path("src/terminal"));
    libvterm.root_module.addCSourceFiles(.{
        .root = b.path("third_party/libvterm-0.3.3/src"),
        .files = &libvterm_sources,
        .flags = &.{
            "-D_XOPEN_SOURCE=600",
            "-std=c99",
        },
    });
    libvterm.root_module.addCSourceFile(.{
        .file = b.path("src/terminal/libvterm_shim.c"),
        .flags = &.{
            "-D_XOPEN_SOURCE=600",
            "-std=c99",
        },
    });

    return .{
        .mbedcrypto = mbedcrypto,
        .libssh2 = libssh2,
        .libvterm = libvterm,
    };
}

fn libssh2FlagsForTarget(target: std.Build.ResolvedTarget) []const []const u8 {
    return switch (target.result.os.tag) {
        .windows => &libssh2_windows_flags,
        else => &libssh2_posix_flags,
    };
}

const libssh2_windows_flags = [_][]const u8{
    "-DLIBSSH2_MBEDTLS",
    "-DLIBSSH2_LIBRARY",
    "-D_FILE_OFFSET_BITS=64",
};

const libssh2_posix_flags = [_][]const u8{
    "-DLIBSSH2_MBEDTLS",
    "-DLIBSSH2_LIBRARY",
    "-D_FILE_OFFSET_BITS=64",
    "-DHAVE_SELECT=1",
    "-DHAVE_SNPRINTF=1",
    "-DHAVE_STRTOLL=1",
    "-DHAVE_GETTIMEOFDAY=1",
    "-DHAVE_INTTYPES_H=1",
    "-DHAVE_UNISTD_H=1",
    "-DHAVE_SYS_TIME_H=1",
    "-DHAVE_SYS_SELECT_H=1",
    "-DHAVE_SYS_SOCKET_H=1",
    "-DHAVE_SYS_UIO_H=1",
    "-DHAVE_SYS_IOCTL_H=1",
    "-DHAVE_SYS_UN_H=1",
    "-DHAVE_O_NONBLOCK=1",
};

fn attachNativeDeps(b: *std.Build, compile: *std.Build.Step.Compile, native_deps: NativeDeps) void {
    compile.root_module.link_libc = true;
    compile.root_module.linkLibrary(native_deps.libssh2);
    compile.root_module.linkLibrary(native_deps.mbedcrypto);
    compile.root_module.linkLibrary(native_deps.libvterm);
    compile.root_module.addIncludePath(b.path("third_party/libssh2-1.11.1/include"));
    compile.root_module.addIncludePath(b.path("third_party/mbedtls-3.6.6/include"));
    compile.root_module.addIncludePath(b.path("third_party/libvterm-0.3.3/include"));
    compile.root_module.addIncludePath(b.path("src/terminal"));

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

const libvterm_sources = [_][]const u8{
    "encoding.c",
    "keyboard.c",
    "mouse.c",
    "parser.c",
    "pen.c",
    "screen.c",
    "state.c",
    "unicode.c",
    "vterm.c",
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
