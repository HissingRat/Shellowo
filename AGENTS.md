# Shellow Agent Guide

本文件是智能体进入 Shellow 仓库时的入口地图，不是完整手册。稳定事实以 `docs/` 为准；功能草案和 agent 工作流放 `.agents/`。

## 1. 项目定位

Shellow 是一个以 FinalShell 为参考方向的原生桌面远程工作台。当前技术路线是 `Zig + DVUI + SDL3`，目标是把 SSH 终端、SFTP 文件、多标签工作区、传输任务和连接管理收束到一个轻量、可长期使用的桌面客户端里。

当前仓库已经具备原生工作台壳、连接配置 CRUD、非敏感 profile 持久化、真实 SSH runtime、SFTP 文件面板和基础传输任务。后续重点是 SSH/SFTP 可用性、安全凭据策略、传输中心体验和发布准备。

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
- Raw libssh2 handle 不得越过 `src/protocols/libssh2_backend.zig` 一类 backend 边界。
- 新功能先定义数据模型和边界，再写 DVUI 界面。
- 新依赖必须登记到 `docs/integration-inventory.md`。

## 4. 当前代码位置

- Zig 构建入口：`build.zig`
- Zig 依赖清单：`build.zig.zon`
- DVUI + SDL3 app 入口：`src/main.zig`
- 计划中的领域模型：`src/core/`
- 计划中的 app 状态与路由：`src/app/`
- 计划中的 protocol controllers：`src/protocols/`
- 计划中的 UI feature：`src/ui/`

## 5. 当前热点

- `src/main.zig` 现在只有最小 Hello World，后续不要把整个产品都堆在这里。
- `build.zig` 已接入 DVUI SDL3 backend；新增 C/native 依赖时先更新 `docs/integration-inventory.md`。
- `build.zig.zon` pin 了 DVUI commit/hash；升级 DVUI 时要重新验证窗口启动和基础控件。

## 6. 推荐扩展路径

1. 在 `docs/plans/active/` 或 `.agents/extensions/` 写清楚功能草案。
2. 明确影响层级：`core`、`storage`、`protocol controller`、`session runtime`、`transfer system`、`ui`。
3. 先补领域类型和状态转换。
4. 再实现 service/controller。
5. 最后接 DVUI 界面和交互。
6. 涉及终端、文件传输、凭据或发布时，同步补 `docs/quality/` 检查项。

## 7. 近期优先级

1. 完成 Phase 1 UI polish，尤其是表单 id、布局层级和工作台视觉密度。
2. 验证 libssh2 构建和链接策略。
3. 实现 SSH connect/auth/host-key verification。
4. 建立终端 widget 与 PTY resize 同步路径。
5. 接 SFTP list/upload/download，并进入 transfer queue。
6. 将当前 mock/fallback 路径替换为真实 session runtime。

## 8. 文档维护规则

- `AGENTS.md` 只放入口地图和硬约束，保持短小。
- 稳定架构事实放 `docs/architecture.md`。
- 阶段目标放 `docs/roadmap.md`。
- 跨文件或跨层任务放 `docs/plans/active/`，完成后移到 `docs/plans/completed/`。
- 已确认的架构选择放 `docs/decisions/`。
- 质量、测试、发布、安全检查放 `docs/quality/`。
- `.agents/` 只放协作草案和 skills，不放生产运行代码。

一句话结论：Shellow 要走 FinalShell 类产品路线，但技术上要保持原生 Zig/DVUI 的轻量边界，先把 `model / protocol / runtime / transfer / UI` 立住。
