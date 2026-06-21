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

状态：已完成 MVP，增强项继续由 terminal roadmaps 跟踪。

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

状态：已完成 MVP，高级冲突处理和远程编辑体验继续迭代。

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

状态：进行中。全局任务面板、进度/速度、取消、重试、覆盖确认、基础 busy/disabled 状态、主题/布局记忆和系统信息面板已实现。

交付：

- 全局传输任务中心
- 任务进度、速度、状态、取消、重试
- 最近连接
- 错误提示优化
- 终端字体与主题设置
- 窗口与布局记忆
- 系统信息面板雏形

剩余：

- 最近连接与连接使用历史
- 传输历史持久化、批量清理/控制和并发队列策略
- 更细的路径占用解释与复杂批量冲突策略
- 可配置 terminal 字体；主题设置已实现
- profile/editor/workspace 的 UI polish 与回归说明

验收标准：

- 多任务传输稳定
- 常见错误能给出清晰提示
- 桌面体验接近日常使用

## Phase 5: 发布准备

目标：形成可分发的桌面版本。

状态：已建立三平台 CI 构建、nightly/tag Release 和 macOS `.app` 基础打包；正式签名、公证、安装器及 Windows/Linux 原生运行回归仍待完成。

交付：

- Windows 可执行包
- macOS app 包
- Linux 运行验证
- 崩溃日志和诊断信息
- 基础用户文档

剩余：

- Windows/macOS 正式签名、macOS notarization 与安装器
- Windows 11、Ubuntu LTS 和受支持 macOS 的原生 GUI/SSH/SFTP 回归
- 崩溃日志、诊断信息与可交付诊断包策略
- 面向首次使用者的安装、凭据安全和常见故障文档

验收标准：

- Windows、macOS 和 Linux 可以安装或直接运行
- 关键功能回归通过
- 文档足够支持首次体验

## 后续优先池

- SSH 隧道 / 端口转发
- 命令片段与收藏
- 双远端面板
- 本地文件面板
- 远程文件编辑器高级能力
- 系统信息与进程管理交互
- SSH agent 管理与 agent forwarding
- 配置导入导出
- 同步与备份

## 已完成的基础开发顺序

1. 先拆 `src/main.zig`，立 app shell。
2. 先做布局和连接配置。
3. 用 `libssh2` 封装打通 SSH connect/auth/PTY shell。
4. 用 `libvterm` 封装打通 terminal emulator 和终端渲染。
5. 再接 SFTP 文件面板和 transfer queue。
6. 最后统一传输中心、设置和发布。

## 近期待办

1. 收敛 terminal cursor/cell metrics 和自动回归 fixture；dirty region、text run、60 FPS snapshot gate 与 scrollback 上限已实现。
2. 完善传输中心的历史、批量控制、队列策略和复杂冲突说明；重试、覆盖确认和基础 busy/disabled 已实现。
3. 打磨 selected connection 状态、profile editor 和 Phase 1 UI polish，并补 profile CRUD UI 回归。
4. 完善安全凭据策略和发布前安全检查。
5. 在现有自动打包基础上补 Windows/macOS 正式签名、notarization/安装器与三平台运行回归。
