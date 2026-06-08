# Terminal Regression Checklist

终端相关改动必须复测这些场景。Shellow 已接入真实 SSH PTY 和 libvterm emulator；本清单用于保持日常 terminal 行为不回退。

## 基础

- 连接后显示 shell prompt。
- 输入普通命令能看到输出。
- 复制和粘贴不破坏换行。
- bracketed paste 模式下，粘贴不会被 shell 当作逐键输入处理。
- 大文本粘贴会分批发送，期间 UI 仍可响应，末尾内容不会丢失。
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
- `top` 或 `htop` 刷屏不会污染普通 scrollback。
- TUI 开启 mouse reporting 后，左键点击、拖动和滚轮能被远端程序收到。
- TUI 未开启 mouse reporting 时，鼠标拖动仍是本地选区。

## 搜索与选区

- 选区复制不包含额外 UI 文本。
- 搜索不阻塞终端输入。
- 右键菜单不会吞掉终端焦点。

## 错误状态

- 连接断开有可读提示。
- 网络错误有可读提示。
- resize 失败不会导致 app 崩溃。
