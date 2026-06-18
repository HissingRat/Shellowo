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
- 非敏感 profile JSON 持久化
- SSH workspace tab 与 libssh2-backed SSH runtime
- PTY shell channel、libvterm terminal rendering、resize/input/selection 基础路径
- terminal runtime 在异常断线后保留最后 screen/scrollback snapshot；主动关闭仍释放 runtime
- SFTP 文件面板：远端目录树、右侧文件表、基础 mutation、上传/下载任务
- 全局 transfer task 摘要、进度、取消和文件面板内任务弹窗
- 设置与主题系统基础：`owoConfig.json`、Light/Dark、窗口/布局尺寸和下载路径持久化

尚未具备：

- 平台系统凭据库集成与发布级 profile secret 策略；当前已有可选 Master Password 加密 vault
- 完整传输中心体验，例如重试、覆盖冲突处理和更细的 busy/disabled 状态
- 远程编辑器的大文件、编码检测和冲突处理等高级编辑体验
- 发布打包流程

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

## 5. 计划目录结构

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
    app/
      App.zig
      Workspace.zig
    core/
      profile.zig
      session.zig
      transfer.zig
      remote_file.zig
    services/
      profile_repository.zig
      session_registry.zig
      transfer_queue.zig
    protocols/
      ssh/
      sftp/
    ui/
      home.zig
      workspace.zig
      connections.zig
      files.zig
      terminal.zig
      transfers.zig
```

这只是目标结构。实现时小步创建，不为了目录完整而提前铺空文件。

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

敏感字段可以在用户选择持久化时进入 profile 存储，但必须通过 Shellow-owned profile repository/security 边界。密码、私钥 passphrase、临时凭据不能在 UI、日志或普通业务对象里明文散落。

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

第一阶段本地持久化对象：

- 连接配置
- 分组
- 最近连接
- UI 设置
- 终端设置

敏感信息策略需要单独决策：

- profile 可以保存用户选择持久化的 secret。
- 密码、passphrase、私钥内容必须通过 profile repository/security 层定义的存储格式处理，不直接明文写入 JSON。
- 当前实现支持可选 Master Password：启用后 `data/profiles.json` 存为 Shellowo profile vault object，使用 Argon2id 从用户密码和随机 salt 派生密钥，并用 XChaCha20-Poly1305 加密 profile JSON array。
- 未启用 Master Password 时仍兼容旧的明文 profile array。

## 12. 实施原则

- 所有新功能先落抽象，再接 UI。
- 协议 controller 不依赖 DVUI。
- DVUI widget 不直接拥有协议客户端。
- 文件传输必须走统一任务中心。
- 错误处理必须以用户可读提示为目标。
- 优先把 Windows 与 macOS 做顺，再扩展 Linux 桌面发布。
- 新依赖和边界变化必须更新文档。
