# Shellow

Shellow 是一个以 FinalShell 为参考方向的原生桌面远程工作台，技术路线为 `Zig + DVUI + SDL3 + SDL3_ttf`，当前聚焦 SSH 终端、SFTP 文件、多标签工作区和传输任务。

## Zig 版本

- `Zig 0.16.0+`

## 依赖

### Zig 库

- `dvui 0.5.0-dev`
- `sdl 0.4.2` / `SDL3 3.4.4`
  - 由 `dvui_sdl3` backend 依赖链引入
- `SDL3_ttf 3.2.2`
  - 随 Shellowo 的 DVUI fork 固定，用于 FreeType + HarfBuzz shaped text backend

### C 库

- `FreeType` / `HarfBuzz`
  - 通过 SDL3_ttf 字体系统提供 glyph rasterization、fallback 和 shaping
- `libssh2 1.11.1`
- `mbedTLS 3.6.6`
- `libvterm 0.3.3`

## Features

- 原生桌面工作台壳与多标签布局
- SSH 连接配置 CRUD
- Profile 本地持久化与可选 Master Password vault
- SSH connect / auth / host key verification / agent auth
- PTY shell channel、libvterm 终端渲染、scrollback、搜索和多 terminal slot
- 断线后保留最后 terminal screen / scrollback snapshot
- SFTP 远端目录浏览、基础文件操作、权限编辑和 details 面板
- 上传/下载任务、传输进度、速度、重试、取消和覆盖确认
- 远程文件编辑器、查找/替换、SDL3_ttf shaped text、CJK fallback 和 emoji/symbol 基础支持
- 主题、窗口布局和下载目录持久化

## 已完成

- Phase 0：原生工程基础
- Phase 1：工作台骨架
- SSH Terminal MVP 基础链路
- SFTP File MVP 基础链路
- 设置与主题系统基础

## TODO

- 发布级凭据策略；未启用 Master Password 时当前 profile secret 没有静态加密保护
- 传输中心体验打磨，例如历史持久化、批量控制和更细的占用说明
- 远程编辑器分块大文件编辑、通用编码转换和可视化 diff/merge
- 正式签名、公证、安装器与三平台运行回归
- 更多工作台体验打磨

## Quick Start

```bash
zig build
zig build test
zig build run
```

## Packaging

macOS 本地打包：

```bash
scripts/package-macos-app.sh 0.1.0
```

GitHub Actions 会在单个 macOS Job 中运行测试，并交叉编译 Windows、Linux 产物和构建 macOS `.app`。推送 `main` 会更新 `nightly` prerelease，推送 `v*` tag 会创建或更新正式 GitHub Release：Windows 发布单文件 `.exe`，Linux 发布单文件 ELF，macOS 发布解压后可直接运行的 `.app.zip`。发布前检查见 [Release Checklist](./docs/quality/release-checklist.md)。

## Docs

- [Agent Guide](./AGENTS.md)
- [Architecture](./docs/architecture.md)
- [Roadmap](./docs/roadmap.md)
- [Integration Inventory](./docs/integration-inventory.md)
- [Active Plans](./docs/plans/active/)
- [Decisions](./docs/decisions/)
- [Quality](./docs/quality/)

## Collaboration

- `AGENTS.md` 是仓库入口地图。
- 稳定架构事实放在 `docs/`。
- 跨层任务从 `docs/plans/active/` 开始。
- 功能草案放在 `.agents/extensions/`。
- Repo 内 agent workflows 放在 `.agents/skills/`。
