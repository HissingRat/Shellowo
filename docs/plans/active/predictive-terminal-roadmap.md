# Shellow 高延迟流畅终端路线图

## 项目内定位

本文从外部草案整理进入 Shellow active plans，用于跟踪高 RTT 场景下 terminal 输入流畅度、预测显示和真实远端状态校正。它依赖并延续：

- `docs/plans/completed/ssh-terminal-mvp-runtime.md`
- `docs/plans/completed/libvterm-terminal-emulator.md`
- `docs/plans/active/terminal-enhancement-roadmap.md`

当前代码已经具备真实 SSH worker、PTY shell、libvterm snapshot、DVUI terminal panel、scrollback、selection、paste 和 alternate screen 基础能力。接下来第一优先级不是直接做复杂预测，而是确保 UI 输入路径只写入本地 intent/queue，所有 SSH read/write/resize 都由 worker 侧非阻塞地推进，并且 `WouldBlock` 或部分写入不会丢输入。

当前重点文件：

- `src/ui/workspace/terminal_panel.zig`: 只负责渲染 snapshot、输入编码、粘贴分块、resize intent 和未来本地预测显示。
- `src/runtime/sessions/registry.zig`: 负责把 tab intent 路由到 session/workspace worker。
- `src/runtime/sessions/ssh_workspace_worker.zig`: workspace coordinator，负责 SSH client、SFTP/file worker 和各 runtime 的生命周期协调。
- `src/runtime/terminal/pty_slot.zig`: terminal slot、PTY read/write/resize queue 和 snapshot cache。
- `src/runtime/monitor/ssh_monitor.zig`: 独立 SSH monitor/probe 状态。
- 单 terminal worker 已移除；probe 与生产路径统一使用 `ssh_workspace_worker.zig`。
- `src/runtime/sessions/ssh_session.zig`: 单会话 runtime facade，适合沉淀 write queue / read pump / resize 语义。
- `src/contracts/ssh.zig` 和 `src/backends/ssh/libssh2.zig`: Shellow SSH facade 与 libssh2 backend，不能让 raw libssh2 handle 上浮到 UI。
- `src/contracts/terminal_emulator.zig` 和 `src/backends/terminal/libvterm.zig`: terminal snapshot、dirty 信息、未来双 vterm / reconcile 的落点。

目标：让 Shellow 在 SSH 高延迟环境下，尽可能接近 FinalShell / Xshell / Mosh 的输入流畅度，同时保证在 Shell、Vim、Nano、Tmux、Htop、Less 等场景下不容易错乱。

---

## 总体架构目标

```text
Keyboard Input
     │
     ├──────────────► Predictive Terminal State ──► Renderer / dvui
     │
     └──────────────► SSH Write Queue ────────────► Remote PTY

Remote PTY
     │
     ▼
SSH Read Thread
     │
     ▼
Real Terminal State
     │
     ▼
Reconcile / Rollback
     │
     ▼
Predictive Terminal State
```

核心思想：

- UI 不等待 SSH round-trip。
- 输入先在本地预测显示。
- 远端真实输出回来后再校正。
- 预测失败时回滚到真实状态。
- 不追求 100% 永远预测正确，而是追求“预测错了也能快速恢复”。

---

# Phase 0：基础稳定性

目标：先确保普通 SSH 终端稳定，不做预测。

## 任务

- [x] SSH read / write 完全异步化。
- [x] UI 线程绝对不直接调用阻塞式 `libssh2_channel_read` / `write`。
- [x] 建立 SSH write queue。
- [x] 建立 SSH read thread。
- [x] 所有远端输出统一进入终端状态机。
- [x] 所有 UI 渲染只读取终端 screen state。

当前进展：

- [x] `src/runtime/sessions/ssh_workspace_worker.zig` 的 terminal input 使用 bounded pending byte queue。
- [x] `src/ui/workspace/terminal_panel.zig` 的键盘、文本、粘贴、鼠标和 resize intent 都通过 `App` / `session_registry` 路由到 worker，不直接触碰 `libssh2`。
- [x] SSH write 遇到 `WouldBlock` 时保留 pending input，下一轮继续写。
- [x] SSH write partial success 时只消费已经写出的字节，未写出的字节继续留在 queue。
- [x] 鼠标 escape bytes 先进入同一个 pending byte queue，避免 channel 暂时不可写时丢事件。
- [x] PTY resize 遇到 `WouldBlock` 时保留 latest retry request，不直接丢弃。
- [x] `src/runtime/sessions/ssh_workspace_worker.zig` 的 terminal pump 线程负责 `shell.read` / `shell.write` / `shell.resize`，远端输出经 `TerminalEmulator.write` 进入 libvterm 状态机。
- [x] `src/runtime/sessions/ssh_workspace_worker.zig` 的 status monitor exec 移到独立线程和独立 SSH client，避免周期性阻塞 terminal slot pump。
- [x] `src/runtime/sessions/ssh_workspace_worker.zig` 的 terminal slot 列表锁不再覆盖 open/read/write/resize/snapshot runtime 操作。
- [x] `src/runtime/sessions/ssh_workspace_worker.zig` 的 pump loop 改为 active-aware：有 pending input、resize、mouse、read output 或 dirty snapshot 时连续推进，完全空闲时才让出/sleep。
- [x] `terminal.Snapshot` 增加 generation，App 侧缓存当前可见 terminal snapshot；generation 未变化时复用 cached snapshot，避免空闲帧重复复制整屏 cells/scrollback。
- [x] `src/ui/workspace/terminal_panel.zig` 只渲染 `terminal.Snapshot` / fallback transcript，真实 SSH tab 的 screen 内容来自 `app.cachedSshSnapshot`。
- [x] `src/backends/terminal/libvterm_shim.c` 接入 libvterm screen damage callback，`terminal.Snapshot` 带 dirty row range 和 scrollback dirty 标记，为后续只更新变化行/光标区域做准备。
- [x] `terminal.Snapshot` 增加 cursor dirty/visible 元数据，`src/backends/terminal/libvterm_shim.c` 接入 libvterm `movecursor` callback，并把新旧光标所在行并入 dirty rows。
- [x] `src/ui/workspace/terminal_panel.zig` 的搜索结果按 snapshot generation/query 缓存；仅当前 screen dirty rows 变化且 scrollback 未变时，增量替换 dirty 行的搜索结果。
- [x] `src/ui/workspace/terminal_panel.zig` 的搜索高亮按已排序 match 做行级二分定位，避免每个可见行扫描全部搜索结果。
- [x] `src/ui/workspace/terminal_panel.zig` 缓存行级背景元数据；无选区且该行无背景样式时跳过整行 background pass，且未命中 dirty rows 的行可跨 snapshot generation 复用缓存。

## 建议结构

```text
src/
  terminal/
    terminal_state.zig
    terminal_renderer.zig
    input.zig
    reconcile.zig
  protocols/
    ssh_client.zig
    ssh_worker.zig
```

## 完成标准

- 普通 shell 输入稳定。
- Vim / Nano / Less / Htop 可以正常显示。
- 高输出量场景不会卡 UI。
- SSH WouldBlock 不会导致 UI 卡死或死循环。

---

# Phase 1：接入真正的终端状态机

目标：不要自己手写 VT 解析，使用成熟状态机。

推荐使用：

```text
libvterm
```

## 任务

- [x] 把 SSH 输出 feed 给 libvterm。
- [x] 从 libvterm 获取 screen cell。
- [x] 渲染 cell：字符、前景色、背景色、粗体、斜体、下划线。
- [x] 支持 cursor。
- [x] 支持 alternate screen。
- [x] 支持 scrollback。
- [x] 支持 resize。

当前进展：

- [x] `src/backends/terminal/libvterm.zig` 通过 `TerminalEmulator.write` 把 PTY bytes 写入 `libvterm`，并用 `snapshot` 读取 screen cells、scrollback、cursor、mode 和 title。
- [x] `src/backends/terminal/libvterm_shim.c` / `src/backends/terminal/libvterm_shim.h` 把 libvterm cell 的 codepoint、width、fg/bg、bold、italic、underline、blink、reverse、strike 映射到 Shellow `terminal.Cell` / `terminal.Style`。
- [x] `src/ui/workspace/terminal_panel.zig` 按 snapshot cell 渲染字符 run、前景色、背景色、粗体、斜体、下划线、删除线、reverse 和 cursor。
- [x] `src/backends/terminal/libvterm.zig` 已有文本、Unicode、ANSI color、scrollback、clear scrollback、alternate screen、bracketed paste、dirty rows 和 mouse mode 相关测试。
- [x] `src/runtime/sessions/ssh_workspace_worker.zig` 在 resize intent 到达时同步 resize libvterm emulator 和远端 PTY；远端 PTY `WouldBlock` 时保留 latest retry request。

## 数据流

```text
SSH bytes
   ↓
libvterm
   ↓
Screen cells
   ↓
dvui renderer
```

## 完成标准

- Vim / Nano / Tmux 基本可用。
- 光标位置正确。
- 颜色基本正确。
- 终端 resize 后远端程序能正确刷新。

---

# Phase 2：增量渲染

目标：提升本地渲染性能，避免每次全屏重绘。

## 任务

- [x] libvterm callback 里记录 dirty rows。
- [x] libvterm callback 里记录 dirty rects。
- [x] 渲染层只重绘变化区域。
- [x] 光标单独作为 dirty item。
- [x] 批量合并连续 dirty rows。
- [x] 限制 UI refresh rate，例如 60 FPS。

当前进展：

- [x] `src/backends/terminal/libvterm_shim.c` 记录 libvterm damage callback 给出的 dirty rect，并在 C shim 内合并相邻/重叠 rect；rect 过多时降级为 overflow/full dirty 语义。
- [x] `terminal.Snapshot` 增加 fixed-capacity `DirtyRects`，`src/backends/terminal/libvterm.zig` 把 C shim 的 dirty rects 映射到 Zig snapshot，并已有 snapshot 后清空 dirty metadata 的测试覆盖。
- [x] `src/ui/workspace/terminal_panel.zig` 的行级背景缓存优先使用 dirty rects 判断行是否变化；普通输入只让 dirty/cursor 命中的行失效，未变化行跨 snapshot generation 复用。
- [x] `src/app/App.zig` 对 terminal snapshot present 做约 60 FPS gate；worker 可继续高频 pump/read/write，但 UI 不会无限制复制并交付新 snapshot。
- [x] `src/ui/features/workspace/view.zig` 在有 pending snapshot generation 时通过 DVUI timer 请求下一次 present frame。

说明：Shellow 当前 DVUI 渲染仍是 immediate-mode frame 提交；这里的“只重绘变化区域”落在 terminal 层的 dirty-aware 行处理、缓存失效和 snapshot present 调度上，而不是底层窗口系统的像素级 partial present。若后续引入 retained terminal surface，可继续把 dirty rects 下沉为真正的纹理局部更新。

## Dirty 示例

```zig
const DirtyRect = struct {
    row_start: usize,
    row_end: usize,
    col_start: usize,
    col_end: usize,
};
```

## 完成标准

- `cat large_file` 不会明显卡顿。
- `top` / `htop` 刷新流畅。
- 普通输入不会触发整屏重绘。

---

# Phase 3：简单 Local Echo

目标：先实现安全版本地回显，只处理普通 shell 输入。

## 预测范围

可以先预测：

```text
ASCII printable chars
Space
Backspace
Enter
Tab
```

暂时不要预测：

```text
Ctrl+C
Ctrl+Z
Ctrl+D
Esc
方向键
鼠标事件
Bracketed Paste
复杂组合键
```

## 任务

- [x] 输入按键后立即修改本地 screen。
- [x] 同时把输入写入 SSH queue。
- [x] 收到远端输出后，以远端输出为准。
- [x] 发现明显冲突时清空预测状态。

当前进展：

- [x] `App.cachedSshSnapshot` 将 worker real snapshot 同步进 `DualState`，UI renderer 读取 `predictedSnapshot`；真实远端 snapshot 仍然是最终权威状态。
- [x] 在普通 shell prompt 行尾下预测 printable ASCII 和 Backspace；输入仍同步进入 `App.sendTerminalBytes` / SSH write queue。
- [x] snapshot generation 变化、进入 alternate screen、bracketed paste、mouse reporting、搜索/选区/滚动/粘贴队列等状态时清空或禁用预测，远端输出回来后自动回到真实画面。
- [x] 通过 prompt 形态和敏感词过滤避免在 `password` / `passphrase` / `otp` / `token` 等提示下本地回显。
- [x] Enter 采用保守光标预测；Readline level 已支持行内编辑、Tab、左右/Home/End/Delete 和 Ctrl+A/B/E/F，复杂历史导航仍不预测。

## 注意

这一阶段不要追求 Vim / Nano 预测。

先让普通 shell 在高 RTT 下输入变流畅。

## 完成标准

- Bash / Zsh 提示符下输入字符无明显延迟。
- 不出现双字符。
- 输入密码时不会本地显示密码。

---

# Phase 4：双终端状态模型

目标：进入真正的预测终端架构。

维护两个状态：

```text
real_vterm       = 远端真实状态
predicted_vterm  = 用户当前看到的预测状态
```

## 数据流

```text
Keyboard
   ↓
predicted_vterm.feed_local_input()
   ↓
Renderer

SSH output
   ↓
real_vterm.feed_remote_output()
   ↓
compare(real_vterm, predicted_vterm)
   ↓
reconcile
```

## 任务

- [x] 实现 real screen snapshot。
- [x] 实现 predicted screen snapshot。
- [x] 实现 screen diff。
- [x] 实现 predicted 状态回滚到 real。
- [x] 实现小范围差异修补。

当前进展：

- [x] 新增 `src/core/terminal/predictive.zig`，提供 `DualState`，拥有 real snapshot 和 predicted snapshot 两套状态。
- [x] `DualState.syncReal` 接收远端真实 snapshot；首次同步时初始化 predicted snapshot，后续同步时先 diff 再 reconcile。
- [x] `diffSnapshots` 比较 screen cells、cursor、alternate screen、bracketed paste、mouse mode、size、scrollback 内容，并输出 dirty rects / mismatch count / structural flags。
- [x] `DualState.feedLocalInput` 支持最小本地预测输入：printable ASCII 和 Backspace，直接修改 predicted snapshot。
- [x] `DualState.resetPredictedToReal` 支持预测状态回滚到真实状态。
- [x] 小范围 cell 差异会按 dirty rect 从 real patch 到 predicted；size/mode/scrollback 等结构性差异会直接回滚到 real。
- [x] 已加入 `src/test_root.zig`，覆盖 diff、local input prediction、real sync、结构性回滚。

说明：Phase 4 的 terminal 层双 snapshot / diff / reconcile 核心模型已接入当前 active terminal cache；UI renderer 已优先读取 `DualState.predictedSnapshot`。

## Diff 需要比较

```text
cell char
cell width
foreground color
background color
attributes
cursor row / col
alternate screen state
scroll region
```

## 完成标准

- 预测失败不会长期错乱。
- 最坏情况只是闪一下，然后恢复到远端真实画面。
- 普通 shell 体验明显提升。

---

# Phase 5：输入事件队列与预测记录

目标：知道当前有哪些本地输入还没被远端确认。

## 数据结构

```zig
const PendingInput = struct {
    id: u64,
    timestamp_ms: u64,
    bytes: []const u8,
    prediction_kind: PredictionKind,
};
```

## 任务

- [x] 每次输入分配递增 id。
- [x] 输入进入 pending queue。
- [x] 输入同时进入 predicted_vterm。
- [x] 输入发送给 SSH。
- [x] 收到远端输出后尝试确认 pending input。
- [x] 超时未确认则降级预测。

当前进展：

- [x] `src/core/terminal/predictive.zig` 增加 `PredictionKind` 和 owned `PendingInput`，记录 id、timestamp、bytes、prediction kind。
- [x] `DualState.recordLocalInput` 为每次本地输入分配递增 id，复制 bytes，进入 pending queue，并同步调用 `feedLocalInput` 更新 predicted snapshot。
- [x] pending queue 设置总字节上限；超过上限会清空 pending 并回滚 predicted 到 real，避免网络卡顿时无限增长。
- [x] `DualState.syncReal` 在远端真实 snapshot 到达时比较 real/predicted；一致则确认并清空 pending input，不一致则按 Phase 4 reconcile 后清空未确认预测。
- [x] `DualState.expirePendingInputs` 支持按 timestamp/timeout 降级预测：超时后回滚 predicted 到 real 并清空 pending queue。
- [x] UI 侧输入发送 SSH queue 仍沿用 Phase 0 已完成的 `App.sendTerminalBytes` / worker pending byte queue；预测记录通过 `App.recordTerminalPrediction` 进入 `DualState.recordLocalInput`。
- [x] 已有测试覆盖 id 递增、pending bytes 统计、预测写入 predicted snapshot、远端确认清空、冲突清空、超时回滚和 prediction kind 分类。

## PredictionKind

```zig
const PredictionKind = enum {
    printable_char,
    backspace,
    enter,
    tab,
    arrow_key,
    readline_control,
    unknown,
};
```

## 完成标准

- 可以追踪哪些输入处于预测状态。
- 网络卡顿时 pending 不会无限增长。
- 大量连续输入后仍能恢复一致。

---

# Phase 6：预测等级系统

目标：根据场景和按键类型决定是否预测。

## Level 0：安全预测

适合：普通 shell 输入。

预测：

```text
普通字符
数字
空格
Backspace
Enter
```

## Level 1：中等预测

适合：readline / shell 编辑。

预测：

```text
方向键
Delete
Home
End
Ctrl+A
Ctrl+E
```

## Level 2：TUI 插入预测

适合：Vim insert mode、Nano 普通输入。

预测：

```text
普通字符
Backspace
Enter
Tab
部分方向键
```

## Level 3：禁止预测

适合：危险输入。

不预测：

```text
Ctrl+C
Ctrl+Z
Ctrl+D
Esc
Alt sequences
F1-F12
鼠标事件
Bracketed paste
未知 escape sequence
```

## 任务

- [x] 给每种输入分类。
- [x] 给每个 session 维护当前 prediction level。
- [x] 冲突多时自动降级。
- [x] 稳定一段时间后自动升级。

当前进展：

- [x] `src/core/terminal/predictive.zig` 增加 `PredictionLevel`：`safe_shell`、`readline`、`tui_insert`、`disabled`。
- [x] `classifyPrediction` 覆盖 printable、Backspace、Enter、Tab、方向键、readline control 和 unknown。
- [x] 新增 `PredictionContext` / `PredictionDecision` / `decidePrediction`，根据 snapshot mode、bracketed paste、mouse mode、敏感 prompt、选区、搜索、滚动、粘贴队列、输入类型和 prediction level 决定是否预测。
- [x] `DualState` 增加 `PredictionPolicyState`，作为 session 级 prediction level 状态；`syncRealAt` 会根据 diff 自动记录稳定/冲突。
- [x] 冲突多时自动降级；严重冲突会进入 `disabled` 并设置短 cooldown；稳定多次后自动从 `safe_shell` 升级到 `readline`，再到 `tui_insert`。
- [x] `src/ui/workspace/terminal_panel.zig` 的输入预测已改为调用 App / terminal core 的 `decidePrediction` 和 `recordLocalInput`，当前默认跟随用户配置。
- [x] `applyLocalInput` 已实现 Readline 行内插入/删除、左右/Home/End/Delete、Ctrl+A/B/E/F；上/下历史导航仍保守交给远端。
- [x] printable prediction 支持 UTF-8 单宽字符、CJK 和常见 emoji 宽字符；组合字符与 variation selector 继续主动禁用。
- [x] 已有测试覆盖 level gate、Readline 行内编辑、宽字符、alternate screen 策略、disabled 禁止预测、冲突降级/cooldown 恢复、稳定升级。

说明：真实远端 diff 已经通过 `App.cachedSshSnapshot` -> `DualState.syncRealAt` 反馈给当前 active terminal 的 prediction policy。

## 完成标准

- Shell 下很流畅。
- Vim / Nano 下普通输入也能变流畅。
- 复杂操作预测失败后能自动降级。

---

# Phase 7：TUI 场景预测

目标：让 Vim / Nano / Tmux 这类程序下也有流畅输入体验。

## 核心策略

不要真的理解 Vim / Nano。

只预测终端层面的结果：

```text
当前光标位置写入字符
光标右移
必要时换行
Backspace 删除前一个 cell
```

## 任务

- [x] 检测 alternate screen。
- [x] alternate screen 下默认使用更保守的预测策略。
- [x] 对 printable char 做 cell-level optimistic insert。
- [x] 对 Backspace 做 cell-level optimistic delete。
- [x] 对 Enter 做保守预测。
- [x] 对 Tab 默认不预测或弱预测。
- [x] 远端输出一回来立即 reconcile。

当前进展：

- [x] `src/core/terminal/predictive.zig` 的 `decidePrediction` 已区分 normal screen / alternate screen；alternate screen 只有 `tui_insert` level 且配置允许时才预测。
- [x] `DualState.recordLocalInput` 在 `tui_insert` level 下可对 alternate screen 做 cell-level printable insert 和 Backspace delete。
- [x] Enter 采用保守预测：只在有下一行时移动 predicted cursor 到下一行行首，不猜 prompt 或程序语义。
- [x] Tab 默认不预测，除非用户配置 `predict_tab = true`。
- [x] 启用 Tab 预测后，本地 predicted snapshot 会按 terminal tab stop 推进并填充空格，远端补全结果到达后照常 reconcile。
- [x] 远端 real snapshot 到达时继续走 `syncRealAt` diff/reconcile，保证 TUI 预测失败能快速回到真实状态。
- [x] 已有测试覆盖 alternate screen printable prediction、Enter conservative movement。

说明：UI renderer 已切到 `DualState.predictedSnapshot`；TUI 预测是否启用取决于 prediction mode 和当前 policy level。

## Vim Insert Mode 示例

```text
按下 a
  ↓
predicted screen 当前 cell = 'a'
  ↓
cursor col += 1
  ↓
SSH send 'a'
```

## 完成标准

- Vim insert mode 下连续输入明显更顺。
- Nano 下普通文字输入明显更顺。
- Normal mode / command mode 下即使预测失败也能快速恢复。

---

# Phase 8：冲突检测与自动回滚

目标：保证“可以预测错，但不能一直错”。

## 冲突指标

```text
不同 cell 数量
cursor 差异
scrollback 差异
alternate screen 状态变化
远端清屏
远端大范围重绘
```

## 策略

```text
small diff    -> patch predicted
medium diff   -> partial rollback
large diff    -> predicted = real
huge diff     -> 禁用预测一小段时间
```

## 任务

- [x] 实现 diff score。
- [x] 设置 rollback threshold。
- [x] 设置 prediction cooldown。
- [x] 大范围重绘时直接同步到 real。

当前进展：

- [x] `diffScore` 对 cell mismatch、cursor、mode、scrollback、size、dirty rect overflow 加权评分。
- [x] `assessDiff` 将 diff 分为 `patch`、`partial_rollback`、`full_rollback`、`disable_temporarily`。
- [x] `PredictionConfig` 提供 `rollback_threshold`、`disable_threshold`、`cooldown_ms`。
- [x] `DualState.patchPredictedFromReal` 在结构性 diff、full rollback 或 disable action 下直接 `predicted = real`。
- [x] `PredictionPolicyState.observeDiff` 会在严重冲突时进入短 cooldown，并记录 rollback count。
- [x] 已有测试覆盖 small/medium/large/huge diff action。

## 示例

```zig
if (diff_score > full_rollback_threshold) {
    predicted.copyFrom(real);
    prediction_level = .disabled_temporarily;
}
```

## 完成标准

- `vim` 模式切换不会长期错位。
- `tmux` 切 pane 不会错乱。
- `less` 翻页时可以快速恢复。

---

# Phase 9：延迟感知策略

目标：根据网络 RTT 动态决定预测强度。

## RTT 获取方式

可以用：

```text
SSH keepalive round-trip
应用层 ping
输入到回显的时间估算
```

## 策略

```text
RTT < 30ms      -> 不需要强预测
RTT 30~100ms    -> 开启 shell local echo
RTT 100~300ms   -> 开启 TUI printable prediction
RTT > 300ms     -> 更激进预测 + 更快 rollback
```

## 任务

- [x] 实现 RTT sampler。
- [x] 根据 RTT 自动调整 prediction level。
- [x] 给用户设置手动开关。

当前进展：

- [x] `RttSampler` 维护 last sample 和 smoothed RTT。
- [x] `PredictionPolicyState.observeLatency` 根据 `RttSampler.suggestedLevel` 调整 prediction level。
- [x] 低延迟保持保守，高 RTT 可建议 `tui_insert`。
- [x] 内部策略仍保留分级；用户设置只暴露 `off` 与 `auto`。
- [x] 可预测输入被真实 terminal snapshot 确认后，记录 input-to-echo latency；连续输入支持按 pending prefix 分批确认，不会因部分回显清空整批预测。
- [x] SSH workspace monitor client 每 5 秒通过独立 exec channel 做低频轻量 latency probe，不污染用户 PTY。
- [x] echo 样本权重大于主动 probe；EWMA 对异常值限幅，并通过升级迟滞、快速降级和既有 cooldown 控制预测等级。
- [x] prediction state 按 `(tab_id, terminal_slot_id)` 独立保存，slot 切换不会丢失 latency、pending、rollback 和策略状态。
- [x] Echo 与 Probe 分别维护 last/smoothed 样本；状态栏 tooltip 同时显示 Echo / Probe / Adaptive，不再被最后一次 probe 覆盖。
- [x] 大范围或结构性远端输出会触发 output-rate gate，在短窗口内暂停新预测，避免等到 predicted diff 冲突后才回滚。

说明：这里显示的 latency 是 terminal echo latency 与独立 SSH exec probe 的融合估计，比纯 ICMP RTT 更贴近用户实际输入体验。

## 完成标准

- 低延迟下不引入多余风险。
- 高延迟下自动增强预测。

---

# Phase 10：用户可配置选项

目标：给用户控制权。

## 推荐配置

```toml
[terminal.prediction]
enabled = true
mode = "auto" # off, auto
max_pending_inputs = 256
rollback_threshold = 64
cooldown_ms = 250
predict_in_alt_screen = true
predict_printable = true
predict_backspace = true
predict_arrow_keys = true
```

## UI 显示

状态栏可以显示：

```text
Prediction: Auto
RTT: 186ms
Pending: 12
Rollback: 0
```

## 完成标准

- [x] 用户可以完全关闭预测。
- [x] 用户可以选择关闭或自动。
- [x] 出问题时容易排查。

当前进展：

- [x] `PredictionConfig` 覆盖 `enabled`、`mode`、pending 限制、rollback/disable threshold、cooldown、alternate screen 和各输入类型开关。
- [x] `PredictionPolicyState.applyConfig` 可应用配置并重置策略状态。
- [x] `PendingInput` / `PredictionPolicyState` 暴露 pending count、pending bytes、rollback count、RTT sampler 等状态，便于后续状态栏/诊断面板展示。
- [x] terminal slot bar 显示当前 mode/level、Adaptive/Echo/Probe latency、output gate、pending input 和 rollback count。
- [x] settings popup 只开放 Off / Auto；Arrows、alternate screen 和关键 tuning 使用固定产品默认值，不提供修改入口。

说明：配置已接入 `owoConfig.json` 持久化；旧 Safe/Aggressive 和旧 tuning 值加载时会迁移为 Off/Auto 与固定默认值。

---

# Phase 11：Mosh 风格远端 Agent

目标：如果以后想超过普通 SSH 客户端，走状态同步协议。

这不是第一阶段要做的。

## 架构

```text
Shellow Client
     ↕
State Diff Protocol
     ↕
Shellow Remote Agent
     ↕
Local PTY on server
```

## 优点

- 可以真正同步终端状态，而不是猜 SSH 输出。
- 丢包和高延迟下体验更好。
- 可以支持断线重连。
- 可以支持移动网络 IP 切换。

## 缺点

- 需要远端安装 agent。
- 不再是纯 SSH 客户端。
- 协议复杂度明显上升。

## 建议

先不要做。

等 Shellow 普通 SSH 终端稳定后，再作为高级模式开发。

当前进展：

- [x] `RemoteAgentPlan` / `RemoteAgentMode` 已作为 capability stub 放入 `src/core/terminal/predictive.zig`。
- [x] 默认保持 disabled；只有 proposed 且支持 state diff 时才视为 available。
- [x] 未实现远端安装、协议、agent 传输或状态同步运行时，符合本阶段“先不要做”的路线图建议。

---

# 推荐实际开发顺序

## 第一轮：稳定可用

```text
Phase 0
Phase 1
Phase 2
```

目标：先做一个稳定、正确、不卡 UI 的 SSH 终端。

---

## 第二轮：Shell 输入流畅

```text
Phase 3
Phase 4
Phase 5
```

目标：普通 shell 下打字接近本地体验。

---

## 第三轮：Vim / Nano 流畅

```text
Phase 6
Phase 7
Phase 8
```

目标：TUI 下普通输入也流畅，同时预测错了能恢复。

---

## 第四轮：高级体验

```text
Phase 9
Phase 10
```

目标：根据网络情况自动调节预测策略。

---

## 第五轮：Mosh 化

```text
Phase 11
```

目标：实现远端 agent、状态同步、断线重连。

---

# 最小可行版本 MVP

如果只想尽快做出效果，最小路线是：

```text
1. libvterm
2. SSH read/write 独立线程
3. dirty rows 增量渲染
4. shell local echo
5. predicted/real 双 screen
6. diff 太大就 rollback
```

不要一开始就做完整 Mosh。

MVP 目标：

```text
RTT 150~300ms 时，Bash/Zsh 输入明显变顺。
Vim/Nano 插入普通字符时明显变顺。
预测失败不会长期错乱。
```

---

# 核心原则

1. 远端真实输出永远是最终权威。
2. 本地预测只是临时画面。
3. UI 线程永远不能被 SSH 阻塞。
4. 预测错了必须能快速回滚。
5. 不要试图理解所有远端程序，只预测终端屏幕变化。
6. 越复杂的输入，越应该保守。
7. 高 RTT 才需要激进预测。
8. 用户必须能关闭预测。

---

# 风险清单

## 双字符

原因：本地预测显示一次，远端回显又显示一次。

解决：

```text
real output 到来后做 reconcile，而不是直接叠加到 predicted。
```

## 光标错位

原因：预测了字符宽度、换行、组合字符，但远端行为不同。

解决：

```text
使用 wcwidth。
遇到 CJK / emoji / combining mark 时降低预测等级。
```

## Vim Normal Mode 误预测

原因：按 `j/k/h/l` 时不是插入字符，而是移动光标。

解决：

```text
alternate screen 下对普通字符预测要更保守。
冲突频繁时自动禁用。
```

## 密码泄露

原因：远端关闭 echo，但本地仍预测显示。

解决：

```text
检测无回显场景。
短时间内输入没有远端确认时关闭 local echo。
提供敏感模式禁用预测。
```

## 大量输出时错乱

原因：预测状态和远端滚屏同时发生。

解决：

```text
远端大范围输出时暂停预测。
```

---

# 建议优先级

```text
P0: SSH 异步读写
P0: libvterm 正确渲染
P0: resize / alternate screen
P1: dirty rows
P1: shell local echo
P2: 双 vterm
P2: diff / rollback
P2: pending input queue
P3: TUI printable prediction
P3: RTT adaptive prediction
P4: Mosh-style remote agent
```

---

# 结论

FinalShell / Xshell 这类客户端在高延迟下流畅，本质不是 SSH 变快，而是：

```text
本地预测显示
+
远端真实状态校正
+
失败快速回滚
```

Shellow 最现实的路线是：

```text
先做正确终端
再做简单预测
再做双状态校正
最后再考虑 Mosh 风格 agent
```

这样可以一步一步提升体验，而不是一开始就陷入复杂协议设计。
