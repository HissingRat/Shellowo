# File Panel MVP Roadmap

## 状态

MVP completed. 更复杂的批量冲突策略、跨目录占用说明和高级远程编辑体验作为后续增强单独规划。

## 背景

Shellow 现在已经有 `src/ui/workspace/file_panel.zig`，并已从早期写死 rows 的 DVUI mock panel 逐步升级为 snapshot-driven 文件工作区。下一阶段要继续向 FinalShell 风格收敛：SSH workspace 下方显示远端 SFTP 文件面板，左侧是远端目录树，右侧是当前目录文件表。

当前必须继续遵守既有边界：

- UI 不直接拥有协议 client 或 raw backend handle。
- 文件传输必须进入统一 transfer system。
- 文件 UI 只通过 app/session runtime 边界接收 snapshot 和发出 intent。

## 目标

- `file_panel` 只消费 runtime-independent snapshot。
- `file_panel` 只发出 intent，不直接执行 SFTP 或 local filesystem 操作。
- SSH workspace 支持 terminal + remote SFTP panel。
- 左侧远端目录树 + 右侧远端文件表布局先稳定下来，为上传下载和批量操作做准备。
- 上传、下载、删除、重命名等操作有明确 busy/error/disabled 状态。

## 非目标

- 不把 SFTP 文件传输塞进 terminal shell byte stream。
- 不在 DVUI widget 内直接调用 `libssh2`、socket 或 filesystem watcher。
- 不在 file panel 内维护 transfer progress；进度来自 transfer snapshot。
- 不做远程编辑器、双远端同步、权限编辑高级弹窗。

## 边界

```txt
DVUI file_panel
  -> FilePanelSnapshot / FilePanelIntent
    -> App / Session Registry
      -> SSH workspace runtime -> SFTP controller -> libssh2 backend
      -> transfer queue
```

职责：

- `src/ui/workspace/file_panel.zig`
  - 渲染远端目录树、远端文件表、路径栏、空态、错误态和右键菜单。
  - 将用户动作转换成 `FilePanelIntent`。
  - 不保存协议状态，不计算传输进度。
- `src/core/remote_file.zig`
  - 定义 `RemoteFileEntry`、`FilePanelSnapshot`、`FilePanelIntent` 和 capability 数据形状。
  - 可被 SFTP、local service 和 UI 共享。
- `src/services/session_registry.zig`
  - 根据 tab id 暴露 file snapshot。
  - 根据 tab id 分发 file intent 到对应 runtime。
- SSH workspace runtime
  - 管理 SFTP capability 生命周期。
  - 把 SFTP list/stat/mkdir/rename/delete 映射到 core file snapshot/result。
- Transfer system
  - 接收 upload/download intent，创建 transfer task。
  - file panel 只显示任务入口和来自 transfer snapshot 的摘要。

说明：

- `FilePanelSnapshot.tree` 承载左侧远端目录树快照；`FilePanelSnapshot.remote` 承载右侧当前远端目录表。
- `RemoteFileEntry.full_path/depth/expanded` 是第一版 tree node metadata；后续如果 tree 交互继续变复杂，可以再拆出独立 `FileTreeEntry`。

## 数据模型草案

第一版放在 `src/core/remote_file.zig`：

```zig
pub const RemoteFileEntry = struct {
    name: []const u8,
    kind: RemoteFileKind,
    size: ?u64 = null,
    permissions: ?u32 = null,
    modified_unix: ?i64 = null,
    uid: ?u64 = null,
    gid: ?u64 = null,
    full_path: []const u8 = "",
    depth: u8 = 0,
    expanded: bool = false,
};

pub const FilePanelSnapshot = struct {
    tree: FileTreeSnapshot,
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
    select: FileSelectIntent,
    toggle_tree: FileEntryTarget,
    refresh: FilePaneTarget,
    go_parent: FilePaneTarget,
    open: FileEntryTarget,
    create_file: FileCreateFileIntent,
    create_directory: FileCreateDirectoryIntent,
    rename: FileRenameIntent,
    delete: FileEntryTarget,
    upload: FileTransferIntent,
    upload_many: FileBatchTransferIntent,
    download: FileTransferIntent,
    download_many: FileBatchTransferIntent,
};
```

## 阶段计划

### M1: Core File Model

- [x] 扩展 `src/core/remote_file.zig`。
- [x] 定义 pane snapshot、capabilities、loading/error/unavailable 状态。
- [x] 定义 intent union。
- [x] `src/test_root.zig` 引入 remote file model。

验收：

- core 类型不依赖 DVUI、SSH 或 App。
- `zig build test` 通过。

### M2: UI Snapshot Render

- [x] `file_panel.show()` 改为消费 `FilePanelSnapshot`。
- [x] 移除 widget 内硬编码 mock rows。
- [x] 移除顶部文本 toolbar；refresh 使用路径栏 icon button，其余操作进入右键菜单。
- [x] 实现 loading、empty、error、unavailable 空态。
- [x] 单击选中，双击目录产生 open intent。
- [x] 支持 ctrl/cmd 多选。

验收：

- SSH workspace 能显示稳定文件 panel。
- 没有 snapshot 时显示 unavailable，不显示假远端数据。

### M3: App/Registry Mock Wiring

- [x] registry 暴露 `filePanelSnapshot(tab_id)`。
- [x] registry 暴露 `handleFilePanelIntent(tab_id, intent)`。
- [x] 第一版使用 mock snapshot 验证 UI，不接真实协议。
验收：

- UI 交互路径从 widget 到 registry 跑通。
- intent handler 可记录或更新本地 mock state。

### M4: SFTP Read-Only Browser

- [x] SSH workspace runtime 打开 SFTP capability。
- [x] 实现 remote list。
- [x] remote list metadata 已带回 size、modified、permissions、uid/gid，满足当前表格所需 stat 信息。
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
- [x] 将 tree snapshot 从 `FilePanelSnapshot.local` 兼容字段拆到独立数据结构。

验收：

- 左侧不再显示本机文件 mock。
- 远端路径变化时，左侧能高亮当前目录，并展示当前目录的子文件夹。
- tree 交互仍只发 intent，不直接调用协议层。

### M5: Mutations And Transfer

- [x] New File、New Folder、Rename、Delete 接入右键菜单和 inline/modal UI。
- [x] mkdir、rename、delete 接入 SFTP controller。
- [x] 第一版 download 支持多选文件/文件夹，默认下载到 `owoConfig.json` 中的 download path。
- [x] Upload、Upload Folder 和拖拽上传接入右键菜单/原生 drop 事件入口。
- [x] upload/download intent 创建正式 transfer task。
- [x] transfer queue 提供进度 snapshot、任务弹窗、进度条和取消入口。
- [x] transfer popup 保留完成/失败/取消历史，并显示 bytes、实时速度和 retry/dismiss 入口。
- [x] file panel 根据 transfer 状态禁用重复下载操作，并通过 path bar 显示 active task 摘要。
- [x] file panel 根据 path/entry 级 active transfer 禁用高风险操作，并在 upload/download 覆盖目标时弹出确认。
- [x] 下载默认目录进入 `owoConfig.json`，默认仍为程序目录旁 `owoDownloads/`。

验收：

- 第一版文件 mutation、上传、下载可用，并进入统一 transfer system。
- 取消/失败不破坏 pane 当前目录状态。

## 后续增强范围

当前 `file_panel` MVP 已推进到 M5，后续可继续收敛：

- 继续打磨更复杂的冲突策略，例如批量任务的 apply-to-all、覆盖后的 rename/skip 选择，以及更细的跨目录占用说明。
