# Phase 1 Polish

## 背景

Phase 1 baseline 已经具备工作台、profile CRUD、mock tabs 和非敏感持久化，但 UI 仍需要达到“可日常继续迭代”的基础质量。

## 当前已修复

- `textField()` helper 中所有 text entry 共用 `@src()` 造成 duplicate widget id 和状态串台。
- frame 中 body box 的生命周期覆盖 transfer bar，导致 transfer bar 挂进横向主体布局。
- 左侧栏、工作区、profile editor、transfer bar 增加基本 padding/margin 和稳定宽度。

## 剩余目标

- 继续打磨 profile editor 表单排版。
- 给 selected connection row 做更明确的视觉状态。
- 让 empty workspace 更像工作台空态而不是调试文案。
- 增加 profile CRUD 的最小 UI 回归说明。

## 验收标准

- 所有文本框可独立编辑，不出现红色 duplicate id 边框。
- Transfer bar 固定在底部，不参与横向主体三栏布局。
- 连接列表、工作区、编辑器三栏留白稳定。
- `zig build test` 和 `zig build` 通过。
