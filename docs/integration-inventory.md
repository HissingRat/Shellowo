# Shellow Integration Inventory

本文归总 Shellow 已接入和计划评估的核心第三方项目、采用理由、实现位置和维护边界。精确版本以 `build.zig.zon` 为准。

## 1. GUI: DVUI

| 项目 | 当前用途 | 实现位置 | 维护结论 |
| --- | --- | --- | --- |
| `dvui` | 原生 UI、窗口 app lifecycle、widgets | `build.zig`, `src/main.zig` | Shellow 主界面走 DVUI，不用 Electron/WebView 替代主 UI。 |
| `dvui_sdl3` | SDL3 backend | `build.zig` | 通过 `b.dependency("dvui", .{ .backend = .sdl3 })` 导入。 |

当前 DVUI 使用 `HissingRat/dvui` fork 的固定 commit。fork 基于原 Shellowo
pin 的 DVUI commit，增加了可选 `TextEngine` 契约，使字体测量、绘制、
TextLayout 命中和 TextEntry cluster 边界可以由同一 shaped-text backend
提供。未安装 text engine 时仍保留 DVUI 原始字体路径。

维护原则：

- 新 UI 优先使用 DVUI widget 和布局能力。
- 不把业务逻辑堆进 widget 回调。
- DVUI 升级后至少验证 `zig build` 和窗口启动。

## 2. Window Backend: SDL3

当前 SDL3 由 DVUI 依赖链引入。

- `sdl_linux_deps` 也在根 `build.zig.zon` 显式登记，用于确保交叉编译
  Linux 时 SDL3 一定编入 X11 与 Wayland 视频驱动。桌面协议库仍由 SDL
  在运行时动态加载，同一个 Linux ELF 可用于两种会话。
- 未指定 ABI 的 Linux target（例如 `-Dtarget=x86_64-linux`）会在
  `build.zig` 中归一化为 GNU ABI。SDL 的 X11/Wayland backend 需要
  `dlopen` 桌面运行库，不能发布默认静态 libc 形态的 Linux ELF。

维护原则：

- 不绕过 DVUI 直接操作 SDL3 窗口，除非是 DVUI backend 无法覆盖的底层能力。
- 如果接入平台剪贴板、拖拽、文件对话框等系统能力，先判断 DVUI 是否已有抽象。
- Linux 发布产物必须同时保留 SDL3 的 X11 与 Wayland 驱动；不能只以
  “交叉编译成功”作为 GUI 可启动的证明。
- `src/platform/window_chrome.zig` 是自定义窗口标题栏的集中边界。macOS
  通过 `src/platform/macos_window_chrome.m` 调整 SDL 创建的原生
  `NSWindow`，保留系统交通灯和 fullscreen 行为；平台 handle 不进入产品 UI。

## 3. Text Shaping: SDL3_ttf / FreeType / HarfBuzz

当前实现：

- SDL3_ttf 3.2.2 源码随 Shellowo 的 DVUI fork 固定，构建时启用 HarfBuzz。
- SDL3_ttf 使用 DVUI 同一份 SDL3 3.4.4 renderer/backend。
- FreeType 使用 DVUI 已有的固定依赖，HarfBuzz 源码随 fork 固定。
- `src/backends/text/sdl_ttf.zig` 是 Shellowo-owned backend，负责
  `TTF_TextEngine`、字体、fallback、按需 `TTF_Text` layout 生命周期以及
  metrics/emoji texture cache。
- Zed Mono Extended 的 regular/bold/italic 是主字体，Noto Sans CJK SC
  通过 SDL3_ttf fallback chain 提供中文 glyph。
- macOS 通过 `src/backends/text/platform_fonts_macos.c` 使用 CoreText
  发现 Apple Color Emoji、Apple Symbols 和系统 cascade 字体；这些系统
  字体作为 SDL3_ttf fallback chain 的后续候选，用于 emoji、符号和更广
  Unicode 覆盖。
- Windows 通过 `src/backends/text/platform_fonts_windows.c` 保留同一
  Shellowo-owned 边界，优先发现 Segoe UI Emoji、Segoe UI Symbol、
  Microsoft YaHei、SimSun、Yu Gothic、Malgun、Nirmala 等常见系统字体，
  再从 Windows 字体注册表补齐实际安装的 emoji、symbol 和 cascade 候选。
- Linux 通过 `src/backends/text/platform_fonts_linux.c` 保留同一
  Shellowo-owned 边界，运行时动态加载 Fontconfig 发现 Noto Color Emoji、
  Noto Sans Symbols、Noto CJK 与常见 complex-script fallback；Fontconfig
  不可用时退回常见发行版字体路径。该路径不把 Fontconfig 作为构建期依赖。
- macOS 还通过 `src/backends/text/platform_emoji_macos.m` 提供
  AppKit-backed emoji bitmap overlay。普通文字的 geometry 仍来自
  SDL3_ttf；overlay 只在 render 阶段补 Apple Color Emoji 这类当前
  FreeType/SDL_ttf 构建无法直接 rasterize 的彩色 glyph。
- DVUI 的测量、绘制、鼠标命中、caret、selection 和 TextEntry
  cluster movement 使用同一个 text engine。
- terminal 继续由 libvterm cell grid 决定列宽、选择和 cursor；启用 shaped
  backend 时终端 glyph 按 cell 绘制，避免 ligature 改变占用列数。

维护原则：

- Raw `TTF_Font`、`TTF_Text` 和 `TTF_TextEngine` 只允许出现在
  `src/backends/text/`。
- 平台字体发现只能返回候选路径/元数据；UI 不直接调用 CoreText、
  DirectWrite 或 Fontconfig。
- emoji overlay 不得成为第二套测量/命中系统；如果未来引入通用 emoji
  atlas，必须显式接入 TextEngine 的 layout、caret、selection 和 hit
  testing。
- 不允许重新引入“绘制走 SDL3_ttf、测量走 DVUI”的双几何路径。
- 新增字体 fallback 时必须保持主字体和 fallback 的 size/style 一致。
- 更新 SDL3_ttf、FreeType、HarfBuzz 或 DVUI fork 后必须执行
  `zig build test` 和 `zig build`，并复测编辑器、IME、terminal cell 对齐。
- SDL3_ttf renderer text engine 是 window/renderer scoped；必须在 SDL
  renderer 销毁之前释放。

## 4. SSH / SFTP

当前实现：

- `libssh2` C 库绑定已作为 Shellow SSH/SFTP 后端。
- 当前 vendor 版本：`third_party/libssh2-1.11.1`。
- 当前 crypto backend：`third_party/mbedtls-3.6.6`。
- 当前 Zig build 已编译 `shellow_mbedcrypto` 与 `shellow_libssh2` 静态库，并通过 `libssh2_init/libssh2_exit` smoke test。
- `src/backends/ssh/libssh2.zig` 已具备第一版阻塞式 connect/auth/shell channel wrapper，并在认证前提取 host key SHA256 fingerprint 交给 Shellow verifier；known_hosts strict/TOFU 存储与 missing host key 确认路径已接入；password/private key/agent auth 已接入；SFTP list/stat/read/write/mkdir/remove/rename/chmod 与同目录 atomic replace 已接入。
- `zig build ssh-probe -- host port username password` 可通过 Shellow libssh2 backend 做真实 SSH connect/auth/open shell/write/read smoke test。
- Zig 原生 SSH/SFTP 库暂不作为主路线。
- 外部 `ssh` 进程桥接仅可作为诊断或临时验证手段，不进入正式运行时。

准入标准：

- 支持 PTY shell
- 支持 resize
- 支持 SFTP list/stat/read/write/upload/download/atomic replace
- 能在 Windows/macOS/Linux 构建或有清晰替代策略
- 错误状态可映射为用户可读提示

维护原则：

- SSH/SFTP controller 不依赖 DVUI。
- 终端字节流不在 UI 层改写。
- SFTP 传输必须进入 transfer queue。
- 生产代码只调用 Shellow 自有 SSH/SFTP API，不直接调用 `libssh2` C API。
- Raw libssh2 handle 只允许出现在 `src/backends/ssh/libssh2.zig` 或同级 backend/shim 文件中。
- App、runtime 和 UI 层只使用 `src/contracts/ssh.zig` 暴露的 Shellow API。

当前 Shellow API 落点：

| 文件 | 用途 |
| --- | --- |
| `src/contracts/ssh.zig` | 稳定 SSH/SFTP 抽象，定义 endpoint、auth、host key policy、shell、sftp、client、connector。 |
| `src/backends/ssh/libssh2.zig` | libssh2 backend，负责 C API、等待策略、错误映射和 raw handle 生命周期。 |
| `third_party/libssh2-1.11.1` | vendored libssh2 1.11.1 source。 |
| `third_party/mbedtls-3.6.6` | vendored mbedTLS 3.6.6 source for libssh2 crypto backend。 |

## 5. Terminal Emulator

当前实现：

- 自建 `libvterm` C 库 binding 已作为 Shellow terminal emulator 后端。
- 当前 vendor 版本：`third_party/libvterm-0.3.3`。
- 当前 Zig build 已编译 `shellow_libvterm` 静态库，并通过 `src/backends/terminal/libvterm_shim.c` 将 C bitfield/callback-facing cell 数据转换为 Shellow terminal snapshot。
- 不在 DVUI widget 中手写 ANSI/VT escape parser。
- 不把 terminal emulator API 直接暴露给 app/session/UI 层。

准入标准：

- 支持常见 VT/xterm 控制序列。
- 支持 grid、scrollback、cursor、style/color 状态输出。
- 支持输入编码、粘贴、选区、复制所需的数据边界。
- 支持与 SSH PTY cols/rows resize 同步。
- 可在 Windows/macOS/Linux 构建或有清晰 fallback。

维护原则：

- PTY channel 只负责字节流和 resize，不负责 terminal escape 解析。
- Terminal emulator backend 不依赖 DVUI。
- DVUI terminal widget 只渲染 Shellow terminal state，不直接调用 `libvterm`。
- Raw libvterm handle 只允许出现在 dedicated backend/shim 文件中。

当前 Shellow API 落点：

| 文件 | 用途 |
| --- | --- |
| `src/contracts/terminal_emulator.zig` | 稳定 terminal emulator 抽象，定义输入字节、grid snapshot、cursor、style、resize。 |
| `src/backends/terminal/libvterm.zig` | libvterm backend，负责 C API、状态转换和 raw handle 生命周期。 |
| `src/backends/terminal/libvterm_shim.c` | C shim，负责把 libvterm bitfield cell/color 数据转成 Zig 可直接消费的 plain struct。 |
| `third_party/libvterm-0.3.3` | vendored libvterm 0.3.3 source。 |

## 6. 本地存储

当前实现：

- profile 元数据使用本地文件。
- 用户选择持久化的敏感信息可以进入 profile 存储，但必须通过 profile repository/security 层处理，不在 UI、日志或普通业务对象里明文散落。
- `src/security/profile_vault.zig` 提供可选 Master Password profile vault：Argon2id KDF、XChaCha20-Poly1305 AEAD、随机 salt/nonce 写入 vault JSON；`src/runtime/profiles/profile_repository.zig` 负责兼容明文 profile array 与 encrypted vault。
- 未启用 Master Password 时，`src/security/secret_file.zig` 当前只做字节透传，profile array 中保存的密码/passphrase 没有静态加密保护；它是兼容边界，不是安全存储实现。
- settings、window/workspace layout 和 terminal prediction 配置使用 JSON/Zig 结构化序列化；最近连接尚未实现。

后续评估：

- SQLite
- 平台安全存储
- 无 Master Password 模式的发布级凭据策略

## 7. 新依赖准入规则

新增或替换第三方项目时，至少补齐：

1. 在 `build.zig.zon` 添加依赖。
2. 在本文件登记用途、实现位置、维护边界。
3. 如果涉及终端、文件传输、协议、安全或发布，补充 `docs/quality/` 下的回归清单。
4. 如果改变分层边界，同步更新 `docs/architecture.md` 或 `docs/decisions/`。
5. 跑 `zig build`。

## 8. 打包与发布

当前实现：

- `scripts/package-macos-app.sh` 在 macOS 原生环境构建 `Shellowo.app`，生成 `Info.plist`、`.icns` 图标并输出 zip。
- macOS 打包通过显式 Zig target 和 Xcode SDK include/framework/library 路径设置 deployment target；脚本会校验最终 Mach-O `minos` 与 `Info.plist` 目标一致。
- `zig build` 的主程序产物统一包含平台和架构，例如
  `Shellowo-macos-aarch64`、`Shellowo-windows-x86_64.exe` 和
  `Shellowo-linux-x86_64`。
- `.github/workflows/release.yml` 在单个 GitHub-hosted macOS runner 上执行原生测试，交叉编译 Windows/Linux，并原生构建 macOS `.app`。
- 推送 `main` 时通过 GitHub CLI 替换 `nightly` prerelease，推送 `v*` tag 时创建或更新正式 Release；Windows 上传 `.exe`，Linux 上传 ELF，macOS 上传用于保持 bundle 目录结构的 `.app.zip`。
- workflow 从 ziglang.org 官方下载索引安装仓库要求的 Zig 0.16.0 并校验 SHA-256；没有引入产品运行时依赖。

维护原则：

- Windows/Linux 交叉编译只证明目标产物可构建；正式发版前仍需在对应系统执行 GUI、SSH/SFTP 和文件系统回归。
- macOS ad-hoc 签名只用于基础包结构验证，正式公开发布需要 Developer ID 签名和 notarization。
- macOS app bundle 模式将工作目录和运行时数据放到 `~/Library/Application Support/Shellowo/`；Windows/Linux 继续保持现有便携式相对路径行为。
- 发布包不得包含用户 profile、vault、known_hosts、日志或本机生成的数据。
- 发布流程变更后按 `docs/quality/release-checklist.md` 回归。
