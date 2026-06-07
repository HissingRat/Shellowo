# Third Party Source

Vendored C libraries used by Shellow native backends.

## Libraries

- `libssh2-1.11.1`
  - SSH/SFTP backend candidate.
  - License: BSD-style, see `libssh2-1.11.1/COPYING`.
  - Production code must access it only through Shellow protocol wrappers.

- `mbedtls-3.6.6`
  - Crypto backend candidate for libssh2.
  - License: Apache-2.0 OR GPL-2.0-or-later, see `mbedtls-3.6.6/LICENSE`.
  - This vendor copy keeps build-relevant source/config files, not the full upstream test/program tree.

- `libvterm-0.3.3`
  - Terminal emulator backend candidate.
  - License: MIT, see `libvterm-0.3.3/LICENSE`.
  - Production code must access it only through Shellow terminal wrappers.

## Boundary Rule

Do not call third-party C APIs directly from app, service, session, or DVUI UI code.
Raw handles and C API calls belong in dedicated backend/shim files only.
