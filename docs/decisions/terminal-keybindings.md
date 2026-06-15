# Terminal Keybindings

## 背景

Shellow 的 terminal 需要同时满足两类输入：

- 应用层快捷键：复制、粘贴、标签页、搜索、重连等本地动作。
- 终端层快捷键：Readline、shell、tmux、screen、vim 等必须透传给远端 PTY。

如果应用层抢占过多按键，`Ctrl+C`、`Ctrl+B`、`Ctrl+A` 这类远端工作流会被破坏；如果全部透传，桌面 terminal 的复制粘贴体验又不可用。

## 决定

平台 Primary 键：

- Windows/Linux: `Ctrl`
- macOS: `Command`

终端焦点内的最高优先级原则：

- macOS: `Command+*` 归应用层，`Control+*` 默认透传给远端。
- Windows/Linux: 普通 `Ctrl+*` 默认透传给远端；应用层 terminal 快捷键优先使用 `Ctrl+Shift+*`，并保留 `Shift+Insert` / `Ctrl+Insert` 兼容键。
- 复制粘贴是第一批实现的应用层 terminal 快捷键。
- 所有快捷键定义必须进入代码中的 shortcut registry，供未来 Home 或帮助界面查询展示。

当前 terminal 内已实现：

| 动作 | macOS | Windows/Linux | 行为 |
| --- | --- | --- | --- |
| 复制选区 | `Command+C` | `Ctrl+Shift+C`, `Ctrl+Insert` | 有选区时复制选中文本；无选区不发送远端字节 |
| 粘贴 | `Command+V` | `Ctrl+Shift+V`, `Shift+Insert` | 将系统剪贴板文本写入 SSH PTY |
| 终止远端进程 | `Control+C` | `Ctrl+C` | 透传 `0x03` 给远端 |

规划中的应用层快捷键：

| 分类 | 动作 | macOS | Windows/Linux |
| --- | --- | --- | --- |
| 标签页 | 新建标签页 | `Command+T` | `Ctrl+T` |
| 标签页 | 关闭当前标签页 | `Command+W` | `Ctrl+W` |
| 标签页 | 恢复关闭的标签页 | `Command+Shift+T` | `Ctrl+Shift+T` |
| 标签页 | 下一个标签页 | `Command+Tab`, `Command+Right` | `Ctrl+Tab`, `Ctrl+Right` |
| 标签页 | 上一个标签页 | `Command+Shift+Tab`, `Command+Left` | `Ctrl+Shift+Tab`, `Ctrl+Left` |
| 标签页 | 切换到指定标签页 | `Command+1` - `Command+9` | `Ctrl+1` - `Ctrl+9` |
| 窗口 | 新建连接 | `Command+N` | `Ctrl+N` |
| 窗口 | 新建窗口 | `Command+Shift+N` | `Ctrl+Shift+N` |
| 窗口 | 退出程序 | `Command+Q` | `Ctrl+Q` |
| 窗口 | 强制退出程序 | `Command+Shift+Q` | `Ctrl+Shift+Q` |
| 窗口 | 全屏 | `Control+Command+F` | `F11` |
| 搜索与设置 | 搜索终端内容 | `Command+F` | `Ctrl+F` |
| 搜索与设置 | 打开设置 | `Command+,` | `Ctrl+,` |
| 搜索与设置 | 命令面板 | `Command+P` | `Ctrl+P` |
| 搜索与设置 | 全局搜索 | `Command+Shift+F` | `Ctrl+Shift+F` |
| 搜索与设置 | 调色板 | `Command+Shift+P` | `Ctrl+Shift+P` |
| 终端 | 重连会话 | `Command+Shift+R` | `Ctrl+Shift+R` |
| 终端 | 清空滚动缓冲区 | `Command+Shift+L` | `Ctrl+Shift+L` |
| 会话 | 保存会话 | `Command+S` | `Ctrl+S` |
| 会话 | 另存会话 | `Command+Shift+S` | `Ctrl+Shift+S` |
| 会话 | 打开会话 | `Command+O` | `Ctrl+O` |
| 文件传输 | 上传文件 | `Command+U` | `Ctrl+U` |
| 文件传输 | 上传目录 | `Command+Shift+U` | `Ctrl+Shift+U` |
| 文件传输 | 下载文件 | `Command+J` | `Ctrl+J` |

必须透传给远端的 terminal 输入：

- Readline / shell: `Ctrl+A/E/B/F/U/K/W/Y/L/R/C/D/Z/S/Q`
- Alt: `Alt+B/F/D/Backspace/.`
- 导航键：方向键、`Home`、`End`、`Insert`、`Delete`、`PageUp`、`PageDown`
- 功能键：`F1` - `F12`
- tmux prefix: `Ctrl+B *`
- GNU Screen prefix: `Ctrl+A *`
- Vim: `Esc`、`Ctrl+F/B/D/U/E/Y`

## 影响

Terminal widget 不直接硬编码平台快捷键；它只消费 shortcut registry 产出的动作。未来 Home 界面或帮助弹窗应直接枚举 registry 中的快捷键条目，而不是重新维护一份文本列表。

复制行为从 selection model 中提取 scrollback + 当前 screen 文本。Unicode、宽字符、bracketed paste 和大文本粘贴节流仍由 terminal enhancement roadmap 跟踪。
