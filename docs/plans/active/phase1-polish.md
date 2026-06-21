# Phase 1 Polish

## 背景

Phase 1 baseline 已经具备工作台和 profile CRUD；后续又接入了真实 SSH workspace 与可选加密 profile vault，但本计划仍只跟踪工作台基础 UI polish。

## 当前已修复

- `textField()` helper 中所有 text entry 共用 `@src()` 造成 duplicate widget id 和状态串台。
- frame 中 body box 的生命周期覆盖 transfer bar，导致 transfer bar 挂进横向主体布局。
- 左侧栏、工作区、profile editor、transfer bar 增加基本 padding/margin 和稳定宽度。
- profile editor 已改为独立弹层、滚动表单和认证方式分区。
- home workspace 已具备产品化标题、新建连接入口、分组连接列表和搜索空态。

## 剩余目标

- 给 selected connection row 做更明确的视觉状态。
- 继续打磨 profile editor 的校验、错误提示和窄窗口排版。
- 增加 profile CRUD 的最小 UI 回归说明。

## 验收标准

- 所有文本框可独立编辑，不出现红色 duplicate id 边框。
- Transfer bar 固定在底部，不参与横向主体三栏布局。
- 连接列表、工作区、编辑器三栏留白稳定。
- `zig build test` 和 `zig build` 通过。
