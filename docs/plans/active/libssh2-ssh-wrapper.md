# libssh2 SSH Wrapper Plan

## 背景

Shellow 需要 SSH shell 和 SFTP 文件能力。`libssh2` 适合作为底层库，但它的 C API、非阻塞状态和原始 handle 不应该泄漏到 app state、DVUI widget 或 transfer system。

生产代码必须通过 Shellow 自有 wrapper 使用 SSH/SFTP 能力，不直接调用 `libssh2` API。

## 目标

- 建立 Shellow 自己的 `ssh` API。
- 将 `libssh2` 限制在 backend 文件内。
- 将 `libssh2` C API、raw handle、错误码和非阻塞等待细节封装在 backend/shim 内。
- 支持 SSH shell、PTY resize、SFTP 文件操作。
- 为 host key verification 和认证错误映射预留边界。

## 非目标

- 不在第一步完成真实 libssh2 链接。
- 密码或 passphrase 可以按用户选择持久化，但必须通过 Shellow-owned profile repository/security 边界，不在协议 wrapper、UI 或日志中明文散落。
- 不把 FTP 混进 SSH/SFTP wrapper。

## 当前落点

- `src/protocols/ssh.zig`
  - Shellow 稳定 SSH/SFTP API。
  - 包含 endpoint、auth、host key policy、shell、sftp、client、connector。
- `src/protocols/libssh2_backend.zig`
  - 未来唯一允许接触 raw libssh2 handle 的位置。
  - 负责 C API 调用、生命周期、错误映射和 socket wait 策略。

## API 边界

```txt
DVUI terminal/file widgets
  -> session runtime
    -> ssh.Client / ssh.Shell / ssh.Sftp
      -> libssh2_backend
        -> libssh2 C API
```

## 实施步骤

1. 验证 libssh2 构建策略
   - [x] 当前使用 vendored libssh2 source + vendored mbedTLS source，通过 Zig build 编译静态库。
   - [x] 记录 mbedTLS crypto backend 策略。

2. 建立 C/Zig 绑定
   - [x] raw libssh2 C API 只在 `src/protocols/libssh2_backend.zig` 内使用。
   - [x] 不让 raw handle 进入 app/service/UI。

3. 实现 connect
   - [x] socket connect。
   - [x] `libssh2_session_init_ex`。
   - [x] handshake。
   - [x] host key check。
   - [x] password/private key auth。
   - [ ] agent auth。

4. 实现 shell
   - [x] open session channel。
   - [x] request pty。
   - [x] shell。
   - [x] read/write。
   - [x] resize。
   - [x] close。

5. 实现 SFTP
   - init sftp session。
   - list/stat/read/write。
   - mkdir/remove/rename。
   - transfer progress callback 接 transfer queue。

6. 错误映射
   - libssh2 error code -> `ssh.Error`。
   - 保留用户可读 message，但不暴露 secret。

## 验收标准

- `zig build test` 通过。
- raw libssh2 handle 不出现在 `src/app`、`src/ui`、`src/services`。
- SSH terminal 可以正常执行命令。
- PTY resize 与 UI cols/rows 一致。
- SFTP list/upload/download 进入统一 transfer system。

当前验证：

- `zig build ssh-probe -- 10.157.123.76 8022 root 123456` 已通过 Shellow libssh2 backend 连接真实 SSH server，并读回 `shellow_probe_okLinux`。
