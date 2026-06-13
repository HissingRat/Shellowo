# File Panel MVP Roadmap

## 背景

Shellow 现在已经有 `src/ui/workspace/file_panel.zig`，并已从早期写死 rows 的 DVUI mock panel 逐步升级为 snapshot-driven 文件工作区。下一阶段要继续向 FinalShell 风格收敛：SSH workspace 下方显示远端 SFTP 文件面板，左侧是远端目录树，右侧是当前目录文件表；FTP workspace 后续使用 file-only 文件工作区。

当前必须继续遵守既有边界：

- SSH/SFTP 与 FTP controller/runtime 分离。
- UI 不直接拥有协议 client 或 raw backend handle。
- 文件传输必须进入统一 transfer system。
- 文件 UI 可以共享数据形状和交互模型，但不能强行共享 session runtime。

## 目标

- `file_panel` 只消费 runtime-independent snapshot。
- `file_panel` 只发出 intent，不直接执行 SFTP/FTP/local filesystem 操作。
- SSH workspace 支持 terminal + remote SFTP panel。
- FTP workspace 复用文件 UI，但走独立 FTP runtime。
- 左侧远端目录树 + 右侧远端文件表布局先稳定下来，为上传下载和批量操作做准备。
- 上传、下载、删除、重命名等操作有明确 busy/error/disabled 状态。

## 非目标

- 第一阶段不完成完整 FTP runtime。
- 不把 SFTP 文件传输塞进 terminal shell byte stream。
- 不在 DVUI widget 内直接调用 `libssh2`、socket、filesystem watcher 或 FTP parser。
- 不在 file panel 内维护 transfer progress；进度来自 transfer snapshot。
- 不做远程编辑器、双远端同步、权限编辑高级弹窗。

## 边界

```txt
DVUI file_panel
  -> FilePanelSnapshot / FilePanelIntent
    -> App / Session Registry
      -> SSH workspace runtime -> SFTP controller -> libssh2 backend
      -> FTP workspace runtime -> FTP controller
      -> transfer queue
```

职责：

- `src/ui/workspace/file_panel.zig`
  - 渲染远端目录树、远端文件表、路径栏、空态、错误态和右键菜单。
  - 将用户动作转换成 `FilePanelIntent`。
  - 不保存协议状态，不计算传输进度。
- `src/core/remote_file.zig`
  - 定义 `RemoteFileEntry`、`FilePanelSnapshot`、`FilePanelIntent` 和 capability 数据形状。
  - 可被 SFTP、FTP、local service 和 UI 共享。
- `src/services/session_registry.zig`
  - 根据 tab id 暴露 file snapshot。
  - 根据 tab id 分发 file intent 到对应 runtime。
- SSH workspace runtime
  - 管理 SFTP capability 生命周期。
  - 把 SFTP list/stat/mkdir/rename/delete 映射到 core file snapshot/result。
- FTP workspace runtime
  - 后续单独实现 file-only session。
  - 不复用 SSH/SFTP runtime 类型。
- Transfer system
  - 接收 upload/download intent，创建 transfer task。
  - file panel 只显示任务入口和来自 transfer snapshot 的摘要。

说明：

- `FilePanelSnapshot.local` 当前作为兼容字段承载左侧目录树快照，不代表真实本机文件服务。
- `RemoteFileEntry.full_path/depth/expanded` 是第一版 tree metadata；长期应拆成独立 `FileTreeSnapshot`，避免 table entry 与 tree node 语义混在一起。

## 数据模型草案

第一版放在 `src/core/remote_file.zig`：

```zig
pub const RemoteFileEntry = struct {
    name: []const u8,
    kind: RemoteFileKind,
    size: ?u64 = null,
    permissions: ?u32 = null,
    modified_unix: ?i64 = null,
    full_path: []const u8 = "",
    depth: u8 = 0,
    expanded: bool = false,
};

pub const FilePanelSnapshot = struct {
    local: FilePaneSnapshot,
    remote: FilePaneSnapshot,
};

pub const FilePaneSnapshot = struct {
    location: FileLocation,
    path: []const u8,
    state: FilePaneState,
    entries: []const RemoteFileEntry,
    selected_name: ?[]const u8 = null,
    error_summary: ?[]const u8 = null,
    capabilities: FilePaneCapabilities = .{},
};

pub const FilePanelIntent = union(enum) {
    refresh: FilePaneTarget,
    open: FileEntryTarget,
    go_parent: FilePaneTarget,
    create_directory: FileCreateDirectoryIntent,
    rename: FileRenameIntent,
    delete: FileEntryTarget,
    upload: FileTransferIntent,
    download: FileTransferIntent,
};
```

## 阶段计划

### M1: Core File Model

- [x] 扩展 `src/core/remote_file.zig`。
- [x] 定义 pane snapshot、capabilities、loading/error/unavailable 状态。
- [x] 定义 intent union。
- [x] `src/test_root.zig` 引入 remote file model。

验收：

- core 类型不依赖 DVUI、SSH、FTP 或 App。
- `zig build test` 通过。

### M2: UI Snapshot Render

- [x] `file_panel.show()` 改为消费 `FilePanelSnapshot`。
- [x] 移除 widget 内硬编码 mock rows。
- [x] 移除顶部文本 toolbar；refresh 使用路径栏 icon button，其余操作进入右键菜单。
- [x] 实现 loading、empty、error、unavailable 空态。
- [x] 单击选中，双击目录产生 open intent。
- [x] 支持 ctrl/cmd 多选。

验收：

- SSH 和 FTP workspace 都能显示稳定文件 panel。
- 没有 snapshot 时显示 unavailable，不显示假远端数据。

### M3: App/Registry Mock Wiring

- [x] registry 暴露 `filePanelSnapshot(tab_id)`。
- [x] registry 暴露 `handleFilePanelIntent(tab_id, intent)`。
- [x] 第一版使用 mock snapshot 验证 UI，不接真实协议。
- [x] FTP tab 显示 file-only unavailable/mock 状态，不出现 terminal 或 SSH monitor 假信息。

验收：

- UI 交互路径从 widget 到 registry 跑通。
- intent handler 可记录或更新本地 mock state。

### M4: SFTP Read-Only Browser

- [x] SSH workspace runtime 打开 SFTP capability。
- [x] 实现 remote list。
- [ ] 实现 remote stat。
- [x] directory open、parent、refresh 更新 remote pane snapshot。
- [x] 当前目录表按 folder 在前、file 在后排序。
- [x] 错误映射成用户可读 summary。

验收：

- SSH tab 能浏览远端目录。
- SFTP 失败不影响当前 terminal PTY。
- UI 不接触 raw libssh2 handle。

### M4.5: Remote Directory Tree Pane

- [x] 左侧 pane 从本机 mock 文件列表切换为远端目录树。
- [x] 树第一版由 worker 维护已访问/已展开目录缓存，不因右侧路径变化隐藏其他已知文件夹。
- [x] 点击 tree node 打开对应远端路径。
- [x] folder/file png icon 进入 file entry 和 tree node，并通过 tint 适配 theme。
- [x] worker 维护目录树缓存，支持展开已访问目录和懒加载未访问目录。
- [x] 支持 tree node 展开/收起状态，而不是只展示当前路径相关节点。
- [ ] 将 tree snapshot 从 `FilePanelSnapshot.local` 兼容字段拆到独立数据结构。

验收：

- 左侧不再显示本机文件 mock。
- 远端路径变化时，左侧能高亮当前目录，并展示当前目录的子文件夹。
- tree 交互仍只发 intent，不直接调用协议层。

### M5: Mutations And Transfer

- [x] New File、New Folder、Rename、Delete 接入右键菜单和 inline/modal UI。
- [x] mkdir、rename、delete 接入 SFTP controller。
- [x] 第一版 download 支持多选文件/文件夹，下载到程序目录旁 `owoDownloads/`。
- [ ] upload/download intent 创建正式 transfer task。
- [ ] transfer queue 提供进度 snapshot。
- [ ] file panel 根据 transfer 状态禁用重复操作或显示 busy 摘要。
- [ ] 评估并实现从 file panel 拖出远端文件/文件夹到本机文件管理器；优先 macOS file promise，Windows/Linux 后续走平台 drag source 适配。
- [x] 下载默认目录进入 `owoConfig.json`，默认仍为程序目录旁 `owoDownloads/`。

验收：

- 第一版文件 mutation 可用；上传下载后续进入统一 transfer system。
- 取消/失败不破坏 pane 当前目录状态。

### M6: FTP Runtime

- [ ] 定义独立 FTP controller/runtime。
- [ ] FTP workspace 使用同一 `FilePanelSnapshot` 数据形状。
- [ ] FTP list/mkdir/rename/delete/upload/download 按独立 controller 接入。

验收：

- FTP tab 是 file-only 工作区。
- FTP 不复用 SSH/SFTP runtime 类型。

## 第一轮代码范围

本轮只做 M1：

- 扩展 `src/core/remote_file.zig`。
- 引入 `src/test_root.zig`。
- 跑 `zig build test`。

完成后再进入 M2，把 `file_panel` 从 mock rows 改成 snapshot-driven widget。
