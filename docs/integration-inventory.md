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

## 3. 计划评估：SSH / SFTP

候选方向：

- `libssh2` C 库绑定，当前首选
- Zig 原生 SSH/SFTP 库
- 外部 `ssh` 进程桥接作为早期验证手段

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
- Raw libssh2 handle 只允许出现在 `src/protocols/libssh2_backend.zig` 或同级 backend/shim 文件中。
- App、service 和 UI 层只使用 `src/protocols/ssh.zig` 暴露的 Shellow API。

当前 Shellow API 落点：

| 文件 | 用途 |
| --- | --- |
| `src/protocols/ssh.zig` | 稳定 SSH/SFTP 抽象，定义 endpoint、auth、host key policy、shell、sftp、client、connector。 |
| `src/protocols/libssh2_backend.zig` | 未来 libssh2 backend，负责 C API、非阻塞等待、错误映射和 raw handle 生命周期。 |

## 4. 计划评估：FTP / FTPS

候选方向：

- Zig 原生 FTP client
- C 库绑定
- 自研最小 FTP client

准入标准：

- 支持 list/upload/download/delete/rename/mkdir
- 可选 FTPS
- 连接错误和传输错误可明确分类

维护原则：

- FTP controller 与 SSH/SFTP controller 分离。
- FTP workspace 使用 `file_only` 布局。

## 5. 计划评估：本地存储

早期策略：

- profile 元数据使用本地文件。
- 敏感信息不进入普通 profile 文件。
- settings、layout、recent sessions 可以先用 JSON 或 Zig 结构化序列化。

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
