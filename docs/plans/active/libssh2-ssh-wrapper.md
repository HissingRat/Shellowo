# libssh2 SSH Wrapper Plan

## 背景

Shellow 需要 SSH shell 和 SFTP 文件能力。`libssh2` 适合作为底层库，但它的 C API、非阻塞状态和原始 handle 不应该泄漏到 app state、DVUI widget 或 transfer system。

## 目标

- 建立 Shellow 自己的 `ssh` API。
- 将 `libssh2` 限制在 backend 文件内。
- 支持 SSH shell、PTY resize、SFTP 文件操作。
- 为 host key verification 和认证错误映射预留边界。

## 非目标

- 不在第一步完成真实 libssh2 链接。
- 不保存密码或 passphrase。
- 不把 FTP 混进 SSH/SFTP wrapper。

## 当前落点

- `src/protocols/ssh.zig`
  - Shellow 稳定 SSH/SFTP API。
  - 包含 endpoint、auth、host key policy、shell、sftp、client、connector。
- `src/protocols/libssh2_backend.zig`
  - 未来唯一允许接触 raw libssh2 handle 的位置。

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
   - Windows: vcpkg/system lib 或 Zig 编译源码。
   - macOS/Linux: system lib 或源码构建。
   - 记录 OpenSSL/libcrypto 策略。

2. 建立 C/Zig 绑定
   - 优先尝试小型 C shim。
   - 不让 `@cImport` 生成内容进入业务模块。

3. 实现 connect
   - socket connect。
   - `libssh2_session_init_ex`。
   - handshake。
   - host key check。
   - password/private key/agent auth。

4. 实现 shell
   - open session channel。
   - request pty。
   - shell。
   - read/write。
   - resize。
   - close。

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
