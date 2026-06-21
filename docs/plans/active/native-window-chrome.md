# Native Window Chrome

## Status

Implementation is complete in the current codebase. The platform boundary,
macOS traffic-light integration, Windows caption controls, drag regions,
tab overflow scrolling and application close safety check are present.
This plan remains active only for native Windows/macOS/Linux manual runtime
verification before release.

## Goal

Give Shellowo a compact Zed-style application titlebar that can host workspace
tabs and future product controls without replacing the native Zig + DVUI + SDL3
stack.

## Platform strategy

- macOS keeps the native `NSWindow` traffic lights and fullscreen behavior.
  The titlebar is transparent and the SDL content view extends into it.
- Windows removes the system decoration and draws caption controls in DVUI.
  SDL3 remains responsible for move, resize, minimize, maximize and restore.
- Linux keeps server-side/system decoration in the first implementation. The
  common titlebar UI remains compatible with a later X11/Wayland client-side
  decoration implementation.

## Boundary

```text
DVUI app titlebar
  -> window chrome intents and drag rectangle
    -> src/platform/window_chrome.zig
      -> SDL3 common window operations
      -> Cocoa titlebar shim on macOS
```

Feature UI must not retain native platform handles. Native handles stay in the
platform layer.

## Acceptance

- macOS displays native traffic lights over the Shellowo titlebar.
- Windows displays Shellowo-drawn minimize, maximize/restore and close buttons.
- Empty titlebar space drags the window and Windows keeps edge resizing.
- Titlebar controls and workspace tabs remain interactive while every remaining
  topbar blank area can drag the window.
- Windows borderless chrome retains a native DWM shadow and draws a 1px inner border.
- Workspace tabs scroll horizontally when they exceed the available titlebar width.
- Activating a hidden workspace tab scrolls it back into view.
- Windows supports titlebar double-click maximize/restore and right-click system menu.
- Main-window close requests are routed through an application safety check.
- Running transfers, unsaved remote editors and active SSH sessions require an
  explicit quit confirmation.
- Existing workspace tabs and settings remain interactive.
- `zig build test` and `zig build` pass.
