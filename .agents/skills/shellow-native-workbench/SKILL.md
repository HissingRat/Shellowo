---
name: shellow-native-workbench
description: Guide Codex work on Shellow's native FinalShell-style remote workstation architecture. Use when implementing or planning profiles, sessions, SSH/SFTP/FTP controllers, workspace tabs, transfer tasks, storage, security boundaries, or cross-layer changes in the Zig + DVUI project.
---

# Shellow Native Workbench Skill

## Start Here

Read these before cross-layer work:

- `AGENTS.md`
- `docs/architecture.md`
- `docs/roadmap.md`
- `docs/integration-inventory.md`
- Relevant files in `docs/plans/active/`

Use this skill to keep Shellow on the native Zig + DVUI route while building a FinalShell-style remote workstation.

## Architecture Rules

- Keep UI, domain model, service/runtime, and protocol controller separate.
- Keep SSH/SFTP and FTP controller/runtime types separate.
- Share data shapes such as `RemoteFileEntry`, `TransferTask`, and user-facing error models.
- Do not put protocol clients inside DVUI widget code.
- Do not put file transfer through shell byte streams.
- Do not save secrets in ordinary profile files.

## Implementation Order

For a new feature:

1. Write or update a plan in `docs/plans/active/` when the work crosses layers.
2. Define or update core model types first.
3. Implement service/controller behavior without DVUI dependencies.
4. Add app state transitions.
5. Add DVUI screens/widgets last.
6. Update `docs/integration-inventory.md` for new dependencies.
7. Run `zig build`.

## Session Modeling

Use these conceptual boundaries:

- `SshSession`: shell channel plus optional SFTP capability.
- `FtpSession`: file-only protocol session.
- `WorkspaceTab`: UI/runtime handle that references a session and layout.
- `TransferTask`: global task independent of the widget that started it.

Avoid a single giant `RemoteSession` with optional terminal/file/auth fields.

## Storage Rules

- Profile metadata may be persisted early.
- Passwords, passphrases, tokens, and private key contents need a separate security design.
- Log host/user/status, not secrets.
- Prefer repository/service APIs over direct file reads from UI.

## Quality Checks

Always run:

```powershell
zig build
```

For terminal changes, also consult:

- `docs/quality/terminal-regression-checklist.md`

For credential or profile changes, consult:

- `docs/quality/security-notes.md`
