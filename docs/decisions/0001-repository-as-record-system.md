# 0001 Repository As Record System

## 背景

Shellow 会长期由人和 AI 协作者共同推进。仅靠聊天记录或临时计划很容易丢失边界和阶段目标。

## 决定

把仓库本身作为记录系统：

- `AGENTS.md` 放入口地图和硬约束。
- `docs/architecture.md` 放稳定架构事实。
- `docs/roadmap.md` 放阶段路线。
- `docs/plans/active/` 放跨层任务计划。
- `docs/decisions/` 放已确认的架构选择。
- `docs/quality/` 放回归、发布和安全检查。
- `.agents/` 放协作草案和 agent skills。

## 影响

新功能开始前优先补计划；边界变化后同步更新文档。不要把所有项目知识继续堆进 `AGENTS.md`。
