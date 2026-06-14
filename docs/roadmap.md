# Shellow 路线图

## 总体策略

Shellow 的目标是做一个原生、轻量、可长期使用的 FinalShell 替代品。路线图优先形成可工作的桌面端 MVP，再逐步打磨为可发布版本。

## Phase 0: 原生工程基础

目标：建立不会返工的 Zig + DVUI 桌面基础。

交付：

- Zig 工程初始化
- DVUI + SDL3 窗口
- 基础 app shell
- 文档、计划、决策和 agent skills
- 基础构建命令

验收标准：

- `zig build` 通过
- `zig build run` 可启动桌面窗口
- 仓库有明确架构和路线文档

## Phase 1: 工作台骨架

目标：先做出像产品的桌面壳。

状态：已完成基础版本。

交付：

- 左侧连接列表占位
- 顶部标签栏
- 主工作区布局
- 传输任务面板占位
- 设置页基础框架
- 连接配置模型
- profile repository 雏形

验收标准：

- 可以创建、编辑、删除非敏感连接配置
- 可以打开空白工作区 tab
- 布局接近 FinalShell 类远程工作台形态

## Phase 2: SSH 终端 MVP

目标：跑通最核心的终端工作流。

交付：

- `libssh2` 后端构建与 Shellow SSH wrapper
- SSH connect/auth/host-key verification
- PTY shell channel
- `libvterm` binding 与 Shellow terminal emulator wrapper
- 终端渲染 widget / grid viewport
- 输入输出
- resize 同步
- 断开、重连、错误状态

验收标准：

- 能打开 SSH 标签页并正常执行命令
- 常见 TUI 程序尺寸正确
- 断开和错误状态可见

## Phase 3: SFTP 文件 MVP

目标：让 SSH 会话具备终端 + 文件联动。

交付：

- SFTP 目录浏览
- 文件/目录 stat
- 新建目录、重命名、删除
- 上传下载
- 远程文件读写雏形
- SSH 工作区 `terminal_file` 布局

验收标准：

- SSH 会话能浏览远端目录
- 能上传下载文件
- 传输状态进入统一 transfer system

## Phase 4: 传输中心与体验打磨

目标：从“能用”提升到“顺手”。

交付：

- 全局传输任务中心
- 任务进度、速度、状态、取消、重试
- 最近连接
- 错误提示优化
- 终端字体与主题设置
- 窗口与布局记忆
- 系统信息面板雏形

验收标准：

- 多任务传输稳定
- 常见错误能给出清晰提示
- 桌面体验接近日常使用

## Phase 5: 发布准备

目标：形成可分发的桌面版本。

交付：

- Windows 可执行包
- macOS app 包
- Linux 运行验证
- 崩溃日志和诊断信息
- 基础用户文档

验收标准：

- 双平台可以安装或直接运行
- 关键功能回归通过
- 文档足够支持首次体验

## 后续优先池

- SSH 隧道 / 端口转发
- 命令片段与收藏
- 双远端面板
- 本地文件面板
- 远程文件编辑器
- 系统信息与进程管理
- 密钥代理与平台钥匙串
- 配置导入导出
- 同步与备份

## 推荐开发顺序

1. 先拆 `src/main.zig`，立 app shell。
2. 先做布局和连接配置。
3. 用 `libssh2` 封装打通 SSH connect/auth/PTY shell。
4. 用 `libvterm` 封装打通 terminal emulator 和终端渲染。
5. 再接 SFTP 文件面板和 transfer queue。
6. 最后统一传输中心、设置和发布。

## 近期待办

1. 创建 `src/core`，定义 profile、session、tab、transfer 类型。
2. 创建 `src/app`，把窗口帧和工作区状态从 `main.zig` 拆出来。
3. 做连接管理的 DVUI 表单与列表。
4. 做 profile 文件存储，暂不保存敏感信息。
5. 验证 `libssh2` 构建、链接和 backend wrapper 策略。
6. 验证 `libvterm` binding、terminal state 和尺寸同步策略。
7. 为终端 widget 建立尺寸同步和回归清单。
