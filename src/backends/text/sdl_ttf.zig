const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const platform_fonts = @import("platform_fonts.zig");

const c = dvui.backend.c;
const cjk_font_family = "Noto Sans CJK SC";
const max_cached_layouts = 2048;

pub const System = struct {
    allocator: std.mem.Allocator,
    renderer: *c.SDL_Renderer,
    engine: *c.TTF_TextEngine,
    font_sources: FontSources,
    system_fallbacks: platform_fonts.List = .{},
    fonts: std.AutoHashMapUnmanaged(u64, Face) = .empty,
    simple_metrics: std.AutoHashMapUnmanaged(u64, SimpleMetrics) = .empty,
    layouts: std.AutoHashMapUnmanaged(u64, *c.TTF_Text) = .empty,
    active_cached_layouts: usize = 0,
    clear_layouts_after_release: bool = false,
    emoji_textures: std.AutoHashMapUnmanaged(u64, EmojiTexture) = .empty,

    pub const FontSources = struct {
        regular: []const u8,
        bold: []const u8,
        italic: []const u8,
        cjk: []const u8,
    };

    const Face = struct {
        primary: *c.TTF_Font,
        fallbacks: std.ArrayListUnmanaged(*c.TTF_Font) = .empty,

        fn deinit(self: *Face, allocator: std.mem.Allocator) void {
            for (self.fallbacks.items) |fallback| c.TTF_CloseFont(fallback);
            self.fallbacks.deinit(allocator);
            c.TTF_CloseFont(self.primary);
            self.* = undefined;
        }
    };

    const Layout = struct {
        system: *System,
        text: *c.TTF_Text,
        cached: bool,

        fn release(self: Layout) void {
            if (self.cached) {
                self.system.releaseCachedLayout();
            } else {
                c.TTF_DestroyText(self.text);
            }
        }
    };

    const EmojiTexture = struct {
        texture: *c.SDL_Texture,
        width: f32,
        height: f32,

        fn deinit(self: EmojiTexture) void {
            c.SDL_DestroyTexture(self.texture);
        }
    };

    const SimpleMetrics = struct {
        advances: [128]c_int,
        height: c_int,
        ascent: c_int,

        fn advance(self: *const SimpleMetrics, byte: u8) c_int {
            if (byte == '\t') {
                const space = @max(1, self.advances[' ']);
                return space * 4;
            }
            return @max(0, self.advances[byte]);
        }
    };

    pub fn init(
        allocator: std.mem.Allocator,
        renderer: *c.SDL_Renderer,
        font_sources: FontSources,
    ) !System {
        if (!c.TTF_Init()) return error.SdlTtfInitFailed;
        errdefer c.TTF_Quit();

        const engine = c.TTF_CreateRendererTextEngine(renderer) orelse
            return error.SdlTtfTextEngineFailed;
        return .{
            .allocator = allocator,
            .renderer = renderer,
            .engine = engine,
            .font_sources = font_sources,
            .system_fallbacks = platform_fonts.discoverFallbacks(allocator) catch .{},
        };
    }

    pub fn deinit(self: *System) void {
        self.clearLayouts();
        self.layouts.deinit(self.allocator);
        var emoji_it = self.emoji_textures.valueIterator();
        while (emoji_it.next()) |texture| texture.deinit();
        self.emoji_textures.deinit(self.allocator);
        self.simple_metrics.deinit(self.allocator);
        var it = self.fonts.valueIterator();
        while (it.next()) |face| {
            face.deinit(self.allocator);
        }
        self.fonts.deinit(self.allocator);
        self.system_fallbacks.deinit(self.allocator);
        c.TTF_DestroyRendererTextEngine(self.engine);
        c.TTF_Quit();
        self.* = undefined;
    }

    pub fn dvuiEngine(self: *System) dvui.TextEngine {
        return .{ .context = self, .vtable = &vtable };
    }

    fn destroyFromTextEngine(context: *anyopaque) void {
        const self: *System = @ptrCast(@alignCast(context));
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }

    fn faceFor(self: *System, font: dvui.Font, scale: f32) ?Face {
        const physical_size = physicalFontSize(font, scale);
        const key = fontScaleKey(font, physical_size);
        if (self.fonts.get(key)) |face| return face;

        const family = font.familyName();
        const cjk_primary = std.mem.eql(u8, family, cjk_font_family);
        const primary_bytes = if (cjk_primary)
            self.font_sources.cjk
        else if (font.weight == .bold)
            self.font_sources.bold
        else if (font.style == .italic)
            self.font_sources.italic
        else
            self.font_sources.regular;

        const primary = openFont(primary_bytes, physical_size) orelse return null;
        errdefer c.TTF_CloseFont(primary);
        applyFontStyle(primary, font);

        var face: Face = .{ .primary = primary };
        errdefer face.deinit(self.allocator);

        if (!cjk_primary) {
            tryAddFallbackBytes(self.allocator, &face, self.font_sources.cjk, physical_size, font);
        }
        for (self.system_fallbacks.paths) |path| {
            tryAddFallbackPath(self.allocator, &face, path, physical_size, font);
        }

        self.fonts.put(self.allocator, key, face) catch {
            face.deinit(self.allocator);
            return null;
        };
        return face;
    }

    fn simpleMetricsFor(self: *System, font: dvui.Font, scale: f32) ?*SimpleMetrics {
        if (!isMonospaceFont(font)) return null;
        const physical_size = physicalFontSize(font, scale);
        const key = fontScaleKey(font, physical_size);
        if (self.simple_metrics.getPtr(key)) |metrics| return metrics;

        const face = self.faceFor(font, scale) orelse return null;
        var metrics: SimpleMetrics = .{
            .advances = [_]c_int{0} ** 128,
            .height = @max(1, c.TTF_GetFontHeight(face.primary)),
            .ascent = c.TTF_GetFontAscent(face.primary),
        };
        var byte: usize = 0;
        while (byte < metrics.advances.len) : (byte += 1) {
            const ch: u8 = @intCast(byte);
            if (ch == '\n' or ch == '\r') {
                metrics.advances[byte] = 0;
                continue;
            }
            var advance: c_int = 0;
            if (ch >= 0x20 and c.TTF_GetGlyphMetrics(face.primary, ch, null, null, null, null, &advance)) {
                metrics.advances[byte] = @max(0, advance);
                continue;
            }
            if (ch >= 0x20) {
                const one = [_]u8{ch};
                var width_px: c_int = 0;
                if (c.TTF_GetStringSize(face.primary, &one, one.len, &width_px, null)) {
                    metrics.advances[byte] = @max(0, width_px);
                }
            }
        }
        if (metrics.advances[' '] <= 0) metrics.advances[' '] = @max(1, @divTrunc(metrics.height, 2));
        if (metrics.advances['M'] <= 0) metrics.advances['M'] = metrics.advances[' '];

        self.simple_metrics.put(self.allocator, key, metrics) catch return null;
        return self.simple_metrics.getPtr(key);
    }

    fn layout(
        self: *System,
        font: dvui.Font,
        text: []const u8,
        scale: f32,
        wrap_width: ?f32,
    ) ?Layout {
        var hasher = std.hash.Wyhash.init(font.hash());
        hasher.update(std.mem.asBytes(&scale));
        const wrap_key = wrap_width orelse -1;
        hasher.update(std.mem.asBytes(&wrap_key));
        hasher.update(text);
        const key = hasher.final();
        const cacheable = text.len <= 256;
        if (cacheable) {
            if (self.layouts.get(key)) |cached| {
                return self.borrowCachedLayout(cached);
            }
        }

        const face = self.faceFor(font, scale) orelse return null;
        const result = c.TTF_CreateText(
            self.engine,
            face.primary,
            if (text.len == 0) null else text.ptr,
            text.len,
        ) orelse return null;
        if (wrap_width) |width| {
            const physical_width: c_int = @intFromFloat(@max(1, @ceil(width * safeScale(scale))));
            if (!c.TTF_SetTextWrapWidth(result, physical_width)) {
                c.TTF_DestroyText(result);
                return null;
            }
            _ = c.TTF_SetTextWrapWhitespaceVisible(result, true);
        }
        if (cacheable) {
            if (self.layouts.count() >= max_cached_layouts) {
                if (self.active_cached_layouts > 0) {
                    self.clear_layouts_after_release = true;
                    return .{ .system = self, .text = result, .cached = false };
                }
                self.clearLayouts();
            }
            self.layouts.put(self.allocator, key, result) catch
                return .{ .system = self, .text = result, .cached = false };
            return self.borrowCachedLayout(result);
        }
        return .{ .system = self, .text = result, .cached = false };
    }

    fn clearLayouts(self: *System) void {
        var it = self.layouts.valueIterator();
        while (it.next()) |text| c.TTF_DestroyText(text.*);
        self.layouts.clearRetainingCapacity();
        self.clear_layouts_after_release = false;
    }

    fn borrowCachedLayout(self: *System, text: *c.TTF_Text) Layout {
        self.active_cached_layouts += 1;
        return .{ .system = self, .text = text, .cached = true };
    }

    fn releaseCachedLayout(self: *System) void {
        std.debug.assert(self.active_cached_layouts > 0);
        self.active_cached_layouts -= 1;
        if (self.active_cached_layouts == 0 and self.clear_layouts_after_release) {
            self.clearLayouts();
        }
    }

    fn fontTextHeightPhysical(self: *System, font: dvui.Font, scale: f32) f32 {
        const shaped = self.layout(font, "M", scale, null) orelse
            return @max(1, font.size * safeScale(scale));
        defer shaped.release();

        var width_px: c_int = 0;
        var height_px: c_int = 0;
        if (c.TTF_GetTextSize(shaped.text, &width_px, &height_px)) {
            return @floatFromInt(@max(1, height_px));
        }
        return @max(1, font.size * safeScale(scale));
    }

    fn emojiBoxPhysical(self: *System, font: dvui.Font, scale: f32) f32 {
        const text_height = self.fontTextHeightPhysical(font, scale);
        const em = @max(1, font.size * safeScale(scale));
        return @max(1, @min(text_height * 0.82, em * 1.04));
    }

    fn measure(
        context: *anyopaque,
        font: dvui.Font,
        text: []const u8,
        options: dvui.Font.TextSizeOptions,
    ) dvui.Size {
        const self: *System = @ptrCast(@alignCast(context));
        const scale = currentScale();
        if (self.measureSimple(font, text, scale, options)) |fast| return fast;

        const line = firstLine(text);
        const shaped = self.layout(font, line.bytes, scale, null) orelse
            return .{ .w = font.size, .h = font.size };
        defer shaped.release();
        const layout_text = shaped.text;

        var width_px: c_int = 0;
        var height_px: c_int = 0;
        if (!c.TTF_GetTextSize(layout_text, &width_px, &height_px)) {
            return .{ .w = font.size, .h = font.size };
        }

        var end = line.bytes.len;
        const has_emoji = containsEmojiCluster(line.bytes);
        const emoji_box = self.emojiBoxPhysical(font, scale);
        if (options.max_width) |max_width| {
            const point_x: c_int = @intFromFloat(@max(0, @round(max_width * scale)));
            if (has_emoji) {
                end = compensatedEndForMaxWidth(
                    layout_text,
                    line.bytes,
                    @floatFromInt(point_x),
                    options.end_metric,
                    emoji_box,
                );
            } else {
                var substring: c.TTF_SubString = undefined;
                if (c.TTF_GetTextSubStringForPoint(layout_text, point_x, @divTrunc(height_px, 2), &substring)) {
                    end = boundaryForPoint(substring, point_x, options.end_metric);
                }
            }
        }
        if (options.max_width) |max_width| {
            const max_width_px = @max(0, max_width * scale);
            while (end > 0 and compensatedCaretXPhysical(layout_text, line.bytes, end, emoji_box) > max_width_px) {
                const previous = previousEmojiOrCodepoint(line.bytes, end);
                if (previous >= end) break;
                end = previous;
            }
        }
        if (line.has_newline and end == line.bytes.len) end += 1;
        if (options.end_idx) |out| out.* = @min(end, text.len);
        if (options.ascent_out) |out| {
            const face = self.faceFor(font, scale) orelse {
                out.* = font.size;
                return .{ .w = @as(f32, @floatFromInt(width_px)) / scale, .h = @as(f32, @floatFromInt(height_px)) / scale };
            };
            out.* = @as(f32, @floatFromInt(c.TTF_GetFontAscent(face.primary))) / scale;
        }

        const measured_width_px = if (end < line.bytes.len)
            compensatedCaretXPhysical(layout_text, line.bytes, end, emoji_box)
        else
            @as(f32, @floatFromInt(width_px)) + emojiCompensationBefore(layout_text, line.bytes, line.bytes.len, emoji_box);
        const measured_height_px = if (has_emoji)
            @max(self.fontTextHeightPhysical(font, scale), emoji_box)
        else
            @as(f32, @floatFromInt(height_px));
        return .{
            .w = @max(0, measured_width_px) / scale,
            .h = measured_height_px / scale,
        };
    }

    fn measureSimple(
        self: *System,
        font: dvui.Font,
        text: []const u8,
        scale: f32,
        options: dvui.Font.TextSizeOptions,
    ) ?dvui.Size {
        const line = simpleMeasureLine(text, options.max_width != null) orelse return null;
        if (self.simpleMetricsFor(font, scale)) |metrics| {
            return measureSimpleWithMetrics(line, metrics, scale, options);
        }

        const face = self.faceFor(font, scale) orelse return null;

        var width_px: c_int = 0;
        var end = line.bytes.len;
        if (options.max_width) |max_width| {
            const max_width_px: c_int = @intFromFloat(@max(0, @round(max_width * scale)));
            var measured_width: c_int = 0;
            var measured_length: usize = 0;
            if (line.bytes.len > 0) {
                if (!c.TTF_MeasureString(
                    face.primary,
                    line.bytes.ptr,
                    line.bytes.len,
                    max_width_px,
                    &measured_width,
                    &measured_length,
                )) return null;
            }
            end = @min(measured_length, line.bytes.len);
            width_px = measured_width;
            if (options.end_metric == .nearest and end < line.bytes.len) {
                const nearest = self.simpleNearestEnd(face.primary, line.bytes, end, max_width_px, measured_width);
                end = nearest.end;
                width_px = nearest.width_px;
            }
        } else {
            if (line.bytes.len > 0) {
                if (!c.TTF_GetStringSize(face.primary, line.bytes.ptr, line.bytes.len, &width_px, null)) return null;
            }
        }

        if (line.has_newline and end == line.bytes.len) end += 1;
        if (options.end_idx) |out| out.* = @min(end, text.len);
        if (options.ascent_out) |out| out.* = @as(f32, @floatFromInt(c.TTF_GetFontAscent(face.primary))) / scale;

        return .{
            .w = @max(0, @as(f32, @floatFromInt(width_px))) / scale,
            .h = @as(f32, @floatFromInt(@max(1, c.TTF_GetFontHeight(face.primary)))) / scale,
        };
    }

    fn simpleNearestEnd(
        self: *System,
        font: *c.TTF_Font,
        bytes: []const u8,
        before_end: usize,
        max_width_px: c_int,
        before_width_px: c_int,
    ) struct { end: usize, width_px: c_int } {
        _ = self;
        if (before_end >= bytes.len) return .{ .end = bytes.len, .width_px = before_width_px };
        const after_end = before_end + 1;
        var after_width_px: c_int = before_width_px;
        if (!c.TTF_GetStringSize(font, bytes.ptr, after_end, &after_width_px, null)) {
            return .{ .end = before_end, .width_px = before_width_px };
        }
        const before_dist = @abs(@as(f32, @floatFromInt(max_width_px - before_width_px)));
        const after_dist = @abs(@as(f32, @floatFromInt(after_width_px - max_width_px)));
        return if (after_dist < before_dist)
            .{ .end = after_end, .width_px = after_width_px }
        else
            .{ .end = before_end, .width_px = before_width_px };
    }

    fn render(context: *anyopaque, options: dvui.TextEngine.RenderOptions) anyerror!void {
        const self: *System = @ptrCast(@alignCast(context));
        if (options.rotation != 0) return error.UnsupportedTextRotation;

        const scale = safeScale(options.rs.s);
        const shaped = self.layout(options.font, options.text, scale, null) orelse
            return error.SdlTtfLayoutFailed;
        defer shaped.release();
        const text = shaped.text;

        _ = c.TTF_SetTextColor(text, options.color.r, options.color.g, options.color.b, options.color.a);
        const start = options.p orelse options.rs.r.topLeft();

        var text_w: c_int = 0;
        var text_h: c_int = 0;
        const have_size = c.TTF_GetTextSize(text, &text_w, &text_h);
        const default_h = if (have_size)
            @as(f32, @floatFromInt(@max(1, text_h)))
        else
            16 * scale;
        const emoji_box = self.emojiBoxPhysical(options.font, scale);
        const has_emoji = containsEmojiCluster(options.text);
        const use_emoji_overlay = has_emoji and emojiOverlayEnabled();
        const emoji_extra = if (use_emoji_overlay) emojiCompensationBefore(text, options.text, options.text.len, emoji_box) else 0;
        const render_height = if (use_emoji_overlay) @max(self.fontTextHeightPhysical(options.font, scale), emoji_box) else default_h;

        if (options.background_color) |background| {
            if (have_size) {
                (dvui.Rect.Physical{
                    .x = start.x,
                    .y = start.y,
                    .w = @max(1, @as(f32, @floatFromInt(text_w)) + emoji_extra),
                    .h = render_height,
                }).fill(.{}, .{ .color = background, .fade = 0 });
            }
        }

        const sel_start = @min(options.sel_start orelse 0, options.text.len);
        const sel_end = @min(options.sel_end orelse 0, options.text.len);
        if (sel_start < sel_end and use_emoji_overlay) {
            const selection_color = options.sel_color orelse dvui.themeGet().focus;
            const x0 = compensatedCaretXPhysical(text, options.text, sel_start, emoji_box);
            const x1 = compensatedCaretXPhysical(text, options.text, sel_end, emoji_box);
            (dvui.Rect.Physical{
                .x = start.x + @min(x0, x1),
                .y = start.y,
                .w = @max(1, @abs(x1 - x0)),
                .h = render_height,
            }).fill(.{}, .{ .color = selection_color, .fade = 0 });
        } else if (sel_start < sel_end) {
            var count: c_int = 0;
            const substrings = c.TTF_GetTextSubStringsForRange(
                text,
                @intCast(sel_start),
                @intCast(sel_end - sel_start),
                &count,
            );
            if (substrings != null) {
                defer c.SDL_free(@ptrCast(substrings));
                const selection_color = options.sel_color orelse dvui.themeGet().focus;
                var i: usize = 0;
                while (i < @as(usize, @intCast(count))) : (i += 1) {
                    const substring = substrings[i].*;
                    (dvui.Rect.Physical{
                        .x = start.x + @as(f32, @floatFromInt(substring.rect.x)),
                        .y = start.y + @as(f32, @floatFromInt(substring.rect.y)),
                        .w = @as(f32, @floatFromInt(substring.rect.w)),
                        .h = @as(f32, @floatFromInt(substring.rect.h)),
                    }).fill(.{}, .{ .color = selection_color, .fade = 0 });
                }
            }
        }

        const previous_clip_enabled = c.SDL_RenderClipEnabled(self.renderer);
        var previous_clip: c.SDL_Rect = undefined;
        if (!c.SDL_GetRenderClipRect(self.renderer, &previous_clip)) {
            return error.SdlRenderStateFailed;
        }
        const clip = dvui.clipGet();
        const next_clip: c.SDL_Rect = .{
            .x = @intFromFloat(@floor(clip.x)),
            .y = @intFromFloat(@floor(clip.y)),
            .w = @intFromFloat(@ceil(clip.w)),
            .h = @intFromFloat(@ceil(clip.h)),
        };
        if (!c.SDL_SetRenderClipRect(self.renderer, &next_clip)) {
            return error.SdlRenderStateFailed;
        }
        defer _ = c.SDL_SetRenderClipRect(self.renderer, if (previous_clip_enabled) &previous_clip else null);

        const align_cjk = containsCjkBaselineCodepoint(options.text) and !isCjkFont(options.font);
        if (use_emoji_overlay or align_cjk) {
            try self.renderVisualTextSegments(options.font, text, options.text, start, scale, options.color, emoji_box, use_emoji_overlay, align_cjk);
        } else if (!c.TTF_DrawRendererText(text, start.x, start.y)) return error.SdlTtfDrawFailed;
        if (use_emoji_overlay) self.renderEmojiOverlays(text, options.text, start, emoji_box, render_height);
    }

    fn caretX(
        context: *anyopaque,
        font: dvui.Font,
        text: []const u8,
        byte_offset: usize,
    ) f32 {
        const self: *System = @ptrCast(@alignCast(context));
        const scale = currentScale();
        if (self.simpleCaretX(font, text, byte_offset, scale)) |fast| return fast;

        const shaped = self.layout(font, text, scale, null) orelse return 0;
        defer shaped.release();
        const layout_text = shaped.text;
        return compensatedCaretXPhysical(layout_text, text, byte_offset, self.emojiBoxPhysical(font, scale)) / scale;
    }

    fn caretPoint(
        context: *anyopaque,
        font: dvui.Font,
        text: []const u8,
        byte_offset: usize,
        wrap_width: ?f32,
    ) dvui.Point {
        const self: *System = @ptrCast(@alignCast(context));
        const scale = currentScale();
        if (self.simpleCaretPoint(font, text, byte_offset, scale, wrap_width)) |fast| return fast;

        const shaped = self.layout(font, text, scale, wrap_width) orelse return .{};
        defer shaped.release();
        const layout_text = shaped.text;

        var substring: c.TTF_SubString = undefined;
        if (!c.TTF_GetTextSubString(layout_text, @intCast(byte_offset), &substring)) {
            return .{
                .x = compensatedCaretXPhysical(layout_text, text, byte_offset, self.emojiBoxPhysical(font, scale)) / scale,
                .y = 0,
            };
        }
        const emoji_box = self.emojiBoxPhysical(font, scale);
        const rtl = (substring.flags & c.TTF_SUBSTRING_DIRECTION_MASK) == c.TTF_DIRECTION_RTL;
        const at_start = byte_offset <= @as(usize, @intCast(@max(0, substring.offset)));
        const x_px: f32 = @floatFromInt(if (at_start)
            (if (rtl) substring.rect.x + substring.rect.w else substring.rect.x)
        else
            (if (rtl) substring.rect.x else substring.rect.x + substring.rect.w));
        return .{
            .x = (x_px + emojiCompensationBefore(layout_text, text, byte_offset, emoji_box)) / scale,
            .y = @as(f32, @floatFromInt(substring.rect.y)) / scale,
        };
    }

    fn simpleCaretX(
        self: *System,
        font: dvui.Font,
        text: []const u8,
        byte_offset: usize,
        scale: f32,
    ) ?f32 {
        const offset = @min(byte_offset, text.len);
        if (!isSimpleAscii(text[0..offset])) return null;
        if (self.simpleMetricsFor(font, scale)) |metrics| {
            return @as(f32, @floatFromInt(simpleMetricsWidth(metrics, text[0..offset]))) / scale;
        }
        const face = self.faceFor(font, scale) orelse return null;
        return @as(f32, @floatFromInt(simpleStringWidth(face.primary, text[0..offset]) orelse return null)) / scale;
    }

    fn simpleCaretPoint(
        self: *System,
        font: dvui.Font,
        text: []const u8,
        byte_offset: usize,
        scale: f32,
        wrap_width: ?f32,
    ) ?dvui.Point {
        const offset = @min(byte_offset, text.len);
        const prefix = text[0..offset];
        if (!isSimpleAscii(prefix)) return null;
        if (self.simpleMetricsFor(font, scale)) |metrics| {
            return simpleCaretPointWithMetrics(prefix, metrics, scale, wrap_width);
        }
        const face = self.faceFor(font, scale) orelse return null;
        const line_h = @as(f32, @floatFromInt(@max(1, c.TTF_GetFontHeight(face.primary))));

        const wrap_px: ?c_int = if (wrap_width) |width|
            @intFromFloat(@max(1, @round(width * scale)))
        else
            null;

        var y_px: f32 = 0;
        var line_start: usize = 0;
        var pos: usize = 0;
        while (pos < prefix.len) {
            if (prefix[pos] == '\n') {
                line_start = pos + 1;
                y_px += line_h;
                pos += 1;
                continue;
            }

            const next_newline = std.mem.indexOfScalarPos(u8, prefix, pos, '\n') orelse prefix.len;
            if (wrap_px) |limit| {
                while (pos < next_newline) {
                    const remaining = prefix[pos..next_newline];
                    var measured_width: c_int = 0;
                    var measured_length: usize = 0;
                    if (!c.TTF_MeasureString(
                        face.primary,
                        remaining.ptr,
                        remaining.len,
                        limit,
                        &measured_width,
                        &measured_length,
                    )) return null;
                    const step = @max(@as(usize, 1), @min(measured_length, remaining.len));
                    if (pos + step >= prefix.len) {
                        return .{
                            .x = @as(f32, @floatFromInt(simpleStringWidth(face.primary, prefix[pos..prefix.len]) orelse measured_width)) / scale,
                            .y = y_px / scale,
                        };
                    }
                    pos += step;
                    line_start = pos;
                    if (pos < next_newline) y_px += line_h;
                }
            } else {
                pos = next_newline;
            }
        }

        return .{
            .x = @as(f32, @floatFromInt(simpleStringWidth(face.primary, prefix[line_start..prefix.len]) orelse 0)) / scale,
            .y = y_px / scale,
        };
    }

    fn previousBoundary(
        context: *anyopaque,
        font: dvui.Font,
        text: []const u8,
        byte_offset: usize,
    ) usize {
        if (byte_offset == 0 or text.len == 0) return 0;
        const self: *System = @ptrCast(@alignCast(context));
        const shaped = self.layout(font, text, currentScale(), null) orelse
            return previousCodepoint(text, byte_offset);
        defer shaped.release();
        const layout_text = shaped.text;

        var substring: c.TTF_SubString = undefined;
        if (!c.TTF_GetTextSubString(layout_text, @intCast(byte_offset - 1), &substring)) {
            return previousCodepoint(text, byte_offset);
        }
        return @intCast(@max(0, substring.offset));
    }

    fn nextBoundary(
        context: *anyopaque,
        font: dvui.Font,
        text: []const u8,
        byte_offset: usize,
    ) usize {
        if (byte_offset >= text.len) return text.len;
        const self: *System = @ptrCast(@alignCast(context));
        const shaped = self.layout(font, text, currentScale(), null) orelse
            return nextCodepoint(text, byte_offset);
        defer shaped.release();
        const layout_text = shaped.text;

        var substring: c.TTF_SubString = undefined;
        if (!c.TTF_GetTextSubString(layout_text, @intCast(byte_offset), &substring)) {
            return nextCodepoint(text, byte_offset);
        }
        return @min(text.len, @as(usize, @intCast(@max(0, substring.offset + substring.length))));
    }

    fn renderVisualTextSegments(
        self: *System,
        font: dvui.Font,
        original_text: *c.TTF_Text,
        bytes: []const u8,
        start: dvui.Point.Physical,
        scale: f32,
        color: dvui.Color,
        emoji_advance: f32,
        skip_emoji_clusters: bool,
        align_cjk: bool,
    ) !void {
        const cjk_offset_y = if (align_cjk) self.cjkBaselineOffsetPhysical(font, scale) else 0;

        var emoji_index: usize = 0;
        var next_emoji: ?ByteRange = if (skip_emoji_clusters) nextEmojiCluster(bytes, &emoji_index) else null;
        var pos: usize = 0;
        while (pos < bytes.len) {
            while (next_emoji) |cluster| {
                if (cluster.end > pos) break;
                next_emoji = nextEmojiCluster(bytes, &emoji_index);
            }

            if (next_emoji) |cluster| {
                if (pos >= cluster.start and pos < cluster.end) {
                    pos = cluster.end;
                    continue;
                }
            }

            var codepoint_index = pos;
            const first = nextCodepointValue(bytes, &codepoint_index) orelse {
                pos += 1;
                continue;
            };
            const cjk_run = align_cjk and isCjkBaselineCodepoint(first);
            const segment_start = pos;
            pos = codepoint_index;

            while (pos < bytes.len) {
                if (next_emoji) |cluster| {
                    if (pos >= cluster.start) break;
                }

                var next_index = pos;
                const codepoint = nextCodepointValue(bytes, &next_index) orelse break;
                const next_cjk = align_cjk and (isCjkBaselineCodepoint(codepoint) or (cjk_run and (isCombiningMark(codepoint) or isVariationSelector(codepoint))));
                if (next_cjk != cjk_run) break;
                pos = next_index;
            }

            const segment_font = if (cjk_run) font.withFamily(cjk_font_family) else font;
            try self.renderTextSegment(
                segment_font,
                bytes[segment_start..pos],
                start.x + compensatedCaretXPhysical(original_text, bytes, segment_start, emoji_advance),
                start.y + (if (cjk_run) cjk_offset_y else 0),
                scale,
                color,
            );
        }
    }

    fn renderTextSegment(
        self: *System,
        font: dvui.Font,
        bytes: []const u8,
        x: f32,
        y: f32,
        scale: f32,
        color: dvui.Color,
    ) !void {
        if (bytes.len == 0) return;
        const shaped = self.layout(font, bytes, scale, null) orelse return error.SdlTtfLayoutFailed;
        defer shaped.release();
        const text = shaped.text;
        _ = c.TTF_SetTextColor(text, color.r, color.g, color.b, color.a);
        if (!c.TTF_DrawRendererText(text, x, y)) return error.SdlTtfDrawFailed;
    }

    fn cjkBaselineOffsetPhysical(self: *System, font: dvui.Font, scale: f32) f32 {
        const primary = self.faceFor(font, scale) orelse return 0;
        const cjk_font = font.withFamily(cjk_font_family);
        const cjk = self.faceFor(cjk_font, scale) orelse return 0;

        const raw_offset: f32 = @floatFromInt(c.TTF_GetFontAscent(primary.primary) - c.TTF_GetFontAscent(cjk.primary));
        const em = @max(1, font.size * safeScale(scale));
        return std.math.clamp(raw_offset, -em * 0.22, em * 0.22);
    }

    fn renderEmojiOverlays(
        self: *System,
        layout_text: *c.TTF_Text,
        bytes: []const u8,
        start: dvui.Point.Physical,
        draw_h: f32,
        line_h: f32,
    ) void {
        var index: usize = 0;
        while (nextEmojiCluster(bytes, &index)) |cluster| {
            const texture = self.emojiTexture(bytes[cluster.start..cluster.end], draw_h) orelse continue;
            const cluster_x = compensatedCaretXPhysical(layout_text, bytes, cluster.start, draw_h);
            const aspect = if (texture.height > 0) texture.width / texture.height else 1;
            const draw_w = @max(1, draw_h * aspect);
            const draw_x = start.x + cluster_x + (draw_h - draw_w) * 0.5;
            const draw_y = start.y + @max(0, line_h - draw_h) * 0.5;
            const dst: c.SDL_FRect = .{
                .x = draw_x,
                .y = draw_y,
                .w = draw_w,
                .h = draw_h,
            };
            _ = c.SDL_RenderTexture(self.renderer, texture.texture, null, &dst);
        }
    }

    fn emojiTexture(self: *System, cluster: []const u8, physical_size: f32) ?EmojiTexture {
        if (builtin.os.tag != .macos) return null;
        const size_key: u16 = @intFromFloat(@max(1, @round(physical_size)));
        var hasher = std.hash.Wyhash.init(0x656d6f6a69);
        hasher.update(cluster);
        hasher.update(std.mem.asBytes(&size_key));
        const key = hasher.final();
        if (self.emoji_textures.get(key)) |texture| return texture;
        if (self.emoji_textures.count() >= 256) self.clearEmojiTextures();

        const bitmap = loadNativeEmojiBitmap(cluster, physical_size) orelse return null;
        defer bitmap.deinit();
        const texture = c.SDL_CreateTexture(
            self.renderer,
            c.SDL_PIXELFORMAT_RGBA32,
            c.SDL_TEXTUREACCESS_STATIC,
            @intCast(bitmap.width),
            @intCast(bitmap.height),
        ) orelse return null;
        var keep = false;
        defer if (!keep) c.SDL_DestroyTexture(texture);
        if (!c.SDL_UpdateTexture(texture, null, bitmap.pixels, bitmap.stride)) return null;
        _ = c.SDL_SetTextureBlendMode(texture, c.SDL_BLENDMODE_BLEND);

        const result: EmojiTexture = .{
            .texture = texture,
            .width = @floatFromInt(bitmap.width),
            .height = @floatFromInt(bitmap.height),
        };
        self.emoji_textures.put(self.allocator, key, result) catch return null;
        keep = true;
        return result;
    }

    fn clearEmojiTextures(self: *System) void {
        var it = self.emoji_textures.valueIterator();
        while (it.next()) |texture| texture.deinit();
        self.emoji_textures.clearRetainingCapacity();
    }
};

const vtable: dvui.TextEngine.VTable = .{
    .deinit = System.destroyFromTextEngine,
    .measure = System.measure,
    .render = System.render,
    .caret_x = System.caretX,
    .caret_point = System.caretPoint,
    .previous_boundary = System.previousBoundary,
    .next_boundary = System.nextBoundary,
};

pub fn ownsEngine(engine: dvui.TextEngine) bool {
    return engine.vtable == &vtable;
}

fn openFont(bytes: []const u8, size: f32) ?*c.TTF_Font {
    const io = c.SDL_IOFromConstMem(bytes.ptr, bytes.len) orelse return null;
    return c.TTF_OpenFontIO(io, true, size);
}

fn openFontPath(allocator: std.mem.Allocator, path: []const u8, size: f32) ?*c.TTF_Font {
    const path_z = allocator.dupeZ(u8, path) catch return null;
    defer allocator.free(path_z);
    return c.TTF_OpenFont(path_z.ptr, size);
}

fn tryAddFallbackBytes(
    allocator: std.mem.Allocator,
    face: *System.Face,
    bytes: []const u8,
    size: f32,
    requested: dvui.Font,
) void {
    const fallback = openFont(bytes, size) orelse return;
    var keep = false;
    defer if (!keep) c.TTF_CloseFont(fallback);
    applyFontStyle(fallback, requested);
    face.fallbacks.append(allocator, fallback) catch return;
    if (!c.TTF_AddFallbackFont(face.primary, fallback)) {
        face.fallbacks.items.len -= 1;
        return;
    }
    keep = true;
}

fn tryAddFallbackPath(
    allocator: std.mem.Allocator,
    face: *System.Face,
    path: []const u8,
    size: f32,
    requested: dvui.Font,
) void {
    const fallback = openFontPath(allocator, path, size) orelse return;
    var keep = false;
    defer if (!keep) c.TTF_CloseFont(fallback);
    applyFontStyle(fallback, requested);
    face.fallbacks.append(allocator, fallback) catch return;
    if (!c.TTF_AddFallbackFont(face.primary, fallback)) {
        face.fallbacks.items.len -= 1;
        return;
    }
    keep = true;
}

fn applyFontStyle(font: *c.TTF_Font, requested: dvui.Font) void {
    var style: c.TTF_FontStyleFlags = c.TTF_STYLE_NORMAL;
    if (requested.weight == .bold) style |= c.TTF_STYLE_BOLD;
    if (requested.style == .italic) style |= c.TTF_STYLE_ITALIC;
    if (requested.underline != null) style |= c.TTF_STYLE_UNDERLINE;
    if (requested.strike != null) style |= c.TTF_STYLE_STRIKETHROUGH;
    c.TTF_SetFontStyle(font, style);
}

fn physicalFontSize(font: dvui.Font, scale: f32) f32 {
    return @max(1, font.size * safeScale(scale));
}

fn fontScaleKey(font: dvui.Font, physical_size: f32) u64 {
    var hasher = std.hash.Wyhash.init(font.hash());
    hasher.update(std.mem.asBytes(&physical_size));
    return hasher.final();
}

fn isMonospaceFont(font: dvui.Font) bool {
    const family = font.familyName();
    return std.mem.indexOf(u8, family, "Mono") != null or
        std.mem.indexOf(u8, family, "mono") != null or
        std.mem.indexOf(u8, family, "Code") != null;
}

fn isCjkFont(font: dvui.Font) bool {
    return std.mem.eql(u8, font.familyName(), cjk_font_family);
}

fn currentScale() f32 {
    return safeScale(dvui.parentGet().screenRectScale(.{}).s);
}

fn safeScale(scale: f32) f32 {
    return if (scale > 0) scale else 1;
}

fn firstLine(text: []const u8) struct { bytes: []const u8, has_newline: bool } {
    if (std.mem.indexOfScalar(u8, text, '\n')) |idx| {
        return .{ .bytes = text[0..idx], .has_newline = true };
    }
    return .{ .bytes = text, .has_newline = false };
}

const simple_measure_probe_bytes: usize = 16 * 1024;

const SimpleMeasureLine = struct {
    bytes: []const u8,
    has_newline: bool,
};

fn simpleMeasureLine(text: []const u8, max_width: bool) ?SimpleMeasureLine {
    const limit = if (max_width)
        @min(text.len, simple_measure_probe_bytes)
    else
        text.len;

    var i: usize = 0;
    while (i < limit) : (i += 1) {
        const byte = text[i];
        if (byte == '\n') return .{ .bytes = text[0..i], .has_newline = true };
        if (!isSimpleAsciiByte(byte)) return null;
    }

    return .{ .bytes = text[0..limit], .has_newline = false };
}

fn measureSimpleWithMetrics(
    line: SimpleMeasureLine,
    metrics: *const System.SimpleMetrics,
    scale: f32,
    options: dvui.Font.TextSizeOptions,
) dvui.Size {
    var end = line.bytes.len;
    var width_px = simpleMetricsWidth(metrics, line.bytes);

    if (options.max_width) |max_width| {
        const result = simpleMetricsMeasureWidth(metrics, line.bytes, @max(0, @round(max_width * scale)), options.end_metric);
        end = result.end;
        width_px = result.width_px;
    }

    if (line.has_newline and end == line.bytes.len) end += 1;
    if (options.end_idx) |out| out.* = @min(end, line.bytes.len + @intFromBool(line.has_newline));
    if (options.ascent_out) |out| out.* = @as(f32, @floatFromInt(metrics.ascent)) / scale;

    return .{
        .w = @as(f32, @floatFromInt(width_px)) / scale,
        .h = @as(f32, @floatFromInt(@max(1, metrics.height))) / scale,
    };
}

fn simpleMetricsWidth(metrics: *const System.SimpleMetrics, bytes: []const u8) c_int {
    var width: c_int = 0;
    for (bytes) |byte| {
        if (byte == '\n' or byte == '\r') break;
        width += metrics.advance(byte);
    }
    return width;
}

fn simpleMetricsMeasureWidth(
    metrics: *const System.SimpleMetrics,
    bytes: []const u8,
    max_width_px: f32,
    end_metric: dvui.Font.EndMetric,
) struct { end: usize, width_px: c_int } {
    if (bytes.len == 0) return .{ .end = 0, .width_px = 0 };

    var width: c_int = 0;
    var pos: usize = 0;
    while (pos < bytes.len) : (pos += 1) {
        const next_width = width + metrics.advance(bytes[pos]);
        if (@as(f32, @floatFromInt(next_width)) > max_width_px) {
            if (end_metric == .nearest) {
                const before_dist = @abs(max_width_px - @as(f32, @floatFromInt(width)));
                const after_dist = @abs(@as(f32, @floatFromInt(next_width)) - max_width_px);
                if (after_dist < before_dist) {
                    return .{ .end = pos + 1, .width_px = next_width };
                }
            }
            return .{ .end = pos, .width_px = width };
        }
        width = next_width;
    }
    return .{ .end = bytes.len, .width_px = width };
}

fn simpleCaretPointWithMetrics(
    prefix: []const u8,
    metrics: *const System.SimpleMetrics,
    scale: f32,
    wrap_width: ?f32,
) ?dvui.Point {
    const line_h = @as(f32, @floatFromInt(@max(1, metrics.height)));
    const wrap_px = if (wrap_width) |width| @max(1, @round(width * scale)) else null;

    var y_px: f32 = 0;
    var x_px: c_int = 0;
    var pos: usize = 0;
    while (pos < prefix.len) : (pos += 1) {
        const byte = prefix[pos];
        if (byte == '\n') {
            x_px = 0;
            y_px += line_h;
            continue;
        }
        const advance = metrics.advance(byte);
        if (wrap_px) |limit| {
            if (x_px > 0 and @as(f32, @floatFromInt(x_px + advance)) > limit) {
                x_px = 0;
                y_px += line_h;
            }
        }
        x_px += advance;
    }

    return .{
        .x = @as(f32, @floatFromInt(x_px)) / scale,
        .y = y_px / scale,
    };
}

fn isSimpleAscii(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (!isSimpleAsciiByte(byte)) return false;
    }
    return true;
}

fn isSimpleAsciiByte(byte: u8) bool {
    if (byte >= 0x80) return false;
    if (byte >= 0x20) return true;
    return byte == '\n' or byte == '\t' or byte == '\r';
}

fn simpleStringWidth(font: *c.TTF_Font, bytes: []const u8) ?c_int {
    if (bytes.len == 0) return 0;
    var width_px: c_int = 0;
    if (!c.TTF_GetStringSize(font, bytes.ptr, bytes.len, &width_px, null)) return null;
    return width_px;
}

fn boundaryForPoint(
    substring: c.TTF_SubString,
    x: c_int,
    metric: dvui.Font.EndMetric,
) usize {
    const start: usize = @intCast(@max(0, substring.offset));
    if (metric == .before or substring.length <= 0) return start;
    const rtl = (substring.flags & c.TTF_SUBSTRING_DIRECTION_MASK) == c.TTF_DIRECTION_RTL;
    const midpoint = substring.rect.x + @divTrunc(substring.rect.w, 2);
    const choose_end = if (rtl) x < midpoint else x >= midpoint;
    return if (choose_end)
        @intCast(@max(0, substring.offset + substring.length))
    else
        start;
}

fn emojiCompensationBefore(
    layout_text: *c.TTF_Text,
    bytes: []const u8,
    byte_offset: usize,
    emoji_advance: f32,
) f32 {
    if (!emojiOverlayEnabled()) return 0;
    var extra: f32 = 0;
    var index: usize = 0;
    const offset = @min(byte_offset, bytes.len);
    while (nextEmojiCluster(bytes, &index)) |cluster| {
        if (cluster.start >= offset) break;
        const delta = emojiClusterDeltaPhysical(layout_text, bytes, cluster, emoji_advance);
        if (cluster.end <= offset) {
            extra += delta;
        } else {
            extra += delta;
            break;
        }
    }
    return extra;
}

fn compensatedCaretXPhysical(
    layout_text: *c.TTF_Text,
    bytes: []const u8,
    byte_offset: usize,
    emoji_advance: f32,
) f32 {
    const offset = @min(byte_offset, bytes.len);
    return caretXPhysicalAt(layout_text, bytes.len, offset) +
        emojiCompensationBefore(layout_text, bytes, offset, emoji_advance);
}

fn compensatedEndForMaxWidth(
    layout_text: *c.TTF_Text,
    bytes: []const u8,
    max_width_px: f32,
    metric: dvui.Font.EndMetric,
    emoji_advance: f32,
) usize {
    if (bytes.len == 0) return 0;
    var previous: usize = 0;
    var previous_x: f32 = 0;
    var offset: usize = 0;
    const limit = @max(0, max_width_px);

    while (offset < bytes.len) {
        const next = nextEmojiOrCodepointBoundary(bytes, offset);
        if (next <= offset) break;
        const next_x = compensatedCaretXPhysical(layout_text, bytes, next, emoji_advance);
        if (next_x > limit) {
            if (metric == .nearest and next != previous) {
                const previous_dist = @abs(limit - previous_x);
                const next_dist = @abs(next_x - limit);
                return if (next_dist < previous_dist) next else previous;
            }
            return previous;
        }
        previous = next;
        previous_x = next_x;
        offset = next;
    }

    return bytes.len;
}

fn emojiClusterDeltaPhysical(
    layout_text: *c.TTF_Text,
    bytes: []const u8,
    cluster: ByteRange,
    emoji_advance: f32,
) f32 {
    const raw_start = caretXPhysicalAt(layout_text, bytes.len, cluster.start);
    const raw_end = caretXPhysicalAt(layout_text, bytes.len, cluster.end);
    const raw_width = @abs(raw_end - raw_start);
    return @max(1, emoji_advance) - raw_width;
}

fn containsEmojiCluster(bytes: []const u8) bool {
    var index: usize = 0;
    return nextEmojiCluster(bytes, &index) != null;
}

fn containsCjkBaselineCodepoint(bytes: []const u8) bool {
    var index: usize = 0;
    while (nextCodepointValue(bytes, &index)) |codepoint| {
        if (isCjkBaselineCodepoint(codepoint)) return true;
    }
    return false;
}

fn isCjkBaselineCodepoint(codepoint: u21) bool {
    return (codepoint >= 0x3400 and codepoint <= 0x4dbf) or // CJK Unified Ideographs Extension A
        (codepoint >= 0x4e00 and codepoint <= 0x9fff) or // CJK Unified Ideographs
        (codepoint >= 0xf900 and codepoint <= 0xfaff) or // CJK Compatibility Ideographs
        (codepoint >= 0x20000 and codepoint <= 0x2ebef) or // CJK extensions
        (codepoint >= 0x3040 and codepoint <= 0x309f) or // Hiragana
        (codepoint >= 0x30a0 and codepoint <= 0x30ff) or // Katakana
        (codepoint >= 0x31f0 and codepoint <= 0x31ff) or // Katakana Phonetic Extensions
        (codepoint >= 0x1100 and codepoint <= 0x11ff) or // Hangul Jamo
        (codepoint >= 0x3130 and codepoint <= 0x318f) or // Hangul Compatibility Jamo
        (codepoint >= 0xac00 and codepoint <= 0xd7af); // Hangul Syllables
}

fn emojiOverlayEnabled() bool {
    return builtin.os.tag == .macos;
}

fn caretXPhysicalAt(text: *c.TTF_Text, text_len: usize, byte_offset: usize) f32 {
    if (byte_offset >= text_len) {
        var width_px: c_int = 0;
        var height_px: c_int = 0;
        if (c.TTF_GetTextSize(text, &width_px, &height_px)) {
            return @floatFromInt(@max(0, width_px));
        }
    }
    return caretXPhysical(text, byte_offset);
}

fn caretXPhysical(text: *c.TTF_Text, byte_offset: usize) f32 {
    var substring: c.TTF_SubString = undefined;
    if (!c.TTF_GetTextSubString(text, @intCast(byte_offset), &substring)) return 0;
    const rtl = (substring.flags & c.TTF_SUBSTRING_DIRECTION_MASK) == c.TTF_DIRECTION_RTL;
    if (byte_offset <= @as(usize, @intCast(@max(0, substring.offset)))) {
        return @floatFromInt(if (rtl) substring.rect.x + substring.rect.w else substring.rect.x);
    }
    return @floatFromInt(if (rtl) substring.rect.x else substring.rect.x + substring.rect.w);
}

fn previousCodepoint(text: []const u8, offset: usize) usize {
    var result = @min(offset, text.len);
    if (result == 0) return 0;
    result -= 1;
    while (result > 0 and text[result] & 0xc0 == 0x80) result -= 1;
    return result;
}

fn previousEmojiOrCodepoint(text: []const u8, offset: usize) usize {
    const bounded = @min(offset, text.len);
    var index: usize = 0;
    while (nextEmojiCluster(text, &index)) |cluster| {
        if (cluster.start < bounded and bounded <= cluster.end) return cluster.start;
        if (cluster.start >= bounded) break;
    }
    return previousCodepoint(text, bounded);
}

fn nextCodepoint(text: []const u8, offset: usize) usize {
    if (offset >= text.len) return text.len;
    return @min(text.len, offset + (std.unicode.utf8ByteSequenceLength(text[offset]) catch 1));
}

fn nextEmojiOrCodepointBoundary(text: []const u8, offset: usize) usize {
    const bounded = @min(offset, text.len);
    var index: usize = bounded;
    if (nextEmojiCluster(text, &index)) |cluster| {
        if (cluster.start == bounded) return cluster.end;
    }
    return nextCodepoint(text, bounded);
}

const ByteRange = struct {
    start: usize,
    end: usize,
};

fn nextEmojiCluster(text: []const u8, index: *usize) ?ByteRange {
    while (index.* < text.len) {
        const start = index.*;
        const first = nextCodepointValue(text, index) orelse return null;
        if (!isEmojiBase(first)) continue;

        var end = index.*;
        if (isRegionalIndicator(first) and index.* < text.len) {
            const save = index.*;
            if (nextCodepointValue(text, index)) |second| {
                if (isRegionalIndicator(second)) {
                    end = index.*;
                    return .{ .start = start, .end = end };
                }
            }
            index.* = save;
        }

        var after_zwj = false;
        while (index.* < text.len) {
            const next_start = index.*;
            const codepoint = nextCodepointValue(text, index) orelse {
                index.* = next_start;
                break;
            };
            if (isEmojiClusterPart(codepoint)) {
                end = index.*;
                after_zwj = codepoint == 0x200d;
                continue;
            }
            if (after_zwj and isEmojiBase(codepoint)) {
                end = index.*;
                after_zwj = false;
                continue;
            }
            index.* = next_start;
            break;
        }
        return .{ .start = start, .end = end };
    }
    return null;
}

fn nextCodepointValue(text: []const u8, index: *usize) ?u21 {
    if (index.* >= text.len) return null;
    const len = std.unicode.utf8ByteSequenceLength(text[index.*]) catch return null;
    const end = index.* + len;
    if (end > text.len) return null;
    const codepoint = std.unicode.utf8Decode(text[index.*..end]) catch return null;
    index.* = end;
    return codepoint;
}

fn isEmojiBase(codepoint: u21) bool {
    return isRegionalIndicator(codepoint) or
        (codepoint >= 0x1f000 and codepoint <= 0x1faff) or
        (codepoint >= 0x2600 and codepoint <= 0x27bf) or
        codepoint == 0x00a9 or
        codepoint == 0x00ae or
        codepoint == 0x2122 or
        codepoint == 0x2139 or
        codepoint == 0x3030 or
        codepoint == 0x303d or
        codepoint == 0x3297 or
        codepoint == 0x3299;
}

fn isEmojiClusterPart(codepoint: u21) bool {
    // Keep ZWJ out of the overlay cluster. The macOS offscreen renderer used
    // here reliably draws individual emoji but may return blank bitmaps for
    // some full ZWJ sequences, so the visual fallback renders their emoji
    // components instead of hiding the whole sequence.
    return codepoint == 0x20e3 or
        isVariationSelector(codepoint) or
        isEmojiModifier(codepoint) or
        isCombiningMark(codepoint);
}

fn isRegionalIndicator(codepoint: u21) bool {
    return codepoint >= 0x1f1e6 and codepoint <= 0x1f1ff;
}

fn isVariationSelector(codepoint: u21) bool {
    return (codepoint >= 0xfe00 and codepoint <= 0xfe0f) or
        (codepoint >= 0xe0100 and codepoint <= 0xe01ef);
}

fn isEmojiModifier(codepoint: u21) bool {
    return codepoint >= 0x1f3fb and codepoint <= 0x1f3ff;
}

fn isCombiningMark(codepoint: u21) bool {
    return (codepoint >= 0x0300 and codepoint <= 0x036f) or
        (codepoint >= 0x1ab0 and codepoint <= 0x1aff) or
        (codepoint >= 0x1dc0 and codepoint <= 0x1dff) or
        (codepoint >= 0x20d0 and codepoint <= 0x20ff) or
        (codepoint >= 0xfe20 and codepoint <= 0xfe2f);
}

const NativeEmojiBitmap = extern struct {
    pixels: *anyopaque,
    width: c_int,
    height: c_int,
    stride: c_int,

    fn deinit(self: NativeEmojiBitmap) void {
        shellowo_free_emoji_bitmap(self.pixels);
    }
};

fn loadNativeEmojiBitmap(cluster: []const u8, physical_size: f32) ?NativeEmojiBitmap {
    if (builtin.os.tag != .macos) return null;
    var bitmap: NativeEmojiBitmap = undefined;
    if (shellowo_render_emoji_bitmap(cluster.ptr, cluster.len, @floatCast(physical_size), &bitmap) == 0) return null;
    if (bitmap.width <= 0 or bitmap.height <= 0 or bitmap.stride <= 0) {
        bitmap.deinit();
        return null;
    }
    return bitmap;
}

extern fn shellowo_render_emoji_bitmap(
    utf8: [*]const u8,
    utf8_len: usize,
    point_size: f64,
    out_bitmap: *NativeEmojiBitmap,
) callconv(.c) c_int;

extern fn shellowo_free_emoji_bitmap(pixels: *anyopaque) callconv(.c) void;

test "fallback boundaries preserve UTF-8 codepoints" {
    const text = "a你🙂z";
    try std.testing.expectEqual(@as(usize, 1), previousCodepoint(text, 4));
    try std.testing.expectEqual(@as(usize, 4), previousCodepoint(text, 8));
    try std.testing.expectEqual(@as(usize, 4), nextCodepoint(text, 1));
    try std.testing.expectEqual(@as(usize, 8), nextCodepoint(text, 4));
}

test "emoji scanner groups modifiers and ZWJ sequences" {
    const text = "a👍🏽 b👨‍👩‍👧‍👦 c🇨🇳";
    var index: usize = 0;
    const first = nextEmojiCluster(text, &index).?;
    try std.testing.expectEqualStrings("👍🏽", text[first.start..first.end]);
    const second = nextEmojiCluster(text, &index).?;
    try std.testing.expectEqualStrings("👨", text[second.start..second.end]);
    const third = nextEmojiCluster(text, &index).?;
    try std.testing.expectEqualStrings("👩", text[third.start..third.end]);
    const fourth = nextEmojiCluster(text, &index).?;
    try std.testing.expectEqualStrings("👧", text[fourth.start..fourth.end]);
    const fifth = nextEmojiCluster(text, &index).?;
    try std.testing.expectEqualStrings("👦", text[fifth.start..fifth.end]);
    const sixth = nextEmojiCluster(text, &index).?;
    try std.testing.expectEqualStrings("🇨🇳", text[sixth.start..sixth.end]);
    try std.testing.expect(nextEmojiCluster(text, &index) == null);
}

test "emoji cluster previous boundary keeps modifiers with base emoji" {
    const text = "a😊b👍🏽c";
    try std.testing.expectEqual(@as(usize, 1), previousEmojiOrCodepoint(text, 5));
    try std.testing.expectEqual(@as(usize, 6), previousEmojiOrCodepoint(text, 14));
}

test "firstLine reports the consumed newline" {
    const line = firstLine("abc\n下一行");
    try std.testing.expectEqualStrings("abc", line.bytes);
    try std.testing.expect(line.has_newline);
}
