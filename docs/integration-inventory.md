# Shellow Integration Inventory

本文归总 Shellow 已接入和计划评估的核心第三方项目、采用理由、实现位置和维护边界。精确版本以 `build.zig.zon` 为准。

## 1. GUI: DVUI

| 项目 | 当前用途 | 实现位置 | 维护结论 |
| --- | --- | --- | --- |
| `dvui` | 原生 UI、窗口 app lifecycle、widgets | `build.zig`, `src/main.zig` | Shellow 主界面走 DVUI，不用 Electron/WebView 替代主 UI。 |
| `dvui_sdl3` | SDL3 backend | `build.zig` | 通过 `b.dependency("dvui", .{ .backend = .sdl3 })` 导入。 |

维护原则：

- 新 UI 优先使用 DVUI widget 和布局能力。
- 不把业务逻辑堆进 widget 回调。
- DVUI 升级后至少验证 `zig build` 和窗口启动。

## 2. Window Backend: SDL3

当前 SDL3 由 DVUI 依赖链引入。

维护原则：

- 不绕过 DVUI 直接操作 SDL3 窗口，除非是 DVUI backend 无法覆盖的底层能力。
- 如果接入平台剪贴板、拖拽、文件对话框等系统能力，先判断 DVUI 是否已有抽象。

## 3. SSH / SFTP

当前实现：

- `libssh2` C 库绑定已作为 Shellow SSH/SFTP 后端。
- 当前 vendor 版本：`third_party/libssh2-1.11.1`。
- 当前 crypto backend：`third_party/mbedtls-3.6.6`。
- 当前 Zig build 已编译 `shellow_mbedcrypto` 与 `shellow_libssh2` 静态库，并通过 `libssh2_init/libssh2_exit` smoke test。
- `src/protocols/libssh2_backend.zig` 已具备第一版阻塞式 connect/auth/shell channel wrapper，并在认证前提取 host key SHA256 fingerprint 交给 Shellow verifier；known_hosts strict/TOFU 存储与 missing host key 确认路径已接入；password/private key/agent auth 已接入；SFTP list/read/write/mkdir/remove/rename 已接入。
- `zig build ssh-probe -- host port username password` 可通过 Shellow libssh2 backend 做真实 SSH connect/auth/open shell/write/read smoke test。
- Zig 原生 SSH/SFTP 库暂不作为主路线。
- 外部 `ssh` 进程桥接仅可作为诊断或临时验证手段，不进入正式运行时。

准入标准：

- 支持 PTY shell
- 支持 resize
- 支持 SFTP list/read/write/upload/download
- 能在 Windows/macOS/Linux 构建或有清晰替代策略
- 错误状态可映射为用户可读提示

维护原则：

- SSH/SFTP controller 不依赖 DVUI。
- 终端字节流不在 UI 层改写。
- SFTP 传输必须进入 transfer queue。
- 生产代码只调用 Shellow 自有 SSH/SFTP API，不直接调用 `libssh2` C API。
- Raw libssh2 handle 只允许出现在 `src/protocols/libssh2_backend.zig` 或同级 backend/shim 文件中。
- App、service 和 UI 层只使用 `src/protocols/ssh.zig` 暴露的 Shellow API。

当前 Shellow API 落点：

| 文件 | 用途 |
| --- | --- |
| `src/protocols/ssh.zig` | 稳定 SSH/SFTP 抽象，定义 endpoint、auth、host key policy、shell、sftp、client、connector。 |
| `src/protocols/libssh2_backend.zig` | libssh2 backend，负责 C API、等待策略、错误映射和 raw handle 生命周期。 |
| `third_party/libssh2-1.11.1` | vendored libssh2 1.11.1 source。 |
| `third_party/mbedtls-3.6.6` | vendored mbedTLS 3.6.6 source for libssh2 crypto backend。 |

## 4. Terminal Emulator

当前实现：

- 自建 `libvterm` C 库 binding 已作为 Shellow terminal emulator 后端。
- 当前 vendor 版本：`third_party/libvterm-0.3.3`。
- 当前 Zig build 已编译 `shellow_libvterm` 静态库，并通过 `src/terminal/libvterm_shim.c` 将 C bitfield/callback-facing cell 数据转换为 Shellow terminal snapshot。
- 不在 DVUI widget 中手写 ANSI/VT escape parser。
- 不把 terminal emulator API 直接暴露给 app/session/UI 层。

准入标准：

- 支持常见 VT/xterm 控制序列。
- 支持 grid、scrollback、cursor、style/color 状态输出。
- 支持输入编码、粘贴、选区、复制所需的数据边界。
- 支持与 SSH PTY cols/rows resize 同步。
- 可在 Windows/macOS/Linux 构建或有清晰 fallback。

维护原则：

- PTY channel 只负责字节流和 resize，不负责 terminal escape 解析。
- Terminal emulator backend 不依赖 DVUI。
- DVUI terminal widget 只渲染 Shellow terminal state，不直接调用 `libvterm`。
- Raw libvterm handle 只允许出现在 dedicated backend/shim 文件中。

当前 Shellow API 落点：

| 文件 | 用途 |
| --- | --- |
| `src/terminal/terminal.zig` | 稳定 terminal emulator 抽象，定义输入字节、grid snapshot、cursor、style、resize。 |
| `src/terminal/libvterm_backend.zig` | libvterm backend，负责 C API、状态转换和 raw handle 生命周期。 |
| `src/terminal/libvterm_shim.c` | C shim，负责把 libvterm bitfield cell/color 数据转成 Zig 可直接消费的 plain struct。 |
| `third_party/libvterm-0.3.3` | vendored libvterm 0.3.3 source。 |

## 5. 本地存储

当前实现：

- profile 元数据使用本地文件。
- 用户选择持久化的敏感信息可以进入 profile 存储，但必须通过 profile repository/security 层处理，不在 UI、日志或普通业务对象里明文散落。
- `src/security/profile_vault.zig` 提供可选 Master Password profile vault：Argon2id KDF、XChaCha20-Poly1305 AEAD、随机 salt/nonce 写入 vault JSON；`src/services/profile_repository.zig` 负责兼容明文 profile array 与 encrypted vault。
- settings、layout、recent sessions 使用 JSON/Zig 结构化序列化。

后续评估：

- SQLite
- 平台安全存储
- 加密文件存储

## 6. 新依赖准入规则

新增或替换第三方项目时，至少补齐：

1. 在 `build.zig.zon` 添加依赖。
2. 在本文件登记用途、实现位置、维护边界。
3. 如果涉及终端、文件传输、协议、安全或发布，补充 `docs/quality/` 下的回归清单。
4. 如果改变分层边界，同步更新 `docs/architecture.md` 或 `docs/decisions/`。
5. 跑 `zig build`。
