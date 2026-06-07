# Shellow

Shellow is a native desktop remote workstation inspired by FinalShell.

The product direction is to bring SSH terminals, SFTP files, FTP files, workspace tabs, transfer tasks, connection profiles, and system information into one focused desktop client. The technical route is intentionally native: `Zig + DVUI + SDL3`.

## Status

Shellow is in Phase 1.

Current state:

- Zig 0.16 project
- DVUI dependency
- SDL3 backend
- Native workstation shell
- Connection profile CRUD
- Non-sensitive profile persistence in `data/profiles.json`
- Mock workspace tabs
- Transfer panel placeholder
- Stable Shellow SSH/SFTP API skeleton
- Architecture, roadmap, decision, quality, and agent-skill documents

Next focus:

1. Finish Phase 1 UI polish.
2. Validate libssh2 build/link strategy.
3. Implement SSH connect/auth/host-key verification.
4. Build the first terminal widget and PTY resize path.
5. Add SFTP list/upload/download through the transfer queue.

## Quick Start

```powershell
zig build
zig build test
zig build run
```

## Docs

- [Agent Guide](./AGENTS.md)
- [Architecture](./docs/architecture.md)
- [Roadmap](./docs/roadmap.md)
- [Integration Inventory](./docs/integration-inventory.md)
- [Active Plans](./docs/plans/active/)
- [Decisions](./docs/decisions/)
- [Quality](./docs/quality/)

## Collaboration

This repository uses the repo itself as the record system:

- `AGENTS.md` is the short entry map.
- Stable architecture facts live in `docs/`.
- Cross-layer work starts with `docs/plans/active/`.
- Draft feature ideas live in `.agents/extensions/`.
- Repo-local AI workflows live in `.agents/skills/`.
