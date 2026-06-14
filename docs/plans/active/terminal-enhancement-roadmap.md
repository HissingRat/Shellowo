# Terminal Enhancement Roadmap

## 背景

Shellow 已经具备真实 SSH PTY 字节流、`libvterm` emulator snapshot 和 DVUI terminal panel 的第一版渲染。下一阶段目标是让它从“能连上并显示输出”推进到“日常可用的真 terminal”。

本计划聚焦 terminal 体验与渲染能力。协议连接、认证、host key 和 SFTP 仍由各自 active plan 跟踪。

相关计划：

- `docs/plans/active/ssh-terminal-mvp-runtime.md`
- `docs/plans/active/libvterm-terminal-emulator.md`
- `docs/plans/active/libssh2-ssh-wrapper.md`

## 目标

- 支持 SSH terminal 的基础日常操作：输入、复制、粘贴、滚动、resize。
- 保持终端渲染由 Shellow terminal snapshot / viewport 驱动，不在 DVUI widget 中解析 ANSI/VT。
- 建立 scrollback、selection、search、alternate screen 等能力的清晰边界。
- 为后续性能优化和 terminal 回归测试预留结构。

## 非目标

- 不手写完整 ANSI/VT parser。
- 不把文件传输塞进 shell byte stream。
- 不让 raw `VTerm*`、raw `LIBSSH2_*` handle 进入 UI。
- 不在第一阶段追求 sixel、GPU renderer、复杂 ligature 或完整 xterm 私有扩展。

## 边界

```txt
DVUI terminal panel
  -> TerminalViewport
    -> TerminalEmulator snapshot / scrollback
      -> libvterm backend

SSH PTY channel
  -> TerminalEmulator.write(bytes)
  -> TerminalEmulator.resize(cols, rows)
  -> SshShell.resize(cols, rows)
```

概念职责：

- `TerminalEmulator`
  - 接收 PTY bytes。
  - 维护 screen、cursor、style、alternate screen、scrollback。
  - 产出 snapshot / viewport 可消费状态。
- `TerminalViewport`
  - UI 层状态：font metrics、visible rows/cols、scroll offset、selection、search highlight。
  - 不解析 escape sequence。
- `SshPtyChannel`
  - 协议层 byte stream。
  - 只负责 read/write/resize/close。

## 能力清单

### 1. PTY resize 同步

- [x] 根据 terminal panel 尺寸和字体 cell size 计算 cols/rows。
- [x] 将同一组 cols/rows 同步给 `TerminalEmulator.resize()` 和 SSH PTY resize。
- [x] resize intent 合并为 latest-size intent，避免拖动窗口时把中间尺寸排成长队。
- [ ] 字号变化后触发重新计算和 PTY resize。Deferred：字号设置暂不进入当前实现主线。

验收：

- shell prompt 与窗口宽度一致。
- `vim`、`top`、`less` 等 TUI 程序尺寸正确。
- 调整 terminal/file 分隔线后远端 rows/cols 能跟随变化。

### 2. Scrollback 上下滑动

- [x] 在 terminal runtime/emulator 层维护 scrollback buffer。
- [x] UI 保存 `scroll_offset`，鼠标滚轮/触控板上滑时显示历史内容。
- [x] 用户在底部时新输出自动跟随。
- [x] 用户正在看历史时新输出不强制跳到底。
- [x] 输入键盘内容时默认回到底部。
- [x] 设置 scrollback 行数上限，例如默认 10k 行。

当前限制：

- resize 会保留 scrollback；旧列宽历史行按当前宽度截断或补空显示，后续 reflow 阶段再优化。
- alternate screen 已区分；TUI 鼠标协议和更完整的 mouse reporting 后续专项处理。

验收：

- 普通 shell 输出可以向上回看。
- 长日志输出时，用户停在历史位置不会被新输出打断。
- 回到底部后继续自动跟随新输出。

### 3. 光标与 monospace grid

- [x] 初版闪烁下划线 cursor。
- [x] terminal 失焦时隐藏 cursor。
- [ ] 统一 cell width / line height 计算，避免 cursor 与文本错位。
- [ ] 支持 cursor style 配置：underline、block、bar。
- [ ] 支持远端 cursor visible 状态。

验收：

- 光标位置与 shell 输入位置一致。
- terminal focus 状态只通过 cursor 体现，不显示额外蓝色焦点框。

### 4. 选择、复制与鼠标交互

- [x] 定义 terminal selection model：anchor/head、grid row/col、跨 scrollback + 当前 screen。
- [x] 拖拽选择文本。
- [x] 选区高亮渲染。
- [x] 从 scrollback + 当前 screen 提取选中文本。
- [x] 双击选词。
- [x] 三击选行。
- [x] 有选区时按平台应用层复制快捷键复制选区。
- [x] 无选区时 `Control+C` / 普通 `Ctrl+C` 发送 interrupt 到远端。
- [x] 右键菜单：复制、粘贴、清屏、清 scrollback。
- [x] ESC 直接穿透发送给远端；remote 高亮由 terminal cell 样式渲染，不伪造本地蓝色选区。

验收：

- 复制内容保持终端行文本顺序。
- 选区跨行、空白和换行行为可预期。
- 复制不会误发送远端控制字符。

### 5. 快捷键与粘贴策略

- [x] 建立可查询 shortcut registry，供 Home/帮助界面展示所有快捷键。
- [x] macOS `Command+C`：有选区复制，没有选区不发送远端 interrupt。
- [x] macOS `Control+C`：发送 `0x03` 到远端。
- [x] macOS `Command+V`：从系统剪贴板粘贴文本到远端。
- [x] Windows/Linux `Ctrl+Shift+C` / `Ctrl+Insert`：复制选区，普通 `Ctrl+C` 发送 interrupt。
- [x] Windows/Linux `Ctrl+Shift+V` / `Shift+Insert`：粘贴到远端。
- [x] 大文本分块发送。
- [x] 支持 bracketed paste mode。
- [x] 大文本节流发送队列。

验收：

- macOS 常用 terminal 快捷键行为符合直觉。
- 普通命令和小段文本可稳定粘贴。
- 大段文本不会卡死 UI 或打爆 SSH channel。

### 6. Unicode、中文与 IME

- [x] 渲染 UTF-8 / Unicode codepoint，不再把非 ASCII 全部显示为空格。
- [x] 验证中文输入提交到 SSH PTY 的字节序列。
- [x] 处理 IME composition 状态。
- [x] 候选窗位置尽量贴近 cursor。
- [x] 宽字符渲染与 cursor 列位置基本一致。
- [x] 复制选区保留 UTF-8 codepoint。

验收：

- 可以在 shell 中输入中文。
- 中文和常见宽字符不破坏列对齐。
- Unicode 粘贴、复制、显示路径行为一致。

### 7. ANSI 样式渲染

- [x] 按 `terminal.Cell.style` 渲染 foreground/background。
- [x] 支持 default、indexed、rgb color。
- [x] 支持 bold、italic、underline、reverse、strike。
- [x] 合并同样式连续 ASCII cells 为 text run，避免逐 cell 低效绘制。
- [x] 处理宽字符和 UTF-8 codepoint。

验收：

- `ls --color`、prompt 颜色、常见 ANSI color demo 能正确显示。
- reverse video 选择或 TUI 状态栏不混乱。
- 中文和常见宽字符不破坏列对齐。

### 8. Alternate Screen

- [x] 识别和维护 alternate screen 状态。
- [x] `vim`、`top`、`less` 进入 alternate screen 时不污染普通 scrollback。
- [x] 退出 alternate screen 后恢复原 screen/scrollback。
- [x] 根据 alternate screen 状态调整滚轮行为。
- [x] 支持 TUI mouse reporting 初版：左键、拖动、滚轮。
- [x] 支持右键/中键和完整 mouse modifier 映射。

验收：

- 进入/退出 `vim` 后 shell 历史仍在。
- `top` 刷屏不把每一帧塞进普通 scrollback。

### 9. Terminal 搜索

- [x] 在 scrollback + 当前 screen 中搜索文本。
- [x] 高亮匹配结果。
- [x] 支持上一项/下一项。
- [x] 搜索时自动调整 viewport 到匹配位置。
- [x] `Command+F` / `Ctrl+F` 打开 terminal 搜索条，`Enter` / `Shift+Enter` 跳转。

验收：

- 长输出里可以快速定位文本。
- 搜索高亮不破坏 terminal 原始样式。

### 10. 字体与字号

Deferred：字号设置暂不实现。当前先保持固定 terminal font metrics，避免在搜索、状态、性能和回归基线完成前引入额外 resize/cell metrics 变量。

- [ ] `Cmd+Plus` / `Cmd+Minus` / `Cmd+0`：字号调整。Deferred。
- [ ] 字号变化后重新计算 cell metrics。Deferred。
- [ ] 字号变化后触发 PTY resize。Deferred。

验收：

- 字号调整后 terminal grid、cursor 和远端 rows/cols 保持一致。

### 11. Bell、title 与状态

- [ ] 支持 BEL 提示。
- [ ] 支持 OSC title 更新。
- [ ] 将远端 title 或 cwd 作为 tab/status panel 可选信息。
- [ ] 断线后保留最后 screen 和 scrollback。

验收：

- 远端设置 title 时 tab 能显示合理标题。
- 断线或重连不会立刻清空用户上下文。

### 12. 性能与内存

- [ ] 限制 scrollback 内存占用。
- [ ] dirty rows / dirty regions。
- [ ] 合并同样式 text runs。
- [ ] 避免每帧整屏逐字符重绘。
- [ ] 对高频输出保持 UI 可响应。

验收：

- 连续输出大日志时 UI 不明显卡顿。
- 长时间 session 不无限增长内存。

### 13. 回归测试基线

- [ ] 建立 terminal fixture。
- [x] 覆盖 ANSI colors。
- [x] 覆盖 resize。
- [x] 覆盖 scrollback。
- [ ] 覆盖 cursor。
- [x] 覆盖 alternate screen。
- [x] 覆盖 bracketed paste state。
- [x] 覆盖 SGR mouse reporting。
- [x] 覆盖 UTF-8 / 宽字符。
- [x] 更新 `docs/quality/terminal-regression-checklist.md`。

验收：

- 每次 terminal 改动有明确手工/自动检查项。
- 常见 terminal 能力不会在 UI 改动中反复回退。

## 建议优先级

第一阶段：把 terminal 变成真可用

1. PTY resize 同步。
2. Scrollback 上下滑动。
3. 选区复制。
4. 快捷键与粘贴。
5. Unicode、中文与 IME。

第二阶段：接近日常 terminal 体验

1. ANSI 样式渲染。
2. Alternate screen。
3. 搜索。
4. 字号调整。Deferred，暂不进入当前主线。

第三阶段：稳定性和长期体验

1. Bell / title / cwd 状态。
2. 断线保留上下文。
3. 性能优化。
4. terminal fixture 和回归基线。

## 开发注意事项

- DVUI widget 不解析 ANSI/VT escape sequence。
- Terminal rendering 不直接碰 SSH channel。
- SSH PTY resize 与 terminal emulator resize 必须使用同一组 cols/rows。
- Scrollback 属于 terminal runtime/emulator 状态，不属于 SSH server。
- Alternate screen 不应污染普通 scrollback。
- UI 选区、搜索、高亮属于 viewport 层，不应改写 emulator 原始 cell state。
