# SSH Terminal MVP Runtime Plan

## 背景

Shellow 已有第一版 `libssh2` wrapper 和 `libvterm` wrapper，但 workspace 仍在使用 mock session 和 mock terminal transcript。下一阶段目标是把 SSH profile 打开成真实 `SshSession`，让 PTY 字节流进入 terminal emulator，再由 DVUI workspace 渲染 terminal snapshot。

本计划负责把以下 active plans 串成一条可落地路线：

- `docs/plans/active/libssh2-ssh-wrapper.md`
- `docs/plans/active/libvterm-terminal-emulator.md`

## 目标

- SSH profile 可以打开真实 SSH terminal tab。
- SSH connect/auth/host-key verification 有明确状态和错误提示。
- PTY read/write/resize 与 terminal emulator resize 同步。
- DVUI terminal widget 只渲染 Shellow terminal snapshot，不解析 escape sequence。
- 阻塞 I/O 不进入 DVUI 主线程。
- 断开、关闭、失败、重连入口有清晰 runtime 状态。

## 非目标

- 不在 SSH terminal MVP 中实现 FTP。
- 不把 SFTP 文件传输塞进 shell channel。
- profile 可以保存用户选择持久化的 secret，但必须通过 Shellow-owned security/profile repository 边界，不能把明文 secret 散落到 UI、日志或普通业务对象外。
- 不为了 UI 方便暴露 raw `LIBSSH2_*` 或 raw `VTerm*` handle。
- 不先追求完整 terminal 高级能力，如 sixel、GPU renderer、复杂字体 shaping。

## 边界图

```txt
DVUI workspace
  -> app state
    -> session registry
      -> SshSession runtime
        -> ssh.Client / ssh.Shell
          -> libssh2_backend
        -> terminal.Emulator
          -> libvterm_backend
```

## 数据模型与文件落点

建议小步创建，不为目录完整提前铺空文件。

| 层级 | 计划文件 | 职责 |
| --- | --- | --- |
| core | `src/core/session.zig` 或扩展 `workspace.zig` | session id、status、error summary、runtime-independent state |
| app/service | `src/services/session_registry.zig` | 从 mock registry 迁移到 runtime-aware registry |
| runtime | `src/services/ssh_session.zig` 或 `src/runtime/ssh_session.zig` | connect/open shell/read loop/write/resize/close |
| protocol | `src/protocols/ssh.zig`, `src/protocols/libssh2_backend.zig` | Shellow SSH facade 与 libssh2 backend |
| terminal | `src/terminal/terminal.zig`, `src/terminal/libvterm_backend.zig` | terminal emulator facade 与 snapshot |
| ui | `src/ui/workspace/terminal_panel.zig` | render snapshot、keyboard/paste/selection/resize intent |
| security | `src/security/` | known_hosts、credential prompt/keychain strategy |

## 实施顺序

### 1. 补齐 SSH backend 最小安全闭环

- [x] 实现 host key fingerprint extraction。
- [x] 在 `ssh.ConnectOptions` 中建立 host key verifier 边界。
- [x] 实现 known_hosts 数据模型和存储位置。
- 实现 policy 行为：
  - [x] `strict`: known host mismatch 或 missing 直接失败。
  - [x] `trust_on_first_use`: missing 时返回需要用户确认的状态，确认后写入。
  - [x] `insecure_accept_any`: 仅允许开发/显式用户选择。
- 将 libssh2 error code 映射成 Shellow user-facing error。
- 保持 agent auth 未完成时显式 `UnsupportedAuth`，不要静默 fallback。

验收：

- host key mismatch 不会继续认证。
- 错误消息不包含密码、passphrase、private key 内容。
- `zig build test` 通过。

### 2. 建立 credential acquisition 与持久化边界

- profile repository 可以保存用户选择持久化的 secret。
- 添加 credential request state：
  - password
  - private key passphrase
  - private key path
- UI 只把 credential intent 交给 profile repository 或 session open request；加密、清理和序列化由 repository/security 层负责。
- 后续 keychain 作为独立 plan，不阻塞 MVP。

验收：

- `data/profiles.json` 不出现明文 secret。
- 关闭 tab 后 runtime 清理临时 credential buffer。
- 选择保存的 secret 只出现在 profile repository/security 层定义的编码字段中。

### 3. 建立 `SshSession` runtime

- [x] 定义 runtime 状态：
  - [x] `idle`
  - [ ] `resolving`
  - [x] `connecting`
  - [ ] `verifying_host_key`
  - [ ] `authenticating`
  - [x] `opening_shell`
  - [x] `connected`
  - [x] `closing`
  - [x] `closed`
  - [x] `failed`
- [x] runtime 持有：
  - [x] `ssh.Client`
  - [x] `ssh.Shell`
  - [x] `terminal.Emulator`
  - [x] pending outbound input queue
  - [x] latest terminal dirty flag
  - [x] last error summary
- SSH read loop 在后台线程或 future runtime queue 中运行，不阻塞 DVUI。
- [x] read pump 只做：`shell.read -> terminal.write -> mark dirty`。
- [x] write path 第一版只做：`runtime.writeInput -> shell.write`。
- [x] close path 保证 shell/client/emulator 的 deinit 顺序。
- [x] 后台 worker 第一版拥有 `SshSession` 并驱动 read pump。
- [x] worker 维护 terminal snapshot cache，UI 只拷贝 snapshot，不直接访问 emulator。

验收：

- 打开 tab 后 UI 主线程不卡死。
- 断线后 tab status 进入 failed/closed，不崩溃。
- close tab 能释放 session、channel、terminal emulator。

### 4. 将 session registry 从 mock 迁移到 runtime-aware

- [x] 保留 `WorkspaceTab` 作为 UI 可消费摘要。
- [x] registry 内部保存 runtime handle，但 UI 不直接拥有 protocol object。
- `openProfile` 改成根据 profile type 分发：
  - [x] SSH -> create `SshSession`
  - FTP -> 暂时仍 mock 或明确 unavailable
- [x] active tab 与 runtime id 绑定。
- mock transcript 仅作为空状态/测试 fallback，不作为真实 SSH 路径。

当前状态：

- `session_registry.MockSessionRegistry` 已有 `openSshRuntimeTab()` 过渡入口。
- `session_registry.MockSessionRegistry` 已有 `openSshWorkerTab()` 后台 worker 入口。
- `App` 已能生成真实 SSH runtime options，包括 libssh2 connector、libvterm terminal factory 和 known_hosts verifier。
- UI 的 `openProfile()` 对 SSH profile 已切到 `openSshWorkerTab()`。
- worker 已支持 outbound input queue，UI 可通过最小命令栏向 SSH PTY 写入一行输入。
- FTP profile 仍使用 mock tab。
- 开发期 SSH runtime 使用 TOFU 自动信任 missing host key，并在 app 关闭前持久化 known_hosts；正式确认 UI 仍待接入。
- `zig build ssh-probe -- 10.157.123.76 8022 root 123456` 已通过 Shellow 自己的 libssh2 backend 完成 connect/auth/open shell/write/read smoke test，读回 `shellow_probe_okLinux`。

验收：

- SSH profile 打开后创建真实 runtime。
- FTP profile 不污染 SSH runtime 类型。

### 5. 接 terminal viewport 与 resize 同步

- [x] 定义初版 `TerminalViewport`：
  - [x] visible rows/cols
  - [x] cell size/font metrics
  - scroll offset
  - selection state
- [x] DVUI 计算 rows/cols 后发 resize intent。
- [x] runtime resize 顺序：
  - [x] `terminal.resize(cols, rows)`
  - [x] `shell.resize(cols, rows)`
- [x] 同一套 cols/rows 同时用于 emulator 和 PTY。
- [x] resize intent 合并为 latest-size request，避免拖窗口时把中间尺寸排成长队。

验收：

- shell prompt、vim/nano/top 的尺寸与窗口一致。
- resize 后没有旧尺寸残留或行列错位。

### 6. 渲染真实 terminal snapshot

- [x] `terminal_panel.zig` 改为可选消费 snapshot。
- 初版先支持：
  - [x] ASCII codepoint
  - [ ] UTF-8 codepoint
  - [ ] default/indexed/rgb colors
  - [ ] bold/italic/underline/reverse
  - [ ] cursor
- 之后再加：
  - scrollback
  - selection/copy
  - bracketed paste
  - mouse reporting
- UI 绝不解析 ANSI/VT escape。

验收：

- 常规 shell 输出和 ANSI color 正常显示。
- cursor 位置正确。
- terminal widget 中无 raw libvterm 调用。

### 7. 输入、粘贴和特殊键

- 定义 UI key event -> terminal/PTY bytes 的转换边界。
- [x] 第一版命令输入栏可以把一行文本加换行写入 shell。
- printable text 直接写入 shell。
- special keys 走 terminal input encoder 或 Shellow key encoder：
  - Enter
  - Backspace
  - Tab
  - arrows
  - Home/End/PageUp/PageDown
  - Ctrl/Alt combinations
- paste 支持后再加 bracketed paste mode。

验收：

- shell 命令输入、历史切换、Ctrl+C、Ctrl+D 可用。
- 粘贴多行不会破坏 UI state。

### 8. 错误、日志和诊断

- 日志只记录 host、port、username、state、error class。
- 不记录 password/passphrase/private key contents。
- error model 区分：
  - network unreachable/refused/timeout
  - host key missing/mismatch
  - auth failed/unsupported auth
  - shell open failed
  - channel closed
- UI 展示短错误，调试日志保留可追踪 code。

验收：

- 常见失败场景能给出可行动提示。
- 日志检查不含 secret。

### 9. 回归清单

每个 terminal/runtime 阶段至少跑：

```sh
zig build test
zig build
```

手工 terminal regression：

- SSH 到本机或测试 VM。
- 执行 `echo hello`。
- 执行 colored output，如 `printf '\033[31mred\033[0m\n'`。
- 执行 `vim` 或 `nano`，确认 resize。
- 执行 `top` 或 `htop`，确认持续刷新。
- Ctrl+C、Ctrl+D、关闭 tab。
- 断网或关闭 sshd，确认状态进入 failed/closed。

同时更新：

- `docs/quality/terminal-regression-checklist.md`
- `docs/quality/security-notes.md`，如果 credential/host key 行为变化。

## 里程碑

### M1: Local Smoke

- 使用 `.insecure_accept_any` 连接测试 SSH。
- 后台 read loop -> terminal emulator -> debug snapshot。
- 不接正式 UI。

### M2: Real Terminal Tab

- [x] SSH profile 打开真实 worker-backed tab。
- [x] terminal panel 渲染 snapshot。
- [x] 基础输入输出可用。

### M2.5: Verified Real SSH Connection

- [x] Shellow libssh2 backend 可连接真实 SSH server。
- [x] password auth 可用。
- [x] shell channel 可打开并写入命令。
- [x] shell output 可读回并进入 terminal/render 路径。
- [ ] 键盘级 terminal 输入、特殊键和 paste。
- [ ] 完整 color/cursor/UTF-8 渲染。

### M3: Resize Stable

- DVUI rows/cols 与 PTY resize 同步。
- vim/nano/top 尺寸正确。

### M4: Host Key Safe

- strict/TOFU known_hosts 流程可用。
- insecure mode 仅作为显式开发/高级选项。

### M5: Daily Shell MVP

- password/private-key login。
- 常见 shell/TUI 可用。
- close/disconnect/error 状态稳定。

### M6: SFTP Entry

- 在 SSH session 上打开 SFTP capability。
- list/stat/read/write/upload/download 进入独立 SFTP/transfer plan。

## 关键风险

- libssh2 阻塞读如果跑在 UI 线程，会冻结窗口。
- host key verification 如果晚于 auth，会形成安全倒置。
- terminal resize 如果 shell 与 emulator 使用不同 rows/cols，TUI 会错位。
- credential 如果绕过 profile repository/security 层直接明文写入 JSON，会破坏安全边界。
- SFTP 如果复用 shell byte stream，会污染 terminal/session 模型。
- raw third-party handles 如果进入 app/ui/services，会让后续 runtime 重构成本变高。
