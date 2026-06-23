# Unicode and Emoji Font System

Implementation status: first macOS pass implemented; the temporary Home visual
probe has been retired after acceptance.

## Goal

Shellowo should render emoji, symbols, CJK, combining marks, RTL text, and
common complex-script samples through the same SDL3_ttf shaped-text path used
for measurement, selection, hit testing, and caret geometry.

The first implementation path is system font fallback, not a custom emoji image
atlas. SDL3_ttf remains the single geometry source.

## Current Baseline

- Application text uses `src/backends/text/sdl_ttf.zig`.
- DVUI flow text and editable text query the installed `dvui.TextEngine`.
- The primary family is embedded Zed Mono Extended.
- Embedded Noto Sans CJK SC is the first fallback.
- Terminal rendering remains a libvterm cell-grid problem; emoji support must
  not alter terminal column ownership.

## Acceptance Surface

The first pass was accepted with a temporary Home `UNICODE / EMOJI PROBE`
section, then the probe was removed so Home stays product-facing.

Keep the sample set below for future ad hoc visual checks:

- basic emoji
- ZWJ emoji
- skin-tone modifiers
- flags
- text-vs-emoji variation selectors
- mixed Latin/CJK/Korean/Japanese text
- combining marks
- RTL samples
- Devanagari and Thai samples
- symbols, arrows, and box drawing

Run:

```sh
zig build run
```

When temporarily reintroducing a probe or adding a focused dev-only surface,
verify that text is not blank, emoji do not become tofu boxes where the platform
provides a font, and baseline/spacing remain reasonable.

## Platform Font Discovery

`src/backends/text/platform_fonts.zig` is the Shellowo-owned boundary for
platform font discovery.

macOS implementation:

- `src/backends/text/platform_fonts_macos.c`
- CoreText font descriptor matching for Apple Color Emoji and Apple Symbols
- CoreText default cascade list for broad Unicode coverage
- available-font URL fallback as a last resort
- `src/backends/text/platform_emoji_macos.m` renders emoji clusters into
  AppKit bitmap images when SDL3_ttf/FreeType cannot draw the color glyph.

Planned platform implementations:

- Windows: Segoe UI Emoji, Segoe UI Symbol, and eventually DirectWrite-backed
  fallback discovery.
- Linux: Fontconfig-backed discovery, prioritizing Noto Color Emoji, Noto Sans
  Symbols 2, and Noto CJK families.

## SDL3_ttf Fallback Chain

Each cached face in `src/backends/text/sdl_ttf.zig` should attach fallbacks in
this order:

1. embedded Noto Sans CJK SC when the primary face is not already CJK
2. platform emoji fonts
3. platform symbol fonts
4. platform cascade candidates

All fallback fonts must be opened at the same physical size and styled
consistently with the primary face.

## Current macOS Limitation

The first pass makes basic emoji, skin-tone samples, flags, variation selector
samples, CJK, RTL, Devanagari, Thai, and common symbols visible in the Home
probe.

Full ZWJ emoji sequences are not yet accepted as complete. Current SDL3_ttf
geometry remains intact, but the macOS offscreen system-rendering path used for
the bitmap overlay still fails to produce visible bitmaps for some full ZWJ
clusters in the Home probe. The temporary overlay scanner therefore avoids
using its result as an editing/layout authority.

Next choices:

1. keep investigating native macOS offscreen emoji rendering for ZWJ clusters;
2. enable FreeType PNG/SVG/color dependencies in the DVUI fork if practical;
3. introduce a real emoji asset/atlas layer that participates in TextEngine
   layout instead of merely drawing over text.

## Non-goal for the First Pass

Do not introduce an inline image emoji atlas unless SDL3_ttf plus platform
fallback fonts cannot provide acceptable emoji rendering.

An atlas fallback would need to participate in layout, caret, hit testing, and
selection geometry. Drawing images over already-laid-out text would reintroduce
a split geometry source and is not acceptable.

## Manual Acceptance Split

Codex checks:

- `zig build test`
- `zig build`
- `zig build run`
- focused Unicode/Emoji visual sanity when a temporary probe or editor sample is
  available

User checks:

- remote editor editing and selection
- TextEntry editing and cluster deletion
- broader visual acceptance across real workflows

## Future Work

- Add Windows and Linux platform font discovery.
- Add optional diagnostic logging for the concrete fallback paths discovered at
  runtime.
- If platform emoji fonts still render as tofu, revisit the DVUI fork's
  SDL3_ttf build options for color/SVG glyph support.
- Only after that, evaluate an inline emoji atlas with layout integration.
