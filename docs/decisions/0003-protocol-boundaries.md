# 0003 Protocol Boundaries

## 背景

SSH/SFTP 和 FTP 都涉及远程文件，但运行时语义不同。如果为了统一而做一个过大的 session 类型，后续会产生大量条件分支和空能力。

## 决定

SSH/SFTP 与 FTP 在 controller/protocol 层保持分离。

可以共享：

- profile 基础字段
- remote file entry 数据形状
- file operation 结果类型
- transfer task
- 错误展示模型

不能共享为一个大对象：

- session runtime
- protocol client
- terminal capability
- authentication flow

## 影响

SSH workspace 使用 `terminal_file` 布局，FTP workspace 使用 `file_only` 布局。后续新增协议时先判断它的工作流，而不是强塞进已有模型。
