---
name: shellow-dvui-ui
description: Guide Codex work on Shellow DVUI user interface implementation. Use when building or refactoring Zig DVUI screens, app shell, workspace layout, connection manager, tabs, file panels, transfer panels, themes, or desktop UI interactions.
---

# Shellow DVUI UI Skill

## Start Here

Use this skill for DVUI UI work in Shellow. Read:

- `AGENTS.md`
- `docs/architecture.md`
- `src/main.zig`

If the UI work crosses protocol, storage, or session boundaries, also use `.agents/skills/shellow-native-workbench/SKILL.md`.

## UI Direction

Shellow is a dense desktop remote workstation, not a marketing site. Prefer:

- compact panels
- predictable toolbars
- scannable tables/lists
- multi-pane workspace
- restrained visual styling
- keyboard-friendly interactions

Do not add decorative hero sections, oversized cards, or web landing-page composition.

## DVUI Structure

Keep `src/main.zig` small:

- DVUI app declaration
- app init/deinit wiring
- call into app shell frame

Move substantial UI into planned modules:

- `src/app/` for app state and frame orchestration
- `src/ui/` for screens/widgets
- `src/core/` for data models

## Layout Rules

For the first workstation shell:

- left rail: profiles/groups/recent connections
- top bar: workspace tabs and primary actions
- center: active workspace
- bottom or side: transfer queue

SSH tab layout:

- terminal region
- SFTP file panel
- visible connection status

FTP tab layout:

- file-only workspace
- no terminal placeholder

## Interaction Rules

- Buttons that trigger network/file work need a busy/disabled state.
- Errors should be user-readable and close to the action that caused them.
- Avoid storing long-lived state in widget-local variables when it belongs to app state.
- Prefer explicit state transitions over implicit UI flags.

## Styling Rules

- Keep a restrained desktop palette.
- Use theme/style options consistently.
- Avoid one-off colors scattered through widgets.
- Keep text inside compact controls short.
- Use stable dimensions for tab bars, toolbars, lists, and transfer rows.

## Validation

Always run:

```powershell
zig build
```

For visual changes, run:

```powershell
zig build run
```

Then inspect that the window opens, layout is nonblank, and text is not clipped.
