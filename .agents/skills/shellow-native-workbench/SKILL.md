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

## Current Technical Stack

Prioritize SSH terminal work before FTP.

- GUI: Zig + DVUI + SDL3.
- SSH/SFTP backend: `libssh2`, wrapped behind Shellow-owned Zig APIs.
- Terminal emulator backend: Shellow `libvterm` binding, wrapped behind Shellow-owned terminal APIs.
- FTP backend: lower priority; start with a Shellow-owned minimal FTP client after SSH terminal and SFTP are stable.
- FTPS: defer until the plain FTP client and transfer system are stable.

Production code must call Shellow abstractions, not third-party APIs directly:

- Use `src/protocols/ssh.zig` or a same-layer Shellow facade for SSH/SFTP.
- Keep raw `libssh2` handles inside `src/protocols/libssh2_backend.zig` or a same-layer backend/shim file.
- Use `src/terminal/` or `src/protocols/terminal/` Shellow abstractions for terminal emulation.
- Keep raw `libvterm` handles inside a dedicated `libvterm_backend.zig`/shim file.
- Keep FTP runtime separate from SSH/SFTP runtime even if file operation data shapes are shared.

## Architecture Rules

- Keep UI, domain model, service/runtime, and protocol controller separate.
- Keep SSH/SFTP and FTP controller/runtime types separate.
- Share data shapes such as `RemoteFileEntry`, `TransferTask`, and user-facing error models.
- Hide all third-party library APIs behind Shellow-owned wrappers before production use.
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

Current priority order:

1. SSH connect/auth/host-key verification through `libssh2_backend`.
2. PTY shell channel, read/write, close, and resize synchronization.
3. Terminal emulator binding and terminal viewport/render state.
4. SFTP list/upload/download wired into transfer queue.
5. FTP file-only controller after SSH terminal and SFTP are usable.

## Session Modeling

Use these conceptual boundaries:

- `SshSession`: shell channel plus optional SFTP capability.
- `FtpSession`: file-only protocol session.
- `WorkspaceTab`: UI/runtime handle that references a session and layout.
- `TransferTask`: global task independent of the widget that started it.

Avoid a single giant `RemoteSession` with optional terminal/file/auth fields.

## Terminal Modeling

Use these boundaries:

- `TerminalEmulator`: accepts PTY bytes and produces grid/scrollback/cursor state.
- `TerminalViewport`: UI-owned presentation state such as selection, visible rows, and font metrics.
- `SshPtyChannel`: protocol-owned byte stream and resize endpoint.

Do not parse ANSI/VT escape sequences in DVUI widgets. Feed bytes into the terminal emulator wrapper, then render the resulting grid.

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
