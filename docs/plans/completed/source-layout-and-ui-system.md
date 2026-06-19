# Source Layout And Shellow UI System

状态：已完成第一轮结构收敛与 UI system 落地。

## 背景

Shellow 已经从最小原型成长为包含 SSH、SFTP、终端模拟、传输、状态监控和多面板工作区的桌面应用。当前目录仍保留早期按技术名词平铺的结构，导致以下问题：

- `src/protocols/` 与 `src/terminal/` 同时容纳 Shellow 稳定接口和第三方 backend 实现。
- `src/services/` 同时容纳 repository、session runtime、线程 worker 和 registry。
- `src/ssh_probe.zig` 等开发工具占据生产源码根目录。
- `src/ui/theme.zig` 同时承担 palette、字体、基础 surface 和控件实现。
- feature UI 大量直接组合 DVUI options，视觉状态、尺寸、间距和 widget 行为难以统一。
- `App.zig`、`ssh_workspace_worker.zig`、terminal/file panel 等文件已经过大，需要后续按职责继续拆分。

本计划先明确长期目录和依赖方向，再采用可持续构建的小批次迁移。不会为了目录完整创建无实现的占位模块。

## 目标

1. 分离 Shellow-owned contracts、runtime orchestration 和第三方 backend。
2. 让 raw libssh2/libvterm handle 继续严格停留在 backend 边界。
3. 将开发 probe 移出生产源码根目录。
4. 建立 Shellow 自己的 UI foundation、widgets 和 layouts。
5. 允许 UI 封装直接使用 DVUI；目标是统一视觉和交互，不追求替换 UI 框架。
6. feature UI 优先消费 Shellow widgets/layouts，减少散落的颜色、尺寸和状态处理。
7. 为后续拆分大型 runtime、App 和 UI feature 文件建立稳定落点。

## 非目标

- 不引入 Electron、WebView 或第二套 UI 框架。
- 不构造通用跨框架 GUI abstraction。
- 不机械复制完整 DVUI API。
- 不在一次迁移中重写 SSH/SFTP、terminal 或 transfer 行为。
- 不为了目录整齐提前铺设空文件。

## 目标目录

```text
src/
  main.zig
  bootstrap.zig

  core/
    profile.zig
    remote_file.zig
    status_panel.zig
    terminal_slot.zig
    transfer.zig
    workspace.zig
    terminal/
      predictive.zig

  contracts/
    ssh.zig
    terminal_emulator.zig

  backends/
    ssh/
      libssh2.zig
    terminal/
      libvterm.zig
      libvterm_shim.c
      libvterm_shim.h

  runtime/
    profiles/
      profile_repository.zig
    sessions/
      registry.zig
      ssh_session.zig
      ssh_workspace_worker.zig

  security/
    known_hosts.zig
    profile_vault.zig
    secret_file.zig

  platform/
    sdl_app.zig

  app/
    App.zig
    config.zig
    keybindings.zig
    native_event.zig

  ui/
    foundation/
      palette.zig
      typography.zig
      metrics.zig
      theme.zig
    widgets/
      button.zig
      text_field.zig
    layouts/
      surface.zig
      split_view.zig
    features/
      ...

tools/
  ssh_probe.zig
  ssh_worker_probe.zig
```

`ui/features/` 是长期方向。现有 screen/workspace 文件会分批迁移，不要求第一批全部移动。

`src/bootstrap.zig` 是 composition root，负责创建具体 SSH/terminal backend 并向 `App` 注入 Shellow-owned contracts。`App` 不直接持有 libssh2/libvterm backend 类型。

## 依赖规则

```text
UI features
  -> Shellow widgets/layouts
    -> UI foundation
      -> DVUI

UI features
  -> App
    -> Runtime
      -> Contracts
        <- Backends
```

硬性规则：

- `core/` 不依赖 DVUI、runtime 或具体 backend。
- `contracts/` 定义 Shellow-owned 能力，不导入 libssh2/libvterm C API。
- `runtime/` 只使用 contracts，不直接使用 raw third-party handle。
- `backends/ssh/libssh2.zig` 是 raw libssh2 handle 的唯一生产落点。
- `backends/terminal/libvterm.zig` 与对应 shim 是 raw libvterm handle 的唯一生产落点。
- UI foundation/widgets/layouts 可以直接依赖 DVUI。
- feature UI 可以在复杂绘制和尚未封装的能力中直接使用 DVUI，但常规按钮、输入框、surface、toolbar、split 等优先使用 Shellow UI API。
- widget API 表达 `intent`、`variant`、`state`、`size` 等产品语义；调用方不重复指定具体 hover/press 颜色。
- layout API 只封装有稳定产品语义或重复行为的布局，不为每个 `dvui.box` 制造一层同名包装。

## UI System 范围

### Foundation

- palette 与语义色
- typography 与 CJK/monospace 字体选择
- spacing、control height、radius、toolbar/sidebar 等 metrics
- 完整 `Theme` 聚合对象

### Widgets

第一批：

- Button
- TextField

后续：

- IconButton
- Checkbox
- Select
- Tab
- DataTable
- TreeView
- ContextMenu
- Dialog
- Scrollbar

统一处理：

- normal / hover / pressed / selected / disabled
- neutral / primary / danger intent
- solid / ghost / row / tab variant
- compact / regular size
- 字体、padding、圆角、focus、widget id

### Layouts

第一批：

- app/panel/topbar surface
- resizable split handle

后续：

- Toolbar
- FormGrid
- Sidebar
- TabStrip
- WorkspaceFrame

## 迁移阶段

### Phase 1：边界归位

- [x] `src/protocols/ssh.zig` 移到 `src/contracts/ssh.zig`。
- [x] `src/protocols/libssh2_backend.zig` 移到 `src/backends/ssh/libssh2.zig`。
- [x] `src/terminal/terminal.zig` 移到 `src/contracts/terminal_emulator.zig`。
- [x] libvterm backend/shim 移到 `src/backends/terminal/`。
- [x] terminal prediction 移到 `src/core/terminal/`。
- [x] session/profile services 移到 `src/runtime/` 对应目录。
- [x] SSH probes 移到 `tools/`。
- [x] 更新 build、tests、imports、architecture 和 integration inventory。
- [x] 将具体 backend 装配收敛到 `src/bootstrap.zig`，App 只持有 contract/factory。

### Phase 2：UI foundation

- [x] 从旧 `theme.zig` 拆出 palette、typography、metrics 和 theme 聚合。
- [x] 保持兼容 facade，避免 feature UI 一次性重写。
- [x] 为 design tokens 增加最小编译期/单元测试。

### Phase 3：基础 widgets/layouts

- [x] 建立 Button API，并迁移旧 theme button 实现。
- [x] 建立 TextField API，优先迁移 profile editor。
- [x] 建立 Surface layout API。
- [x] 将 resize handle 收敛为 SplitView layout 能力。

### Phase 4：feature UI 迁移

- [x] app shell/top bar/sidebar 进入 `ui/features/app_shell`，图标按钮使用 Shellow `IconButton`。
- [x] profile editor 进入 `ui/features/profiles`，常规输入框和 checkbox 使用 Shellow widgets。
- [x] terminal slot bar 的 button/menu 视觉入口统一到 Shellow widgets。
- [x] file toolbar/context menu/dialog 的常规 button/menu/checkbox 入口统一到 Shellow widgets。
- [x] transfer/status/settings 保持 feature-specific 绘制，常规交互控件不再直接调用 DVUI button/checkbox/menu API。

每次迁移一个 feature，禁止只做全仓机械替换而不检查视觉和交互。

### Phase 5：大型模块拆分

- [x] `ssh_workspace_worker.zig` 已拆出 PTY slot runtime、SSH monitor runtime、transfer progress store、remote path 和 file entry ordering；主文件保留 workspace/SFTP orchestration。
- [x] 删除旧 `ssh_session_worker.zig`，worker probe 与生产路径统一使用 workspace worker。
- [x] `App.zig` 已拆出 profile/settings/workspace actions、terminal state 和 transfer rules；facade 保留对 UI 的稳定方法。
- [x] terminal panel 已拆出 viewport state、search、input encoding 和 color/render policy；高耦合 selection/render loop 留在 panel coordinator。
- [x] file panel 已拆出 pane/path/selection/editor/dialog state，并继续复用独立 context menu、details、permissions、editor 和 transfer modules。

后续若继续压缩单文件体积，应以 profiling、测试可读性或明确 feature 需求驱动，不再为了目录层级机械拆分高耦合 immediate-mode frame 函数。

## 验收标准

每一批至少满足：

- `zig fmt` 后源码格式正确。
- `zig build test` 通过。
- `zig build` 通过。
- UI 批次运行 `zig build run`，窗口可启动且主要布局非空。
- SSH/SFTP、terminal 和 transfer 的依赖方向没有反转。
- feature UI 新增常规控件时优先通过 Shellow widgets。
- 文档路径与实际源码保持一致。

## 风险与控制

- 大规模移动导致 relative import 易错：每批移动后立即构建，不叠加多个未验证批次。
- UI wrapper 可能退化为 DVUI 同名转发：只有统一视觉、状态或重复交互时才新增 wrapper。
- theme 拆分可能造成循环依赖：foundation 只能向下依赖 DVUI，widgets/layouts 依赖 foundation。
- worker 拆分可能改变并发语义：目录归位与 runtime 行为拆分分成不同阶段，第一阶段不改变线程和锁逻辑。
