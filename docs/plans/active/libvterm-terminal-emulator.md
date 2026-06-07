# libvterm Terminal Emulator Plan

## 背景

Shellow 的 SSH terminal 需要可靠处理 VT/xterm 控制序列、颜色、光标、滚动区域和常见 TUI 程序。终端 escape parser 不应写在 DVUI widget 中，也不应和 SSH PTY channel 混在一起。

当前方向是自建 `libvterm` binding，并将其封装为 Shellow 自有 terminal emulator API。

## 目标

- 建立 Shellow 自己的 terminal emulator API。
- 将 raw `libvterm` handle 和 C callback 限制在 backend/shim 文件内。
- 支持 PTY 字节输入、grid snapshot、cursor、style/color、scrollback 和 resize。
- 让 DVUI terminal widget 只消费 Shellow terminal state。

## 非目标

- 不手写完整 ANSI/VT parser。
- 不让 DVUI widget 直接调用 `libvterm`。
- 不在 terminal emulator 中管理 SSH socket、认证或 channel 生命周期。
- 不在第一步完成所有高级终端功能，如 sixel、复杂 ligature、GPU 渲染。

## 当前落点

- `src/terminal/terminal.zig` 或同级 Shellow facade
  - 稳定 terminal emulator API。
  - 定义 input bytes、resize、grid/cell snapshot、cursor、style、selection 相关数据形状。
- `src/terminal/libvterm_backend.zig`
  - 未来唯一允许接触 raw libvterm handle 的位置。
  - 负责 C API、callbacks、生命周期和状态转换。
- `src/ui/workspace/terminal_panel.zig`
  - 只负责展示和交互，不解析 escape sequence。

## API 边界

```txt
DVUI terminal widget
  -> terminal viewport/state
    -> TerminalEmulator facade
      -> libvterm_backend
        -> libvterm C API

SSH PTY channel
  -> TerminalEmulator.write(bytes)
```

## 实施步骤

1. 验证 libvterm 构建策略
   - Windows: Zig 编译源码或 vendored C build。
   - macOS/Linux: system lib 或源码构建。
   - 记录是否需要额外 C flags。

2. 建立 C/Zig 绑定
   - 优先小型 C shim，减少 `@cImport` 泄漏。
   - 将 callbacks 转换为 Shellow terminal state 更新。

3. 建立 Shellow terminal API
   - init/deinit。
   - resize cols/rows。
   - write PTY bytes。
   - read grid/cursor/style snapshot。
   - 暂存 scrollback 接口。

4. 接 SSH PTY 数据流
   - SSH channel read -> terminal emulator。
   - UI cols/rows -> terminal resize -> SSH pty resize。
   - input key/paste -> SSH channel write。

5. 接 DVUI terminal widget
   - 使用 terminal snapshot 渲染 cells。
   - 光标、选区、复制、粘贴。
   - 字体度量驱动 cols/rows。

6. 回归检查
   - shell prompt。
   - vim/nano/top/htop 类 TUI。
   - ANSI colors。
   - resize 后布局正确。

## 验收标准

- `zig build` 通过。
- raw libvterm handle 不出现在 `src/app`、`src/ui`、`src/services`。
- SSH terminal 可以渲染常见 shell 输出和基础 TUI。
- PTY resize 与 terminal emulator cols/rows 一致。
- 终端回归清单更新并可执行。
