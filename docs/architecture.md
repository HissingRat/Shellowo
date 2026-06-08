# Shellow 架构规划

## 1. 目标

Shellow 第一版要解决的是“原生桌面远程工作台”的核心闭环，而不是一次支持所有协议。

核心体验：

- 一个连接列表
- 一个多标签工作区
- SSH 会话中终端与 SFTP 文件联动
- FTP 会话中只呈现文件管理
- 上传下载任务全局可见
- 连接、会话、传输和窗口状态可恢复

## 2. 当前实现状态

当前仓库具备：

- Zig 0.16 工程
- DVUI 依赖
- SDL3 backend
- 原生工作台布局
- SSH/FTP 连接配置 CRUD
- 非敏感 profile JSON 持久化
- mock workspace tabs
- transfer panel 占位

尚未具备：

- SSH / SFTP / FTP 协议接入
- 终端渲染与 PTY 尺寸同步
- 真实文件管理器
- 真实传输中心
- 设置与主题系统
- 发布打包流程

## 3. 技术路线

已采用：

- Zig
- DVUI
- SDL3 backend

计划评估：

- SSH client / PTY channel 能力
- SFTP client 能力
- FTP/FTPS client 能力
- 本地配置存储格式
- 可选的系统钥匙串或平台安全存储
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
  - FTP file controller
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
      ftp/
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

### 6.1 Session Type

```zig
pub const SessionType = enum {
    ssh,
    ftp,
};
```

### 6.2 Profile

```zig
pub const BaseProfile = struct {
    id: []const u8,
    name: []const u8,
    host: []const u8,
    port: u16,
};

pub const SshProfile = struct {
    base: BaseProfile,
    username: []const u8,
    auth_type: AuthType,
    sftp_enabled: bool,
};

pub const FtpProfile = struct {
    base: BaseProfile,
    username: []const u8,
    secure: bool,
};
```

敏感字段可以在用户选择持久化时进入 profile 存储，但必须通过 Shellow-owned profile repository/security 边界。密码、私钥 passphrase、临时凭据不能在 UI、日志或普通业务对象里明文散落。

### 6.3 Workspace Tab

```zig
pub const WorkspaceLayout = enum {
    terminal_file,
    file_only,
};

pub const TabStatus = enum {
    idle,
    connecting,
    connected,
    error,
    closed,
};
```

## 7. 为什么 SSH/SFTP 与 FTP 必须拆开

SSH/SFTP：

- 同一个认证上下文
- 同一个目标主机
- 终端与文件面板天然联动
- 后续可扩展端口转发、远端命令、路径跟随

FTP：

- 独立协议
- 无 shell
- 文件操作是完整主路径
- FTPS 仍属于 FTP 家族，不应嫁接到 SSH 模型中

不要为了“统一文件协议”做一个过大的 `RemoteSession`。可以共享 `RemoteFileEntry`、`TransferTask`、`FileOperation` 等数据形状，但 controller 层保持分离。

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
- 搜索、复制、粘贴、选区和字体设置属于 terminal widget 能力。

## 9. 文件与传输边界

文件操作共享数据形状，但不同协议控制器独立实现：

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
- paused
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

FTP 工作区：

- file-only 布局
- 不显示终端区

## 11. 存储设计

第一阶段本地持久化对象：

- 连接配置
- 分组
- 最近连接
- UI 设置
- 终端设置
- 传输历史

敏感信息策略需要单独决策：

- profile 可以保存用户选择持久化的 secret。
- 密码、passphrase、私钥内容必须通过 profile repository/security 层定义的存储格式处理，不直接明文写入 JSON。
- 可以先支持每次连接输入密码，再评估平台安全存储。

## 12. 实施原则

- 所有新功能先落抽象，再接 UI。
- 协议 controller 不依赖 DVUI。
- DVUI widget 不直接拥有协议客户端。
- 文件传输必须走统一任务中心。
- 错误处理必须以用户可读提示为目标。
- 优先把 Windows 与 macOS 做顺，再扩展 Linux 桌面发布。
- 新依赖和边界变化必须更新文档。
