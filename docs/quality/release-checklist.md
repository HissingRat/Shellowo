# Release Checklist

Shellowo 的发布包由 `.github/workflows/release.yml` 在单个 macOS runner 上构建。Windows 和 Linux 使用 Zig 交叉编译，macOS 使用 runner 原生架构构建 `.app`。推送 `v*` tag 时，workflow 会创建或更新对应 GitHub Release。

## 自动检查

- macOS 原生目标执行 `zig build test -Doptimize=ReleaseSafe`。
- Windows x86_64 和 Linux x86_64 由 Zig 完成交叉编译；CI 不会实际启动这两个平台的 GUI。
- 发布构建使用 `zig build -Doptimize=ReleaseFast`。
- Windows 产物为带资源图标的单文件 `.exe`。
- Linux 产物为单文件 ELF executable。
- macOS 构建 artifact 保留带 `Info.plist` 和 `.icns` 图标的原始 `.app`；GitHub Release 因附件必须是文件，上传保持 bundle 结构的 `.app.zip`。
- macOS 未配置 `SIGNING_IDENTITY` 时使用 ad-hoc 签名；这不等同于 Developer ID 签名或 Apple notarization。

## 发版前人工检查

- 在 Windows 11、当前 Ubuntu LTS 和受支持 macOS 上启动应用。
- 创建 SSH profile，验证 host-key 确认、密码/私钥/agent auth。
- 打开 PTY，验证输入、resize、复制粘贴和常见 TUI。
- 验证 SFTP list、上传、下载、取消和覆盖确认。
- 确认发布包不包含 profile、vault、known_hosts、日志或其他本机数据。
- macOS 正式对外发布前配置 Developer ID Application 签名与 notarization。
- 检查 GitHub Release 中三个平台产物均存在且文件名包含正确 tag。

## 本地 macOS 打包

```bash
scripts/package-macos-app.sh 0.1.0
```

默认输出到 `dist/`。可通过 `MACOSX_DEPLOYMENT_TARGET`、`BUILD_VERSION` 和 `SIGNING_IDENTITY` 覆盖最低系统版本、bundle build version 和签名身份。
