# Terminal Regression Checklist

终端相关改动必须复测这些场景。Shellow 已接入真实 SSH PTY 和 libvterm emulator；本清单用于保持日常 terminal 行为不回退。

## 自动回归基线

- `src/backends/terminal/fixture_tests.zig` 覆盖分段 ANSI、宽字符、cursor、alternate screen、bracketed paste、scrollback 与 resize。
- `src/ui/features/terminal/metrics.zig` 覆盖网格尺寸、鼠标命中和最小行列钳制。
- 改动 terminal parser、snapshot 或 cell metrics 后必须执行 `zig build test`。

## 基础

- 连接后显示 shell prompt。
- 输入普通命令能看到输出。
- 复制和粘贴不破坏换行。
- bracketed paste 模式下，粘贴不会被 shell 当作逐键输入处理。
- 大文本粘贴会分批发送，期间 UI 仍可响应，末尾内容不会丢失。
- 单个 chunk 内的小段粘贴在远端回显后立即可见，不需要再输入字符或移动 cursor 才刷新。
- 中文、Powerline 字符和宽字符不明显错位。
- IME composition 期间候选窗靠近 cursor，提交后只发送最终文本。

## Resize

- 窗口变宽、变窄后 prompt 和输入行不重叠。
- 后端 PTY cols/rows 与 UI 计算值一致。
- `vim` / `nano` 底部状态栏不被裁掉。
- readline 上下键历史记录不出现残影。

## 控制流

- 单行 `\r` 进度条能原地刷新。
- 多行进度输出不会被 UI 层改写。
- 清屏、光标移动、颜色控制序列正常。
- `ls --color`、prompt 颜色和 neofetch 色块能正常显示。
- 选区覆盖 terminal 背景色时保持可见且不盖乱文字。

## Alternate Screen 与 TUI

- 进入/退出 `vim` 后普通 shell scrollback 仍在。
- Vim Normal/Insert mode 使用 Shellow 统一的闪烁下划线 cursor，远端 hide/show 设置生效。
- `top` 或 `htop` 刷屏不会污染普通 scrollback。
- TUI 开启 mouse reporting 后，左键点击、拖动和滚轮能被远端程序收到。
- TUI 未开启 mouse reporting 时，鼠标拖动仍是本地选区。

## 高延迟预测

- Auto 模式在低延迟连接保持 Shell/Readline 保守等级，不因单次异常样本突然升到 TUI。
- 150–300ms 延迟下，Bash/Zsh 连续输入明显减少回显等待，不出现双字符。
- 连续快速输入时，远端部分回显只确认对应 pending prefix，后续未确认字符仍保留预测显示。
- Readline 行内编辑的 Left/Right、Home/End、Delete、Ctrl+A/B/E/F 不出现字符覆盖或光标越过 prompt。
- 开启 Tab prediction 后本地 tab stop 不残留；远端补全输出到达后能回到真实结果。
- 中文、常见 emoji 宽字符预测保持 cursor/cell width 一致；组合字符保持保守不预测。
- 大量远端输出触发 output gate 时状态栏显示 paused，输出平稳后自动恢复。
- Vim/Nano alternate screen 下预测冲突会快速 rollback，并在冲突频繁时自动降级或短暂停用。
- 密码、passphrase、OTP/token 提示、paste、selection、search 和 scrollback 浏览期间不进行本地预测。
- 切换多个 terminal slot 后，各 slot 的 latency、pending 和 rollback 状态互不串台。
- terminal bar 的 mode/level、Adaptive/Echo/Probe latency、output gate、pending、rollback 诊断值会随真实回显或独立 SSH probe 更新。

## 搜索与选区

- 选区复制不包含额外 UI 文本。
- 搜索不阻塞终端输入。
- 右键菜单不会吞掉终端焦点。

## 错误状态

- 连接断开有可读提示。
- 网络错误有可读提示。
- resize 失败不会导致 app 崩溃。
