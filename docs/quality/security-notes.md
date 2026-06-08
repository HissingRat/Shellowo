# Security Notes

Shellow 会处理远程服务器凭据和文件。安全能力必须单独设计，不随手塞进 UI 或 profile 文件。

## 当前规则

- profile 可以保存用户选择持久化的 secret，但必须通过 Shellow-owned profile repository/security 边界。
- 密码、私钥 passphrase、临时 token 不散落到 UI/app state 日志中，也不写入明文 JSON。
- 日志不打印密码、passphrase、私钥内容或完整连接 URI。
- 错误提示可以展示 host、port、username，但不展示 secret。

## 后续评估

- 平台钥匙串
- 加密本地文件
- 每次连接临时输入密码
- SSH agent
- 私钥文件权限检查

## 需要安全设计的功能

- 保存密码
- 保存 passphrase
- 导入/导出连接配置
- 自动重连
- 传输历史
- 日志与诊断包
