# FinalShell Parity Draft

## 背景

Shellow 参考 FinalShell 的产品路线：远程连接管理、SSH 终端、文件管理、传输任务、系统信息和多标签工作区集中在一个桌面客户端里。

## 核心工作流

- 用户创建 SSH profile。
- 用户打开 SSH tab。
- 主区显示终端，文件面板可以浏览同一主机的 SFTP。
- 用户上传、下载或编辑远程文件。
- 传输任务在全局中心可见。
- 用户可以打开多个 tab 并在连接之间切换。

## 第一版对齐能力

- SSH profile 管理
- SSH terminal
- SFTP file manager
- Transfer center
- Workspace tabs
- 终端字体与主题设置
- 基础系统信息面板

## 第一版不追的能力

- 商业版功能完整复刻
- 团队同步
- 云备份
- RDP/VNC
- 移动端
- AI 助手

## 产品差异

Shellow 应优先强调：

- 原生轻量
- 清晰的协议边界
- 可读、可维护的本地数据模型
- 不把终端、文件传输和系统信息揉成一个大模块

## 验收标准

- 用户能用 SSH tab 完成日常命令操作。
- 用户能通过同一连接浏览和传输文件。
- 所有传输任务都能在统一面板看到状态。
