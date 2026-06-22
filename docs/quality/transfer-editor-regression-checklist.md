# Transfer and Remote Editor Regression Checklist

## 传输调度

- 单个 SSH workspace 同时创建 5 个以上任务时，最多 4 个进入 running。
- 多个 workspace 合计创建 11 个以上任务时，全局最多 10 个进入 running。
- 队列已有 pending/running 任务时，仍可继续向 file panel 拖拽文件并进入 pending。
- pending 任务可取消，且不会短暂启动网络 worker。
- running 任务完成、失败或取消后，pending 队首继续调度。
- 关闭带 pending/running 任务的 tab 后，pending 立即 canceled；running 保留 permit，直到旧 worker 真正退出后再 canceled，其他连接随后继续调度。
- 重试失败任务后先进入 pending，再由 scheduler 分配 permit。

## 编辑器编码与大文件

- ASCII、UTF-8、UTF-8 BOM 文件可打开并显示正确编码提示。
- 编辑器可以显示并输入中文、日文、韩文及常见 Unicode 符号。
- ASCII 文件加入非 ASCII 字符后保存为 UTF-8，编码提示不再错误保留为 ASCII。
- UTF-8 BOM 保存后 BOM 仍存在。
- CRLF 文件在编辑器中正常显示，保存后保持 CRLF。
- 混合换行文件显示 Mixed line endings，不静默改写未编辑区域。
- 非 UTF-8 和包含 NUL 的二进制文件显示明确错误，不进入可写状态。
- 超过 8 MiB 的文件显示 Large file 提示；超过 64 MiB 的文件拒绝内置编辑。

## 冲突与安全保存

- 打开文件后由其他程序修改远端内容，保存时出现冲突提示。
- Reload 放弃本地草稿并加载远端新版本。
- Keep Editing 保留本地草稿；再次保存仍要求明确处理冲突。
- Overwrite 只在用户明确选择后覆盖远端新版本。
- 从未保存关闭提示选择 Save 后若发生冲突，选择 Overwrite 会在保存成功后继续关闭；Keep Editing 或 Reload 会取消关闭意图。
- 正常保存先写同目录 `.shellowo-*.tmp`，成功后原子替换目标。
- 临时写入或 rename 失败时，原文件内容保持不变并清理临时文件。
- 保存后尽量保持原文件权限。
- OpenSSH server 使用 `posix-rename@openssh.com` 原子覆盖；不支持该扩展的 SFTP v3 server 使用保留原文件备份的兼容替换。

## 目录缓存与手动刷新

- 首次打开没有 snapshot 的目录时显示 Loading。
- 进入已有缓存的目录时立即显示缓存，不切换到 Loading；后台读取完成后更新 snapshot。
- 首次进入空目录或内容恰好与上一个目录相同的目录时，仍会正确建立该路径的缓存。
- 空闲停留在目录时不执行固定周期 SFTP list。
- 工具栏刷新按钮位于 Active Tasks 前，刷新过程中禁用并变暗。
- 文件列表空白区域和文件条目的右键菜单都可以触发刷新。
- 后台刷新成功后文件列表直接更新，当前选中项不存在时自动清除。
- 后台刷新失败时保留原 snapshot，不把 file panel 切换成 Failed。
- Shellow 自身创建、删除、重命名、上传和编辑保存完成后主动刷新受影响目录。
- 在终端或其他进程修改当前目录后，通过手动刷新或重新进入该目录看到变化。
