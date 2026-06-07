# 0002 Native Zig DVUI Route

## 背景

FinalShell 类客户端可以用 Electron/Web 技术较快成型，但 Shellow 当前已经采用 Zig + DVUI + SDL3。这个路线更轻量，也更适合做原生桌面体验，但需要更谨慎地选择协议、终端和存储方案。

## 决定

Shellow 主界面坚持原生 `Zig + DVUI + SDL3` 路线。

## 影响

- 不引入 Electron/WebView 作为主 UI。
- UI 设计以桌面工作台密集信息布局为主。
- 第三方依赖优先选择可被 Zig 构建系统稳定集成的库。
- 协议和终端能力需要单独验证，不默认照搬 Web 生态方案。
