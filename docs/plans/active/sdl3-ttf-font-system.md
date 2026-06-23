# SDL3_ttf Font System

Implementation status: complete; awaiting user visual and functional
acceptance.

## Background

Shellowo currently uses DVUI's built-in font cache and codepoint renderer. Text
measurement, line wrapping, rendering, selection geometry, mouse hit testing,
caret placement, and editor cursor movement are all derived from that path.

Replacing only glyph drawing would create two geometry sources: SDL3_ttf would
shape the visible text while DVUI would continue measuring individual Unicode
codepoints. Ligatures, combining marks, fallback fonts, emoji sequences, and
bidirectional text would then produce incorrect selections and cursor
positions.

The new system therefore treats SDL3_ttf's shaped text as the single geometry
source for flow text and editable text. Terminal rendering remains a fixed cell
grid: libvterm owns terminal columns, while SDL3_ttf supplies font metrics and
glyph rendering constrained to those columns.

## Goals

- Use SDL3_ttf with FreeType and HarfBuzz for application text.
- Keep one shaped layout result for measurement, wrapping, rendering, hit
  testing, caret geometry, and selection geometry.
- Support explicit font fallback instead of switching an entire string to the
  CJK font when any non-ASCII byte is present.
- Preserve DVUI widgets and immediate-mode layout.
- Keep raw SDL3_ttf handles inside a Shellowo-owned backend.
- Preserve the terminal's libvterm cell geometry and PTY resize contract.
- Keep the DVUI changes isolated in `HissingRat/dvui`.

## Non-goals

- Replacing DVUI as the UI framework.
- Changing SSH, SFTP, transfer, storage, or session runtime behavior.
- Implementing a new terminal emulator.
- Packaging or signing the macOS application in this change.
- Completing visual acceptance without user review.

## Architecture

```text
DVUI Font / TextLayoutWidget / TextEntryWidget
                  |
                  v
          dvui.TextEngine contract
                  |
                  v
       Shellowo SDL3_ttf text backend
          |                    |
          v                    v
      TTF_Text layout      SDL_Renderer draw
          |
          +-- measure and wrap
          +-- point to UTF-8 byte boundary
          +-- UTF-8 range to selection rectangles
          +-- UTF-8 offset to caret rectangle
          +-- previous and next cluster boundary
```

The text backend is window-scoped because a renderer text engine is associated
with an SDL renderer. Font data and layout caches remain backend-owned.

## DVUI Fork Work

Baseline: the commit currently pinned by Shellowo,
`9707de2c7e9408b9326bb3c2c83ca0aa603fddca`.

Required changes:

1. Add a public `TextEngine` contract.
2. Allow a window to install an optional text engine.
3. Route `Font.textSizeEx()` through the installed engine.
4. Route deferred `renderText()` commands through the installed engine.
5. Route TextLayout point hit testing and caret/selection geometry through the
   same layout source.
6. Route TextEntry left/right movement and backspace/delete through shaped
   cluster boundaries.
7. Preserve the current renderer as the fallback when no engine is installed.
8. Add contract and fallback regression tests.

## Shellowo Backend Work

New boundary:

```text
src/backends/text/sdl_ttf.zig
```

Responsibilities:

- Initialize and quit SDL3_ttf.
- Create one renderer text engine per SDL/DVUI window.
- Open embedded fonts from memory.
- Build normal, bold, and italic face variants.
- Attach the CJK face as fallback.
- Create and release `TTF_Text` layouts on demand, while caching reusable font
  faces, simple metrics, font heights, and emoji textures.
- Expose measurement, drawing, hit testing, caret, selection, and cluster
  boundaries through `dvui.TextEngine`.
- Apply and restore the SDL renderer clip rectangle around direct text draws.
- Destroy text layouts, fonts, and engines before the SDL renderer is destroyed.

## Build and Dependency Work

- Add SDL3_ttf 3.2.2 source as a pinned third-party dependency in the DVUI fork.
- Build it statically against the same SDL3 used by DVUI.
- Build and link pinned FreeType and HarfBuzz dependencies.
- Disable optional SVG/color-font dependencies for the first integration.
- Update `docs/integration-inventory.md`.
- Pin Shellowo's DVUI dependency to the pushed `HissingRat/dvui` commit.

## UI Font Policy

The primary application family remains Zed Mono Extended. The first fallback is
Noto Sans CJK SC.

The old `needsCjkFont()` whole-string switch is removed from layout decisions.
Mixed strings are shaped as one logical string with fallback handled by the
font backend. Existing baseline helpers may remain temporarily only where the
terminal grid needs an explicit visual correction.

## Editable Text Policy

- External selection state continues to use UTF-8 byte offsets.
- Mouse hit testing returns a valid shaped cluster boundary.
- Left/right movement advances between shaped cluster boundaries.
- Backspace/Delete remove one shaped cluster.
- Selection rectangles come from the shaped layout.
- Wrapped-line vertical navigation uses shaped caret positions.
- Search remains byte-based, but scrolling to a match queries the actual text
  layout instead of independently estimating line breaks.

## Remote Editor Work

- Keep DVUI TextEntry storage and editing behavior.
- Replace `visualYOfOffset()`'s independent `Font.textSizeEx()` wrapping loop
  with a caret/layout query from the active text engine.
- Invalidate layout cache on text, width, font, scale, or wrap changes.
- Preserve the 64 MiB editor limit and current search/replace behavior.

## Terminal Grid Policy

The terminal is not flow text.

- libvterm cell width remains the source of columns and cursor positions.
- PTY resize, selection, mouse hit testing, and cursor rectangles continue to
  use `TerminalMetrics`.
- `TerminalMetrics` obtains glyph height and monospace advance from SDL3_ttf.
- Terminal text is shaped per style run, but each run is constrained to the
  cell span provided by libvterm.
- Ligatures must not alter the occupied terminal column count.
- Wide characters continue to occupy the width reported by libvterm.
- IME composition is drawn with the same font backend at the terminal cursor
  cell.

## Tests

Automated checks should cover:

- Text engine fallback when no custom engine is installed.
- Measurement and render dispatch through the same engine.
- UTF-8 byte boundaries for combining marks and multi-codepoint clusters.
- Point hit testing and caret geometry.
- Selection rectangles over shaped clusters.
- Mixed Latin/CJK fallback.
- Wrapped editor caret lookup.
- Terminal monospace metrics and unchanged grid hit testing.

The implementation includes DVUI dispatch/fallback coverage plus Shellowo
UTF-8 fallback-boundary tests. Geometry cases that require an active renderer
remain in the manual acceptance matrix below.

Manual user acceptance should cover:

- Latin ligatures such as `fi`.
- Combining marks.
- Chinese and Latin mixed text.
- Emoji and ZWJ sequences where supported by the configured fonts.
- Arabic/RTL geometry.
- Mouse selection, keyboard selection, cursor movement, and deletion.
- Remote editor wrapping and search navigation.
- Terminal ASCII, CJK, Powerline, IME, cursor, and selection alignment.

## Delivery Sequence

1. Fork DVUI and branch from the Shellowo-pinned commit.
2. Implement and test the text engine contract.
3. Push the DVUI branch.
4. Add SDL3_ttf, FreeType, and HarfBuzz to Shellowo.
5. Implement the Shellowo text backend and window lifecycle.
6. Replace whole-string font switching with fallback chains.
7. Align TextLayout/TextEntry and the remote editor.
8. Align terminal metrics and rendering without changing cell geometry.
9. Run `zig build test`.
10. Run `zig build`.
11. Push both repositories for user visual and functional acceptance.

## Completion Criteria

- Shellowo uses the `HissingRat/dvui` fork.
- SDL3_ttf is initialized and used for application text.
- Measurement and drawing share SDL3_ttf shaping.
- Editable text uses shaped hit testing and cluster boundaries.
- Remote editor search scrolling uses actual layout geometry.
- Terminal grid dimensions and cursor positioning remain stable.
- `zig build test` passes.
- `zig build` passes.
