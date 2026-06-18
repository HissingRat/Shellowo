# Status Panel Roadmap

## 状态

Completed. Snapshot、独立 SSH exec sampler、Linux 指标解析、降级状态和 DVUI 展示链路均已接入。

## 背景

Shellow 当前 workspace 左侧 `status_panel` 已经从静态 mock 升级为会话状态与远端监控摘要。当前基础链路已经跑通：UI 消费 snapshot，SSH workspace worker 通过独立 exec channel 执行嵌入式 shell 脚本，脚本返回规范化 JSON，Zig 侧解析后渲染系统摘要。

当前定位：

- `status_panel` 是 workspace 左侧栏。
- SSH workspace 中显示远端系统监控摘要。
- UI 只消费 snapshot，不直接执行 SSH/SFTP 操作。

## 目标

- 为 status panel 定义 runtime-independent snapshot。
- 替换现有硬编码 mock 文案。
- SSH 通过独立 exec channel 运行轻量 shell 脚本采样系统信息。
- 远端脚本返回规范化 JSON，Shellow 只解析结构化字段。
- 监控采样不占用用户当前 PTY shell，不污染 terminal scrollback。
- 采样失败时面板降级显示 `--` 或隐藏对应 section，不影响主 SSH terminal。
- 只显示 IP、Uptime、CPU、Memory、Swap、Network、top processes 和 disk 信息。

## 非目标

- 不把监控脚本通过用户当前 terminal PTY 发送。
- 不在 DVUI widget 中直接打开 SSH channel 或解析远端命令输出。
- 不暴露 raw libssh2 handle 到 UI 层。
- 不做进程管理操作，如 kill、renice、服务启停。
- 不追求跨所有 Unix 发行版的完整 system inventory。

## 边界

```txt
DVUI status_panel
  -> StatusPanelSnapshot
    -> App / Session Registry
      -> SshWorkspaceWorker
        -> SshMonitorSampler
          -> SSH exec channel
            -> remote shell script
```

职责：

- `status_panel`
  - 只负责 layout、颜色、紧凑表格、progress bar 和空态。
  - 不持有 runtime handle。
- `StatusPanelSnapshot`
  - 放 UI 可消费摘要：IP、uptime、资源、磁盘、网络、进程和错误。
  - 所有字段允许 unavailable。
- `SessionRegistry`
  - 根据 tab id 找到对应 SSH workspace monitor snapshot。
- `SshWorkspaceWorker`
  - 持有 SSH workspace runtime。
  - 暴露 monitor snapshot，不让 UI 接触 protocol object。
- `SshMonitorSampler`
  - 通过独立 exec channel 定期执行只读脚本。
  - 解析脚本输出成结构化 metrics。
  - 控制采样频率、超时和失败降级。

## 控件与数据

| 区块 | 信息 | 实现方法 | 显示方式 |
| --- | --- | --- | --- |
| IP | remote host or detected primary IP | profile host；后续可由 SSH exec script 读取 `hostname -I` 作为补充 | 双列 row |
| Uptime | remote uptime | SSH exec script 读取 `/proc/uptime` 或 `uptime -p` | 双列 row |
| CPU | cpu percent | SSH exec script 读取 `/proc/stat`，用两次样本做 delta | progress bar + 百分比 |
| Memory | memory used/total/percent、swap used/total/percent | SSH exec script 读取 `/proc/meminfo` | progress bars |
| Network | rx/tx rate | SSH exec script 读取 `/proc/net/dev`，用两次样本做 delta | 速率文本、network chart、hover 详情 |
| Processes | top N process cpu/mem/cmd | SSH exec script 使用 `ps`，限制行数 | compact table |
| Disk | mount path、free、size、used percent | SSH exec script 使用 `df -P`，限制行数 | compact table |

## SSH Monitor 采样方案

### Exec Channel

SSH monitor 使用同一个 SSH client 下的独立 exec channel，而不是用户 terminal 的 PTY shell channel。

原则：

- 每次采样打开短生命周期 exec channel，执行脚本后关闭。
- 采样间隔固定为 0.5 秒。
- 单次 exec 超时建议 1 秒左右，超时则保留上一帧数据并标记 stale。
- 所有脚本只读，不需要 sudo。

### 输出格式

脚本输出使用规范化 JSON，避免在 Zig 中解析自然语言或平台命令的本地化文本。JSON schema 由 Shellow 控制，远端脚本负责把不同平台的命令输出归一化到同一字段形状。

建议格式：

```json
{
  "schema": "shellow.status.v1",
  "platform": "linux",
  "sample_ms": 500,
  "ip": "10.246.32.203",
  "uptime_seconds": 864000,
  "cpu": {
    "percent": 8.2
  },
  "memory": {
    "used_bytes": 3543348019,
    "total_bytes": 16750372454,
    "percent": 21.2
  },
  "swap": {
    "used_bytes": 0,
    "total_bytes": 0,
    "percent": 0.0
  },
  "network": {
    "rx_bytes_per_sec": 742400,
    "tx_bytes_per_sec": 0
  },
  "disks": [
    {
      "path": "/",
      "free_bytes": 259845521408,
      "total_bytes": 300647710720,
      "percent": 13.6
    }
  ],
  "processes": [
    {
      "cpu_percent": 12.4,
      "memory_bytes": 134217728,
      "command": "sshd"
    },
    {
      "cpu_percent": 3.1,
      "memory_bytes": 67108864,
      "command": "bash"
    }
  ]
}
```

第一阶段先选择 Linux/procfs 路径跑通完整链路。后续支持 macOS 和 Windows 时，优先直接修改或替换远端采样脚本，让脚本继续输出同一 JSON schema；Shellow parser 和 UI snapshot 尽量不随平台变化。

## Snapshot 模型草案

```zig
pub const StatusPanelSnapshot = struct {
    monitor: MonitorSnapshot = .{},
};

pub const MonitorSnapshot = struct {
    state: MonitorState = .unavailable,
    last_sample_ms: ?i64 = null,
    ip: ?[]const u8 = null,
    uptime_seconds: ?u64 = null,
    cpu: ?PercentMetric = null,
    memory: ?CapacityMetric = null,
    swap: ?CapacityMetric = null,
    network: ?NetworkMetric = null,
    disks: []const DiskMetric = &.{},
    processes: []const ProcessMetric = &.{},
    error_summary: ?[]const u8 = null,
};
```

实际实现时可以先把 fixed-size buffer 放在 registry/worker 层，避免 UI 每帧分配过多临时内存。

## 阶段计划

### 1. Panel Snapshot 与现有信息接线

- [x] 定义 `StatusPanelSnapshot` 和基础 metric 类型。
- [x] registry 增加 `statusPanelSnapshot(tab_id)`。
- [x] `workspace_view` 将 snapshot 传给 `status_panel.show()`。
- [x] 面板第一版仅显示固定控件骨架：IP、Uptime、CPU、Memory、Swap、Network、top processes、Disk。
- [x] 没有 monitor 数据时显示 `--` 或空表格。

验收：

- 不再显示硬编码 IP、uptime、process、disk。
- 没有 monitor 数据时 UI 布局稳定。

### 2. SSH Monitor Sampler

- [x] 在 SSH workspace runtime 内新增 monitor sampler。
- [x] backend 支持独立 exec channel 只读命令。
- [x] 实现 Linux procfs/df/ps 轻量脚本，输出 `shellow.status.v1` JSON。
- [x] 解析脚本输出为 `MonitorSnapshot`。
- [x] 增加 0.5 秒采样间隔、单次 exec 超时和失败降级。
- [x] UI 显示 IP、uptime、cpu、memory、swap、network、top processes、disk。
- [x] Network chart 支持按 panel 宽度绘制、hover 点详情和 hover 时显示冻结。
- [x] App 空闲刷新有 4 FPS 下限，避免左侧 panel 因 DVUI 空闲策略不更新。

验收：

- 监控采样不会向 terminal 输出任何文本。
- 监控采样失败不影响 terminal 输入输出。
- 弱网络或远端缺命令时 status panel 降级显示。

## UI 规则

- 左侧栏保持紧凑，不做大卡片。
- 控件以双列 rows、progress bar、network chart、compact table 为主。
- 长 host/title/cmd 需要截断或稳定宽度，不能撑宽 panel。
- unavailable 值显示 `--`，整块长期 unavailable 时隐藏 section。

## 质量检查

- `zig build`
- `zig build run`
- 手工检查：
  - SSH connected 状态下 IP、Uptime、CPU、Memory、Swap、Network、top、Disk 区块稳定显示。
  - 关闭 tab 后没有访问释放 runtime。
  - resize 左侧栏时文字不重叠。
  - monitor unavailable 时布局仍稳定。
