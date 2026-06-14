# Phase 1 Native Workbench

## 状态

Baseline completed. Polish continues in `docs/plans/active/phase1-polish.md`.

## 完成内容

- `src/main.zig` 已收缩为 DVUI app wiring。
- 新增 `src/app/App.zig` 管理长期 app state。
- 新增 core 模型：
  - `src/core/profile.zig`
  - `src/core/workspace.zig`
  - `src/core/transfer.zig`
  - `src/core/remote_file.zig`
- 新增 service 层：
  - `src/services/profile_repository.zig`
  - `src/services/session_registry.zig`
- 新增 DVUI 工作台：
  - `src/ui/screen.zig`
  - `src/ui/workspace_view.zig`
- 支持非敏感 profile JSON 持久化：
  - runtime path: `data/profiles.json`
  - ignored by git
- 支持 mock workspace tab 打开/关闭。
- 支持 SSH profile 创建、编辑、删除。
- 保留 transfer panel 占位。

## 非目标保留

- 尚未接真实 SSH。
- 尚未接真实 SFTP。
- 不保存密码、passphrase 或私钥内容。
- 不做发布打包。

## 验证

```powershell
zig build test
zig build
```

桌面程序已启动验证，窗口进入 Phase 1 工作台。
