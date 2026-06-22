# Runtime Hardening Batch

## 当前状态

实现已完成，等待真实 SSH/SFTP 主机上的人工回归后移入 `completed/`。

## 背景

Shellowo 已具备传输任务、远程文件编辑器和可用 terminal，但三个区域仍停留在
MVP 边界：

- 传输 intent 会立即启动线程，缺少全局与单 SSH 会话并发上限。
- 远程编辑保存直接覆盖目标文件，缺少原子替换、编码识别和远端冲突检查。
- terminal 回归测试以分散单测为主，UI 的 cell/font metrics 仍有重复硬编码。

## 目标

1. 建立全局最多 10 个、单 SSH workspace 最多 4 个运行任务的传输调度队列。
2. 增强远程编辑器：
   - UTF-8 / UTF-8 BOM / ASCII 识别与非 UTF-8 提示。
   - 保留 BOM 与 CRLF/LF。
   - 打开时记录远端文件基线，保存前检查冲突。
   - 写入同目录临时文件后 rename 替换，失败时清理临时文件。
   - 大文件采用明确分级和只读/拒绝策略，不静默截断。
3. 建立数据化 terminal fixture，并统一渲染、PTY resize、鼠标命中、selection、
   cursor 与 IME 使用的 cell metrics。

## 非目标

- 本批次不做传输历史持久化。
- 本批次不做传输多选和批量控制 UI。
- 本批次不做断点续传或运行中暂停。
- 本批次不引入完整通用编码转换库；第一版可靠支持 UTF-8、UTF-8 BOM 和 ASCII。
- 本批次不做真正的分块大文件编辑器。

## 影响层级

- `src/core/transfer.zig`
- `src/runtime/transfers/`
- `src/runtime/sessions/`
- `src/contracts/ssh.zig`
- `src/backends/ssh/libssh2.zig`
- `src/core/remote_file.zig`
- `src/ui/workspace/file_panel_elements/remote_editor.zig`
- `src/ui/features/terminal/`
- `src/ui/workspace/terminal_panel.zig`
- `src/backends/terminal/libvterm.zig`
- `docs/quality/`

## 阶段

### Phase 1：传输调度

- [x] pending intent 不立即启动线程。
- [x] registry 统一分配全局 permit，workspace 再限制本地并发。
- [x] 全局 running `<= 10`，每个 workspace running `<= 4`。
- [x] pending / running / canceled 状态准确可见。
- [x] 取消 pending 任务不启动 worker。
- [x] 任务完成后立即调度下一个任务。

### Phase 2：远程编辑器安全

- [x] SFTP contract 增加 `stat` 与 atomic `replace`。
- [x] editor snapshot 保存 size / mtime / permissions / encoding / line ending / 内容 hash 基线。
- [x] 保存前重新 stat 并比较远端内容 hash；发现变化进入 conflict 状态，不直接覆盖。
- [x] 用户可以 reload 或 force overwrite。
- [x] 保存写同目录临时文件，再 atomic rename 到目标路径；保留权限。
- [x] UTF-8 BOM 与换行风格往返不丢失；无效 UTF-8 不进入可写编辑状态。
- [x] ASCII 文件加入 Unicode 后自动升级为 UTF-8，snapshot 编码状态与实际保存内容一致。
- [x] OpenSSH POSIX rename 优先原子覆盖，SFTP v3 无扩展时保留旧文件备份后兼容替换。

### File panel 回归修复

- [x] 传输队列非空时仍允许拖拽上传，新任务进入 scheduler。
- [x] 移除固定周期目录轮询，避免空闲 workspace 持续产生 SFTP 流量。
- [x] 进入已有缓存的目录时立即展示旧 snapshot，并在后台 revalidate。
- [x] 首次进入空目录或与上一目录内容相同的目录时仍建立独立缓存。
- [x] 工具栏和右键菜单提供手动刷新；刷新期间按钮禁用。
- [x] 后台刷新失败保留旧 snapshot，成功后直接发布新列表。

### Phase 3：Terminal fixture 与 metrics

- [x] 新增 fixture 数据与统一 runner。
- [x] 覆盖 ANSI、cursor、Unicode、alternate screen、scrollback、resize 和分段输入。
- [x] 新增 `TerminalMetrics`，集中计算 cell width、line height、baseline 和 cursor rect。
- [x] PTY size、绘制、鼠标定位、选区、IME 和 scrollbar 使用同一 metrics。

## 验收标准

- 同时创建超过 10 个跨连接任务时，全局运行数不超过 10。
- 单 workspace 同时创建超过 4 个任务时，运行数不超过 4。
- pending 任务可取消，运行任务完成后队列继续推进。
- 编辑保存中断不会截断原文件。
- 远端文件被其他进程修改后，Shellowo 不会静默覆盖。
- UTF-8 BOM 和 CRLF 文件保存后保持原格式。
- 非 UTF-8 文件显示明确只读/拒绝提示。
- terminal fixture 自动运行，metrics 相关单测覆盖 resize 与坐标换算。
- `zig build test` 和 `zig build` 通过。
