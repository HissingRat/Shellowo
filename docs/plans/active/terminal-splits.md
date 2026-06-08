# Terminal Splits and Slots Plan

## 背景

Shellow 当前一个 SSH workspace tab 只对应一个 SSH PTY terminal。下一阶段希望在单个 SSH workspace 内管理多个 terminal，并最终支持横向/纵向分屏。OSC title 更新会作为每个 terminal slot 的自然标题来源。

## 目标

- 一个 SSH workspace tab 内可以拥有多个 terminal slot。
- 每个 terminal slot 有独立 PTY channel、terminal emulator、scrollback、selection/search viewport 状态。
- terminal 顶部增加 compact terminal bar，展示当前 SSH workspace 内的 terminal slots。
- OSC title 更新进入 slot label；无 title 时使用稳定 fallback。
- 后续 split layout 通过 pane 绑定 terminal slot，不把协议状态塞进 UI widget。

## 非目标

- 第一阶段不一次性实现完整拖拽分屏布局。
- 不把多个 terminal 的 runtime 状态堆进 `terminal_panel.zig`。
- 不复用一个 shell byte stream 模拟多 terminal；每个 terminal slot 必须是独立 PTY shell channel。
- 不把 SFTP/transfer 走 terminal slot。

## 当前实现

- `MockSessionRegistry` 通过 `SshWorkspaceWorker` 为每个 SSH workspace tab 持有一个 SSH client。
- 每个 terminal slot 在该 workspace worker 内对应一个独立 PTY shell channel、terminal emulator 和 snapshot cache。
- UI 仍只通过 registry/app action 和 slot summary 访问 terminal slots，不直接持有协议/runtime 状态。

## 边界

```txt
WorkspaceTab
  -> SshWorkspaceRuntime
    -> TerminalSlot[]
      -> SshPtyChannel
      -> TerminalEmulator
      -> TerminalSnapshot

DVUI workspace
  -> terminal slot bar
  -> active terminal pane(s)
```

职责：

- `TerminalSlot`
  - runtime-independent model：id、title、fallback label、status。
  - 不持有 raw SSH/libvterm handle。
- `SshSessionWorker`
  - 后续扩展为管理多个 shell channel/emulator。
  - 对 UI 暴露 active slot snapshot、slot list、slot actions。
- `terminal_panel`
  - 只渲染一个 terminal pane 的 snapshot 和 viewport。
  - 不拥有 slot collection，不做协议生命周期。
- `workspace_view`
  - 渲染 terminal slot bar。
  - 将 active slot snapshot 交给 `terminal_panel`。

## 阶段计划

### 1. Slot 模型与计划基线

- [x] 新增 runtime-independent `TerminalSlot` model。
- [x] 明确 slot label fallback 和 OSC title 覆盖规则。
- [x] 将 `WorkspaceTab` 或 registry 摘要扩展出 terminal slot list 查询。

### 2. 多 terminal slot 切换栏

- [x] Registry 暴露当前 workspace 的 slot summaries。
- [x] UI 顶部增加 terminal slot bar。
- [x] 支持新建 slot。
- [x] 支持右键菜单关闭 slot；关闭最后一个 slot 时关闭整个 workspace tab。
- [x] 支持切换 active slot。
- [x] active slot 固定显示在 terminal bar 第一个位置。
- [x] terminal bar 超出宽度时显示 overflow 下拉菜单选择隐藏 slot。
- [x] 第一版只显示 active terminal，不做真正分屏。

### 3. 单 SSH session 多 PTY runtime

- [x] 引入 `SshWorkspaceWorker`，一个 SSH client 管理多个 terminal slot。
- [x] 将多 terminal 路径迁移到 workspace worker + `PtySlot`。
- [x] 每个 `PtySlot` 持有独立 shell channel、terminal emulator、pending input、resize 状态。
- [x] slot create/close/switch 走 workspace runtime，不再创建多个 SSH worker。
- [x] 保持 UI 只依赖 registry/app action 和 slot summary。

### 4. OSC title 更新

- [x] libvterm shim 暴露当前 title。
- [x] terminal snapshot/slot summary 携带 title。
- [x] slot bar 使用 OSC title 作为 label。
- [x] 无 title 时使用 `TerminalSlot.fallbackLabel()`。

### 5. 真正分屏布局

- [ ] 定义 split tree / pane model。
- [ ] pane 绑定 terminal slot id。
- [ ] 支持横向/纵向 split。
- [ ] 支持 pane resize。
- [ ] 支持 focus 切换和快捷键。

## 验收

- 一个 SSH workspace 内可以创建和切换多个 terminal。
- 每个 terminal 的输出、scrollback、selection、search 相互独立。
- OSC title 可以更新 slot bar label。
- 关闭一个 slot 不影响同 workspace 的其他 slot。
- `terminal_panel.zig` 仍只负责单 pane 渲染和 viewport 交互。
