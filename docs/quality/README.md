# Quality

这里放 Shellow 的质量、回归、安全和发布检查。

当前最低验证：

```powershell
zig build
zig build test
zig build run
```

涉及以下能力时必须补充或执行对应检查：

- 终端与 PTY resize
- 文件上传下载
- 连接配置与敏感信息
- 跨平台构建
- 发布包
