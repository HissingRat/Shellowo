# Shellow 架构规划

## 1. 目标

Shellow 第一版要解决的是“原生桌面远程工作台”的核心闭环，而不是一次支持所有协议。

核心体验：

- 一个连接列表
- 一个多标签工作区
- SSH 会话中终端与 SFTP 文件联动
- 上传下载任务全局可见
- 连接、会话、传输和窗口状态可恢复

## 2. 当前实现状态

当前仓库具备：

- Zig 0.16 工程
- DVUI 依赖
- SDL3 backend
- 原生工作台布局
- SSH 连接配置 CRUD
- profile JSON 持久化与可选 Master Password vault
- SSH workspace tab 与 libssh2-backed SSH runtime
- PTY shell channel、libvterm terminal rendering、resize/input/selection 基础路径
- terminal runtime 在异常断线后保留最后 screen/scrollback snapshot；主动关闭仍释放 runtime
- SFTP 文件面板：远端目录树、右侧文件表、基础 mutation、上传/下载任务
- 远端目录采用 snapshot + 事件驱动 revalidation：首次无 snapshot 时显示 loading，进入已有缓存的目录时立即展示旧 snapshot 并在后台更新；用户可通过工具栏或右键菜单手动刷新，Shellow 自身 mutation 完成后也会主动刷新，不做固定周期轮询
- 全局 transfer scheduler：最多 10 个运行任务、单 SSH workspace 最多 4 个；支持 pending、进度、速度、取消、重试、覆盖确认和 busy 状态
- 远程文件编辑器：加载、查找/替换、UTF-8/BOM/ASCII 与换行识别、远端冲突检查、临时文件原子替换和未保存关闭确认
- 系统信息面板雏形与进程/网络快照
- 设置与主题系统基础：`owoConfig.json`、Light/Dark、窗口/布局尺寸和下载路径持久化
- SDL3_ttf + FreeType + HarfBuzz shaped-text backend；DVUI 测量、绘制、
  TextLayout hit testing、caret/selection 与 TextEntry cluster 边界共享同一
  layout source，Zed Mono + Noto CJK fallback chain 已接入
- 三平台 CI 构建、nightly/tag Release、macOS `.app` 基础打包

尚未具备：

- 平台系统凭据库集成与发布级 profile secret 策略；当前已有可选 Master Password 加密 vault
- 完整传输中心体验，例如持久化历史、批量控制和更清晰的占用说明
- 通用编码转换、真正分块的大文件编辑和可视化 diff/merge 等高级编辑体验
- 正式发布签名、公证、安装器和三平台运行回归

## 3. 技术路线

已采用：

- Zig
- DVUI
- SDL3 backend
- libssh2 SSH/SFTP backend
- libvterm terminal emulator
- JSON settings/profile storage 与可选加密 profile vault

计划评估：

- 平台系统凭据库
- SQLite 等长期本地存储方案
- 打包与签名流程

暂缓：

- WebView/Electron 主界面
- 团队同步
- 云备份
- RDP / VNC / Telnet / Serial
- AI 助手

## 4. 高层分层

```txt
DVUI App Shell
  -> Application State
    -> Desktop Services
      -> Session Runtime
        -> Protocol Controllers
          -> Protocol Clients
            -> Remote Servers
```

分层职责：

- `DVUI App Shell`
  - 窗口生命周期
  - 布局、主题、用户交互
  - 只消费 application state，不直接管理协议客户端
- `Application State`
  - profiles
  - workspace tabs
  - selected session
  - transfer tasks
  - UI settings
- `Desktop Services`
  - profile repository
  - session registry
  - transfer scheduler
  - credential strategy
- `Session Runtime`
  - 会话生命周期
  - reconnect/error state
  - 终端尺寸同步
  - 文件面板当前目录
- `Protocol Controllers`
  - SSH shell controller
  - SFTP file controller
- `Protocol Clients`
  - 第三方或自研协议实现

## 5. 当前目标目录结构

```txt
Shellow/
  AGENTS.md
  build.zig
  build.zig.zon
  docs/
    architecture.md
    roadmap.md
    integration-inventory.md
    plans/
    decisions/
    quality/
  .agents/
    extensions/
    skills/
  src/
    main.zig
    bootstrap.zig
    app/
      App.zig
      config.zig
      keybindings.zig
    core/
      profile.zig
      transfer.zig
      remote_file.zig
      terminal/
        predictive.zig
    contracts/
      ssh.zig
      terminal_emulator.zig
    backends/
      ssh/
        libssh2.zig
      text/
        sdl_ttf.zig
      terminal/
        libvterm.zig
        libvterm_shim.c
    runtime/
      files/
        remote_path.zig
        entry_order.zig
      monitor/
        ssh_monitor.zig
      profiles/
        profile_repository.zig
      sessions/
        registry.zig
        ssh_session.zig
        ssh_workspace_worker.zig
      terminal/
        pty_slot.zig
      transfers/
        progress_store.zig
    ui/
      fonts.zig
      foundation/
      widgets/
      layouts/
      features/
        app_shell/
        files/
        profiles/
        security/
        terminal/
        workspace/
      workspace/
  tools/
    ssh_probe.zig
    ssh_worker_probe.zig
```

目录按可构建批次演进，不为了结构完整而提前铺空文件。`contracts` 保存 Shellow-owned 稳定能力，`backends` 保存第三方/native 具体实现，`runtime` 保存 session、worker、registry 和 repository 生命周期。`bootstrap.zig` 是具体 backend 的装配入口，App 只持有 connector/factory contract。UI 直接建立在 DVUI 上，但常规视觉控件和重复布局优先经过 `ui/foundation`、`ui/widgets` 与 `ui/layouts`。

## 6. 会话模型

### 6.1 Profile

Shellow 当前只支持 SSH 连接，profile 模型直接表达 SSH 所需字段，不再额外保存 `SessionType`。

```zig
pub const BaseProfile = struct {
    id: []const u8,
    name: []const u8,
    host: []const u8,
    port: u16,
};

pub const ConnectionProfile = struct {
    base: BaseProfile,
    username: []const u8,
    auth_type: AuthType,
    sftp_enabled: bool,
};
```

敏感字段可以在用户选择持久化时进入 profile 存储，但必须通过 Shellow-owned profile repository/security 边界。临时 UI draft/session request 可以短暂持有明文凭据；日志和无关业务对象不得复制或输出 secret。

### 6.2 Workspace Tab

```zig
pub const WorkspaceLayout = enum {
    terminal_file,
};

pub const TabStatus = enum {
    idle,
    connecting,
    connected,
    error,
    closed,
};
```

## 7. SSH/SFTP 工作区边界

SSH/SFTP 共享认证上下文和目标主机，但终端、文件面板和传输任务仍保持清晰边界：

- SSH shell controller 只负责 PTY 字节流。
- SFTP file controller 负责远端文件 list/read/write/upload/download。
- Transfer system 负责上传下载进度和任务生命周期。
- UI 只消费 snapshot 并发出 intent，不直接持有协议 client。

## 8. 终端边界

终端能力需要拆成三层：

```txt
terminal widget
  -> terminal viewport/state
    -> ssh pty channel
```

维护原则：

- PTY 输出字节流不在 UI 层随意改写。
- UI 的 cols/rows 必须和后端 PTY resize 使用同一套值。
- 文件传输不通过 shell 通道混流。
- 搜索、复制、粘贴和选区属于 terminal widget 能力。

## 9. 文件与传输边界

SFTP 文件操作通过 Shellow-owned controller 暴露：

- list
- stat
- mkdir
- rename
- atomic replace
- delete
- chmod
- read
- write
- upload
- download

传输必须进入统一 transfer queue：

- pending
- running
- completed
- failed
- canceled

UI 不直接维护“临时进度条状态”，只订阅 transfer snapshot。

## 10. UI 结构

桌面主布局：

- 左侧：连接列表 / 分组 / 最近连接
- 顶部：标签栏
- 主区：工作区视图
- 右侧或底部：传输任务与系统信息

SSH/SFTP 工作区：

- 终端主区
- 远程文件面板
- 可切换终端全屏或文件全屏
- 后续可做路径跟随

## 11. 存储设计

当前本地持久化对象：

- 连接配置
- 分组
- UI 设置
- 终端设置

尚未持久化：

- 最近连接与连接使用历史
- 传输历史

敏感信息策略仍需在发布前收口：

- profile 可以保存用户选择持久化的 secret。
- 密码、passphrase、私钥内容必须通过 profile repository/security 层定义的存储格式处理。
- 当前实现支持可选 Master Password：启用后 `data/profiles.json` 存为 Shellowo profile vault object，使用 Argon2id 从用户密码和随机 salt 派生密钥，并用 XChaCha20-Poly1305 加密 profile JSON array。
- 未启用 Master Password 时仍兼容旧的 profile JSON array；`src/security/secret_file.zig` 当前只是透传兼容层，因此其中保存的密码/passphrase 不具备静态加密保护。
- 正式发布前需要明确平台系统凭据库、临时凭据和无 Master Password 模式的产品策略。

## 12. 实施原则

- 所有新功能先落抽象，再接 UI。
- 协议 controller 不依赖 DVUI。
- DVUI widget 不直接拥有协议客户端。
- 文件传输必须走统一任务中心。
- 错误处理必须以用户可读提示为目标。
- 优先把 Windows 与 macOS 做顺，再扩展 Linux 桌面发布。
- 新依赖和边界变化必须更新文档。
