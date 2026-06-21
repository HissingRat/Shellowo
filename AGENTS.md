# Shellow Agent Guide

本文件是智能体进入 Shellow 仓库时的入口地图，不是完整手册。稳定事实以 `docs/` 为准；功能草案和 agent 工作流放 `.agents/`。

## 1. 项目定位

Shellow 是一个以 FinalShell 为参考方向的原生桌面远程工作台。当前技术路线是 `Zig + DVUI + SDL3`，目标是把 SSH 终端、SFTP 文件、多标签工作区、传输任务和连接管理收束到一个轻量、可长期使用的桌面客户端里。

当前仓库已经具备原生工作台壳、连接配置 CRUD、可选 Master Password profile vault、真实 SSH/PTY runtime、libvterm 终端、SFTP 文件面板、远程编辑器、系统信息面板和统一传输任务。后续重点是凭据发布策略、传输中心长期体验、终端回归、编辑器高级能力和正式发布。

## 2. 先读哪里

- 架构地图：`docs/architecture.md`
- 路线图：`docs/roadmap.md`
- 第三方集成与准入：`docs/integration-inventory.md`
- 进行中计划：`docs/plans/active/`
- 架构决策：`docs/decisions/`
- 质量与回归：`docs/quality/`
- 功能草案：`.agents/extensions/`
- Agent skills：`.agents/skills/`

如果任务只改最小 UI，读本文件和 `.agents/skills/shellow-dvui-ui/SKILL.md` 即可。如果任务涉及协议、存储、会话或跨模块边界，必须先读 `docs/architecture.md` 和 `docs/plans/active/`。

## 3. 硬性边界

- UI 保持原生 DVUI 路线，不引入 Electron/WebView 作为主界面。
- 领域模型优先独立于 UI 和协议客户端，后续建议沉入 `src/core/`。
- Renderer/UI 层不直接拥有 SSH/SFTP 协议状态机；协议运行时必须经 service/controller 边界暴露。
- 远程文件能力走 SSH/SFTP 路线。
- 终端通道只传 PTY 字节流；文件传输走 transfer system，不把二进制传输塞进 shell。
- Transfer 进度统一进入 transfer system，不在各个 widget 里零散维护。
- Raw libssh2 handle 不得越过 `src/backends/ssh/libssh2.zig` 一类 backend 边界。
- 新功能先定义数据模型和边界，再写 DVUI 界面。
- 新依赖必须登记到 `docs/integration-inventory.md`。
- 维护的时候不要每轮对话都查git状态

## 4. 当前代码位置

- Zig 构建入口：`build.zig`
- Zig 依赖清单：`build.zig.zon`
- DVUI + SDL3 app 入口：`src/main.zig`
- 领域模型：`src/core/`
- app 状态与路由：`src/app/`
- Shellow-owned 能力契约：`src/contracts/`
- 第三方/native backend：`src/backends/`
- session、worker 和 repository runtime：`src/runtime/`
- UI feature：`src/ui/`
- Shellow UI design system：`src/ui/foundation/`、`src/ui/widgets/`、`src/ui/layouts/`
- 产品 feature UI：`src/ui/features/` 与逐步迁移中的 `src/ui/workspace/`

## 5. 当前热点

- `src/main.zig` 只负责装配和启动；产品状态、runtime 与 UI 已分别进入 `src/app/`、`src/runtime/` 和 `src/ui/`，继续保持这个边界。
- SSH/SFTP、libvterm 和平台窗口能力已经接入；升级 native 依赖时先更新 `docs/integration-inventory.md`，再做对应回归。
- `build.zig.zon` pin 了 DVUI commit/hash；升级 DVUI 时要重新验证窗口启动、终端输入、子窗口和基础控件。

## 6. 推荐扩展路径

1. 在 `docs/plans/active/` 或 `.agents/extensions/` 写清楚功能草案。
2. 明确影响层级：`core`、`storage`、`protocol controller`、`session runtime`、`transfer system`、`ui`。
3. 先补领域类型和状态转换。
4. 再实现 service/controller。
5. 最后接 DVUI 界面和交互。
6. 涉及终端、文件传输、凭据或发布时，同步补 `docs/quality/` 检查项。

## 7. 近期优先级

1. 收敛 Phase 1 UI polish、profile CRUD UI 回归和工作台视觉状态。
2. 完善发布级凭据策略，包括平台系统凭据库、临时凭据和私钥权限检查。
3. 完善传输中心的历史、批量控制、队列策略和占用说明。
4. 补 terminal fixture、cursor/cell metrics 与高输出量回归。
5. 完善远程编辑器的大文件、编码检测和远端冲突处理。
6. 完成 Windows/macOS 正式签名、notarization/安装器和三平台运行回归。

## 8. 文档维护规则

- `AGENTS.md` 只放入口地图和硬约束，保持短小。
- 稳定架构事实放 `docs/architecture.md`。
- 阶段目标放 `docs/roadmap.md`。
- 跨文件或跨层任务放 `docs/plans/active/`，完成后移到 `docs/plans/completed/`。
- 已确认的架构选择放 `docs/decisions/`。
- 质量、测试、发布、安全检查放 `docs/quality/`。
- `.agents/` 只放协作草案和 skills，不放生产运行代码。

一句话结论：Shellow 要走 FinalShell 类产品路线，但技术上要保持原生 Zig/DVUI 的轻量边界，先把 `model / protocol / runtime / transfer / UI` 立住。
