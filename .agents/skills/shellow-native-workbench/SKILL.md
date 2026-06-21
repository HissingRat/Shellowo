---
name: shellow-native-workbench
description: Guide Codex work on Shellow's native FinalShell-style remote workstation architecture. Use when implementing or planning profiles, sessions, SSH/SFTP controllers, workspace tabs, transfer tasks, storage, security boundaries, or cross-layer changes in the Zig + DVUI project.
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

- GUI: Zig + DVUI + SDL3.
- SSH/SFTP backend: `libssh2`, wrapped behind Shellow-owned Zig APIs.
- Terminal emulator backend: Shellow `libvterm` binding, wrapped behind Shellow-owned terminal APIs.
- Remote file workflows use SSH/SFTP.

Production code must call Shellow abstractions, not third-party APIs directly:

- Use `src/contracts/ssh.zig` for SSH/SFTP capabilities.
- Keep raw `libssh2` handles inside `src/backends/ssh/libssh2.zig` or a same-layer backend/shim file.
- Use `src/contracts/terminal_emulator.zig` for terminal emulation.
- Keep raw `libvterm` handles inside `src/backends/terminal/libvterm.zig` and its dedicated C shim.

## Architecture Rules

- Keep UI, domain model, service/runtime, and protocol controller separate.
- Share data shapes such as `RemoteFileEntry`, `TransferTask`, and user-facing error models.
- Hide all third-party library APIs behind Shellow-owned wrappers before production use.
- Do not put protocol clients inside DVUI widget code.
- Do not put file transfer through shell byte streams.
- Profile secrets may be saved only through Shellow-owned credential storage boundaries; do not scatter plaintext secrets outside the profile repository/security layer.

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

1. Release-grade credential strategy and security checks.
2. Transfer history, batch controls, queue policy, and conflict UX.
3. Terminal fixtures, cursor/cell metrics, and high-output regression.
4. Remote editor large-file, encoding, and remote-conflict behavior.
5. Signing, notarization/installers, and native three-platform release validation.

## Session Modeling

Use these conceptual boundaries:

- `SshSession`: shell channel plus optional SFTP capability.
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

- Profile metadata and user-approved secrets may be persisted, but secrets must pass through the security/profile repository boundary.
- Passwords, passphrases, tokens, and private key contents need an explicit storage strategy before release.
- Log host/user/status, not secrets.
- Prefer repository/service APIs over direct file reads from UI.

## Quality Checks

Always run:

```powershell
zig build
```

Do not run `git diff` or `git status` after every code edit as a fixed ritual. Use them only when they are needed for review, troubleshooting, handoff, commit prep, or when the user asks.

For terminal changes, also consult:

- `docs/quality/terminal-regression-checklist.md`

For credential or profile changes, consult:

- `docs/quality/security-notes.md`
