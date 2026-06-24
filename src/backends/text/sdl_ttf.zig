const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const platform_fonts = @import("platform_fonts.zig");

const c = dvui.backend.c;
const cjk_font_family = "Noto Sans CJK SC";
const emoji_advance_padding_ratio: f32 = 0.16;

pub const System = struct {
    allocator: std.mem.Allocator,
    renderer: *c.SDL_Renderer,
    engine: *c.TTF_TextEngine,
    font_sources: FontSources,
    system_fallbacks: platform_fonts.List = .{},
    fonts: std.AutoHashMapUnmanaged(u64, Face) = .empty,
    font_heights: std.AutoHashMapUnmanaged(u64, f32) = .empty,
    simple_metrics: std.AutoHashMapUnmanaged(u64, SimpleMetrics) = .empty,
    emoji_textures: std.AutoHashMapUnmanaged(u64, EmojiTexture) = .empty,
    measure_cache: std.ArrayListUnmanaged(MeasureCacheEntry) = .empty,

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
        text: *c.TTF_Text,

        fn release(self: Layout) void {
            c.TTF_DestroyText(self.text);
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

    const MeasureCacheEntry = struct {
        font_key: u64,
        text_hash: u64,
        text: []u8,
        size: dvui.Size,
        end_idx: usize,
        ascent: f32,

        fn deinit(self: *MeasureCacheEntry, allocator: std.mem.Allocator) void {
            allocator.free(self.text);
            self.* = undefined;
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
        var emoji_it = self.emoji_textures.valueIterator();
        while (emoji_it.next()) |texture| texture.deinit();
        self.emoji_textures.deinit(self.allocator);
        self.clearMeasureCache();
        self.measure_cache.deinit(self.allocator);
        self.simple_metrics.deinit(self.allocator);
        self.font_heights.deinit(self.allocator);
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
        const face = self.faceFor(font, scale) orelse return null;
        const safe_text = overlaySafeLayoutText(self.allocator, text) catch return null;
        defer if (safe_text) |buffer| self.allocator.free(buffer);
        const layout_text = safe_text orelse text;
        const result = c.TTF_CreateText(
            self.engine,
            face.primary,
            if (layout_text.len == 0) null else layout_text.ptr,
            layout_text.len,
        ) orelse return null;
        if (wrap_width) |width| {
            const physical_width: c_int = @intFromFloat(@max(1, @ceil(width * safeScale(scale))));
            if (!c.TTF_SetTextWrapWidth(result, physical_width)) {
                c.TTF_DestroyText(result);
                return null;
            }
            _ = c.TTF_SetTextWrapWhitespaceVisible(result, true);
        }
        return .{ .text = result };
    }

    fn fontTextHeightPhysical(self: *System, font: dvui.Font, scale: f32) f32 {
        const physical_size = physicalFontSize(font, scale);
        const key = fontScaleKey(font, physical_size);
        if (self.font_heights.get(key)) |height| return height;

        const shaped = self.layout(font, "M", scale, null) orelse
            return @max(1, font.size * safeScale(scale));
        defer shaped.release();

        var result = @max(1, font.size * safeScale(scale));
        var width_px: c_int = 0;
        var height_px: c_int = 0;
        if (c.TTF_GetTextSize(shaped.text, &width_px, &height_px)) {
            result = @floatFromInt(@max(1, height_px));
        }
        self.font_heights.put(self.allocator, key, result) catch {};
        return result;
    }

    fn emojiBoxPhysical(self: *System, font: dvui.Font, scale: f32) f32 {
        const text_height = self.fontTextHeightPhysical(font, scale);
        const em = @max(1, font.size * safeScale(scale));
        return @max(1, @min(text_height * 0.82, em * 1.04));
    }

    fn emojiAdvancePhysical(self: *System, font: dvui.Font, scale: f32) f32 {
        return emojiAdvanceForBox(self.emojiBoxPhysical(font, scale));
    }

    fn measureCacheGet(
        self: *System,
        font: dvui.Font,
        text: []const u8,
        scale: f32,
        options: dvui.Font.TextSizeOptions,
    ) ?dvui.Size {
        if (!measureCacheEligible(text, options)) return null;

        const font_key = fontScaleKey(font, physicalFontSize(font, scale));
        const text_hash = std.hash.Wyhash.hash(0x6d656173757265, text);
        for (self.measure_cache.items) |entry| {
            if (entry.font_key != font_key or entry.text_hash != text_hash) continue;
            if (!std.mem.eql(u8, entry.text, text)) continue;
            if (options.end_idx) |out| out.* = entry.end_idx;
            if (options.ascent_out) |out| out.* = entry.ascent;
            return entry.size;
        }

        return null;
    }

    fn measureCachePut(
        self: *System,
        font: dvui.Font,
        text: []const u8,
        scale: f32,
        options: dvui.Font.TextSizeOptions,
        size: dvui.Size,
        end_idx: usize,
        ascent: f32,
    ) void {
        if (!measureCacheEligible(text, options)) return;
        if (self.measure_cache.items.len >= max_measure_cache_entries) self.clearMeasureCache();

        const owned_text = self.allocator.dupe(u8, text) catch return;

        self.measure_cache.append(self.allocator, .{
            .font_key = fontScaleKey(font, physicalFontSize(font, scale)),
            .text_hash = std.hash.Wyhash.hash(0x6d656173757265, text),
            .text = owned_text,
            .size = size,
            .end_idx = end_idx,
            .ascent = ascent,
        }) catch {
            self.allocator.free(owned_text);
            return;
        };
    }

    fn clearMeasureCache(self: *System) void {
        for (self.measure_cache.items) |*entry| entry.deinit(self.allocator);
        self.measure_cache.clearRetainingCapacity();
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
        if (self.measureCacheGet(font, text, scale, options)) |cached| return cached;

        const line = firstLine(text);
        const analysis = analyzeText(line.bytes);
        if (self.measureEmojiLine(font, text, line, scale, options, analysis.has_emoji)) |emoji| return emoji;

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
        const has_emoji = analysis.has_emoji;
        const emoji_box = self.emojiBoxPhysical(font, scale);
        const emoji_advance = emojiAdvanceForBox(emoji_box);
        if (options.max_width) |max_width| {
            const point_x: c_int = @intFromFloat(@max(0, @round(max_width * scale)));
            if (has_emoji) {
                end = compensatedEndForMaxWidth(
                    layout_text,
                    line.bytes,
                    @floatFromInt(point_x),
                    options.end_metric,
                    emoji_advance,
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
            while (end > 0 and compensatedCaretXPhysical(layout_text, line.bytes, end, emoji_advance) > max_width_px) {
                const previous = previousEmojiOrCodepoint(line.bytes, end);
                if (previous >= end) break;
                end = previous;
            }
        }
        if (line.has_newline and end == line.bytes.len) end += 1;
        const measured_end = @min(end, text.len);
        if (options.end_idx) |out| out.* = measured_end;
        const ascent = if (self.faceFor(font, scale)) |face|
            @as(f32, @floatFromInt(c.TTF_GetFontAscent(face.primary))) / scale
        else
            font.size;
        if (options.ascent_out) |out| out.* = ascent;

        const measured_width_px = if (end < line.bytes.len)
            compensatedCaretXPhysical(layout_text, line.bytes, end, emoji_advance)
        else
            @as(f32, @floatFromInt(width_px)) + emojiCompensationBefore(layout_text, line.bytes, line.bytes.len, emoji_advance);
        const measured_height_px = if (has_emoji)
            @max(self.fontTextHeightPhysical(font, scale), emoji_box)
        else
            @as(f32, @floatFromInt(height_px));
        const result: dvui.Size = .{
            .w = @max(0, measured_width_px) / scale,
            .h = measured_height_px / scale,
        };
        self.measureCachePut(font, text, scale, options, result, measured_end, ascent);
        return result;
    }

    fn measureEmojiLine(
        self: *System,
        font: dvui.Font,
        text: []const u8,
        line: TextLine,
        scale: f32,
        options: dvui.Font.TextSizeOptions,
        has_emoji: bool,
    ) ?dvui.Size {
        if (!emojiOverlayEnabled()) return null;
        if (!has_emoji) return null;

        const face = self.faceFor(font, scale) orelse return null;
        const emoji_box = self.emojiBoxPhysical(font, scale);
        const emoji_advance = emojiAdvanceForBox(emoji_box);
        const metrics = self.simpleMetricsFor(font, scale);

        const measured = if (options.max_width) |max_width|
            measureEmojiWidth(face.primary, metrics, line.bytes, emoji_advance, @max(0, max_width * scale), options.end_metric)
        else
            measureEmojiWidth(face.primary, metrics, line.bytes, emoji_advance, null, options.end_metric);

        var end = measured.end;
        if (line.has_newline and end == line.bytes.len) end += 1;
        if (options.end_idx) |out| out.* = @min(end, line.bytes.len + @intFromBool(line.has_newline));
        if (options.ascent_out) |out| out.* = @as(f32, @floatFromInt(c.TTF_GetFontAscent(face.primary))) / scale;

        const result: dvui.Size = .{
            .w = @max(0, measured.width_px) / scale,
            .h = @max(self.fontTextHeightPhysical(font, scale), emoji_box) / scale,
        };
        self.measureCachePut(font, text, scale, options, result, @min(end, text.len), @as(f32, @floatFromInt(c.TTF_GetFontAscent(face.primary))) / scale);
        return result;
    }

    fn measureEmojiWidth(
        primary: *c.TTF_Font,
        metrics: ?*SimpleMetrics,
        bytes: []const u8,
        emoji_advance: f32,
        max_width_px: ?f32,
        end_metric: dvui.Font.EndMetric,
    ) struct { end: usize, width_px: f32 } {
        var emoji_index: usize = 0;
        var next_emoji = nextEmojiCluster(bytes, &emoji_index);
        var symbol_index: usize = 0;
        var next_symbol = nextSymbolOverlay(bytes, &symbol_index);
        var pos: usize = 0;
        var end: usize = 0;
        var width_px: f32 = 0;

        while (pos < bytes.len) {
            while (next_emoji) |cluster| {
                if (cluster.end > pos) break;
                next_emoji = nextEmojiCluster(bytes, &emoji_index);
            }
            while (next_symbol) |symbol| {
                if (symbol.range.end > pos) break;
                next_symbol = nextSymbolOverlay(bytes, &symbol_index);
            }

            const token: EmojiMeasureToken = blk: {
                if (next_emoji) |cluster| {
                    if (cluster.start == pos) {
                        break :blk .{ .end = cluster.end, .advance = emoji_advance };
                    }
                }
                if (next_symbol) |symbol| {
                    if (symbol.range.start == pos) {
                        break :blk .{ .end = symbol.range.end, .advance = symbolPlaceholderAdvancePhysical(primary, metrics) };
                    }
                }

                var token_end = nextCodepoint(bytes, pos);
                if (next_emoji) |cluster| token_end = @min(token_end, cluster.start);
                if (next_symbol) |symbol| token_end = @min(token_end, symbol.range.start);
                break :blk .{
                    .end = token_end,
                    .advance = nonEmojiTokenAdvancePhysical(primary, metrics, bytes[pos..token_end]),
                };
            };

            if (token.end <= pos) break;
            const next_width = width_px + token.advance;
            if (max_width_px) |limit| {
                if (next_width > limit) {
                    if (end_metric == .nearest and token.end != end) {
                        const before_dist = @abs(limit - width_px);
                        const after_dist = @abs(next_width - limit);
                        if (after_dist < before_dist) {
                            return .{ .end = token.end, .width_px = next_width };
                        }
                    }
                    return .{ .end = end, .width_px = width_px };
                }
            }
            pos = token.end;
            end = pos;
            width_px = next_width;
        }

        return .{ .end = end, .width_px = width_px };
    }

    fn nonEmojiTokenAdvancePhysical(
        primary: *c.TTF_Font,
        metrics: ?*SimpleMetrics,
        bytes: []const u8,
    ) f32 {
        if (bytes.len == 0) return 0;
        if (metrics) |m| {
            if (isSimpleAscii(bytes)) {
                return @floatFromInt(simpleMetricsWidth(m, bytes));
            }
        }

        var width_px: c_int = 0;
        if (c.TTF_GetStringSize(primary, bytes.ptr, bytes.len, &width_px, null)) {
            return @floatFromInt(@max(0, width_px));
        }
        return 0;
    }

    fn symbolPlaceholderAdvancePhysical(
        primary: *c.TTF_Font,
        metrics: ?*SimpleMetrics,
    ) f32 {
        if (metrics) |m| return @floatFromInt(m.advance(' '));

        const measured = nonEmojiTokenAdvancePhysical(primary, null, symbol_placeholder);
        if (measured > 0) return measured;
        return nonEmojiTokenAdvancePhysical(primary, null, " ");
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
        const emoji_advance = emojiAdvanceForBox(emoji_box);
        const analysis = analyzeText(options.text);
        const has_emoji = analysis.has_emoji;
        const use_emoji_overlay = has_emoji and emojiOverlayEnabled();
        const use_symbol_overlay = analysis.has_symbol_overlay;
        const emoji_extra = if (use_emoji_overlay) emojiCompensationBefore(text, options.text, options.text.len, emoji_advance) else 0;
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
            const x0 = compensatedCaretXPhysical(text, options.text, sel_start, emoji_advance);
            const x1 = compensatedCaretXPhysical(text, options.text, sel_end, emoji_advance);
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

        const align_cjk = analysis.has_cjk_baseline and !isCjkFont(options.font);
        if (use_emoji_overlay or align_cjk) {
            try self.renderVisualTextSegments(options.font, text, options.text, start, scale, options.color, emoji_advance, use_emoji_overlay, align_cjk);
        } else if (!c.TTF_DrawRendererText(text, start.x, start.y)) return error.SdlTtfDrawFailed;
        if (use_emoji_overlay) self.renderEmojiOverlays(text, options.text, start, emoji_box, emoji_advance, render_height);
        if (use_symbol_overlay) renderSymbolOverlays(text, options.text, start, options.color, emoji_advance, render_height, scale);
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
        return compensatedCaretXPhysical(layout_text, text, byte_offset, self.emojiAdvancePhysical(font, scale)) / scale;
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
                .x = compensatedCaretXPhysical(layout_text, text, byte_offset, self.emojiAdvancePhysical(font, scale)) / scale,
                .y = 0,
            };
        }
        const emoji_box = self.emojiBoxPhysical(font, scale);
        const emoji_advance = emojiAdvanceForBox(emoji_box);
        const rtl = (substring.flags & c.TTF_SUBSTRING_DIRECTION_MASK) == c.TTF_DIRECTION_RTL;
        const at_start = byte_offset <= @as(usize, @intCast(@max(0, substring.offset)));
        const x_px: f32 = @floatFromInt(if (at_start)
            (if (rtl) substring.rect.x + substring.rect.w else substring.rect.x)
        else
            (if (rtl) substring.rect.x else substring.rect.x + substring.rect.w));
        return .{
            .x = (x_px + emojiCompensationBeforeOnVisualLine(layout_text, text, byte_offset, substring.rect.y, emoji_advance)) / scale,
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
        if (previousEmojiBoundaryNear(text, byte_offset)) |boundary| return boundary;
        if (isFastSingleBytePreviousBoundary(text, byte_offset)) return byte_offset - 1;

        const self: *System = @ptrCast(@alignCast(context));
        const window = boundaryWindow(text, byte_offset);
        const local_offset = byte_offset - window.start;
        const shaped = self.layout(font, text[window.start..window.end], currentScale(), null) orelse
            return previousCodepoint(text, byte_offset);
        defer shaped.release();
        const layout_text = shaped.text;

        var substring: c.TTF_SubString = undefined;
        if (local_offset == 0 or !c.TTF_GetTextSubString(layout_text, @intCast(local_offset - 1), &substring)) {
            return previousCodepoint(text, byte_offset);
        }
        const result = window.start + @as(usize, @intCast(@max(0, substring.offset)));
        if (result >= byte_offset) return previousCodepoint(text, byte_offset);
        return result;
    }

    fn nextBoundary(
        context: *anyopaque,
        font: dvui.Font,
        text: []const u8,
        byte_offset: usize,
    ) usize {
        if (byte_offset >= text.len) return text.len;
        if (nextEmojiBoundaryNear(text, byte_offset)) |boundary| return boundary;
        if (isFastSingleByteNextBoundary(text, byte_offset)) return byte_offset + 1;

        const self: *System = @ptrCast(@alignCast(context));
        const window = boundaryWindow(text, byte_offset);
        const local_offset = byte_offset - window.start;
        const shaped = self.layout(font, text[window.start..window.end], currentScale(), null) orelse
            return nextCodepoint(text, byte_offset);
        defer shaped.release();
        const layout_text = shaped.text;

        var substring: c.TTF_SubString = undefined;
        if (!c.TTF_GetTextSubString(layout_text, @intCast(local_offset), &substring)) {
            return nextCodepoint(text, byte_offset);
        }
        const local_result = @as(usize, @intCast(@max(0, substring.offset + substring.length)));
        const result = @min(text.len, window.start + local_result);
        if (result <= byte_offset) return nextCodepoint(text, byte_offset);
        return result;
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
        emoji_advance: f32,
        line_h: f32,
    ) void {
        var index: usize = 0;
        while (nextEmojiCluster(bytes, &index)) |cluster| {
            const texture = self.emojiTexture(bytes[cluster.start..cluster.end], draw_h) orelse continue;
            const cluster_x = compensatedCaretXPhysical(layout_text, bytes, cluster.start, emoji_advance);
            const aspect = if (texture.height > 0) texture.width / texture.height else 1;
            var draw_w = @max(1, draw_h * aspect);
            var draw_actual_h = draw_h;
            if (draw_w > emoji_advance) {
                draw_w = @max(1, emoji_advance);
                draw_actual_h = @max(1, draw_w / @max(aspect, 0.01));
            }
            const draw_x = start.x + cluster_x + @max(0, (emoji_advance - draw_w) * 0.5);
            const draw_y = start.y + @max(0, line_h - draw_actual_h) * 0.5;
            const dst: c.SDL_FRect = .{
                .x = draw_x,
                .y = draw_y,
                .w = draw_w,
                .h = draw_actual_h,
            };
            _ = c.SDL_RenderTexture(self.renderer, texture.texture, null, &dst);
        }
    }

    fn renderSymbolOverlays(
        layout_text: *c.TTF_Text,
        bytes: []const u8,
        start: dvui.Point.Physical,
        color: dvui.Color,
        emoji_advance: f32,
        line_h: f32,
        scale: f32,
    ) void {
        var index: usize = 0;
        while (nextSymbolOverlay(bytes, &index)) |symbol| {
            const x0 = compensatedCaretXPhysical(layout_text, bytes, symbol.range.start, emoji_advance);
            const x1 = compensatedCaretXPhysical(layout_text, bytes, symbol.range.end, emoji_advance);
            const slot_x = @min(x0, x1);
            const slot_w = @max(1, @abs(x1 - x0));
            const center: dvui.Point.Physical = .{
                .x = start.x + slot_x + slot_w * 0.5,
                .y = start.y + line_h * 0.5,
            };
            drawSymbolOverlay(symbol.kind, center, slot_w, line_h, color, scale);
        }
    }

    fn drawSymbolOverlay(
        kind: SymbolOverlayKind,
        center: dvui.Point.Physical,
        slot_w: f32,
        line_h: f32,
        color: dvui.Color,
        scale: f32,
    ) void {
        switch (kind) {
            .square_outline => drawSymbolSquare(center, slot_w, line_h, color, scale, false, false),
            .square_filled => drawSymbolSquare(center, slot_w, line_h, color, scale, true, false),
            .small_square_outline => drawSymbolSquare(center, slot_w, line_h, color, scale, false, true),
            .small_square_filled => drawSymbolSquare(center, slot_w, line_h, color, scale, true, true),
            .triangle_up => drawSymbolTriangle(.up, center, slot_w, line_h, color, false),
            .triangle_down => drawSymbolTriangle(.down, center, slot_w, line_h, color, false),
            .triangle_left => drawSymbolTriangle(.left, center, slot_w, line_h, color, false),
            .triangle_right => drawSymbolTriangle(.right, center, slot_w, line_h, color, false),
            .triangle_up_outline => drawSymbolTriangle(.up, center, slot_w, line_h, color, true),
            .triangle_down_outline => drawSymbolTriangle(.down, center, slot_w, line_h, color, true),
            .triangle_left_outline => drawSymbolTriangle(.left, center, slot_w, line_h, color, true),
            .triangle_right_outline => drawSymbolTriangle(.right, center, slot_w, line_h, color, true),
        }
    }

    fn drawSymbolSquare(
        center: dvui.Point.Physical,
        slot_w: f32,
        line_h: f32,
        color: dvui.Color,
        scale: f32,
        filled: bool,
        small: bool,
    ) void {
        const ratio: f32 = if (small) 0.32 else 0.56;
        const slot_ratio: f32 = if (small) 0.72 else 0.86;
        const size = @max(2 * scale, @min(line_h * ratio, slot_w * slot_ratio));
        const rect: dvui.Rect.Physical = .{
            .x = center.x - size * 0.5,
            .y = center.y - size * 0.5,
            .w = size,
            .h = size,
        };
        if (filled) {
            rect.fill(.all(0), .{ .color = color, .fade = 0 });
        } else {
            rect.stroke(.all(0), .{ .thickness = @max(1, @round(1.15 * scale)), .color = color });
        }
    }

    const TriangleDirection = enum { up, down, left, right };

    fn drawSymbolTriangle(
        direction: TriangleDirection,
        center: dvui.Point.Physical,
        slot_w: f32,
        line_h: f32,
        color: dvui.Color,
        outline: bool,
    ) void {
        const size = @max(3, @min(line_h * 0.72, slot_w * 0.96));
        const half = size * 0.5;
        const third = size / 6;
        const pts = switch (direction) {
            .down => [_]dvui.Point.Physical{
                .{ .x = center.x - half, .y = center.y - half + third },
                .{ .x = center.x + half, .y = center.y - half + third },
                .{ .x = center.x, .y = center.y + half + third },
            },
            .up => [_]dvui.Point.Physical{
                .{ .x = center.x, .y = center.y - half - third },
                .{ .x = center.x + half, .y = center.y + half - third },
                .{ .x = center.x - half, .y = center.y + half - third },
            },
            .right => [_]dvui.Point.Physical{
                .{ .x = center.x - half + third, .y = center.y - half },
                .{ .x = center.x + half + third, .y = center.y },
                .{ .x = center.x - half + third, .y = center.y + half },
            },
            .left => [_]dvui.Point.Physical{
                .{ .x = center.x - half - third, .y = center.y },
                .{ .x = center.x + half - third, .y = center.y + half },
                .{ .x = center.x + half - third, .y = center.y - half },
            },
        };
        const path: dvui.Path = .{ .points = &pts };
        if (outline) {
            path.stroke(.{ .thickness = @max(1, line_h * 0.06), .color = color, .closed = true });
        } else {
            path.fillConvex(.{ .color = color, .fade = 0 });
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

fn emojiAdvanceForBox(emoji_box: f32) f32 {
    return @max(1, emoji_box) + @max(1, emoji_box * emoji_advance_padding_ratio);
}

const TextLine = struct {
    bytes: []const u8,
    has_newline: bool,
};

fn firstLine(text: []const u8) TextLine {
    if (std.mem.indexOfScalar(u8, text, '\n')) |idx| {
        return .{ .bytes = text[0..idx], .has_newline = true };
    }
    return .{ .bytes = text, .has_newline = false };
}

const EmojiMeasureToken = struct {
    end: usize,
    advance: f32,
};

const max_measure_cache_entries: usize = 128;
const max_measure_cache_text_bytes: usize = 512;

fn measureCacheEligible(text: []const u8, options: dvui.Font.TextSizeOptions) bool {
    if (options.max_width != null) return false;
    return text.len <= max_measure_cache_text_bytes;
}

const boundary_context_bytes: usize = 512;

const BoundaryWindow = struct {
    start: usize,
    end: usize,
};

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

fn emojiCompensationBeforeOnVisualLine(
    layout_text: *c.TTF_Text,
    bytes: []const u8,
    byte_offset: usize,
    line_y: c_int,
    emoji_advance: f32,
) f32 {
    if (!emojiOverlayEnabled()) return 0;
    var extra: f32 = 0;
    var index: usize = 0;
    const offset = @min(byte_offset, bytes.len);
    while (nextEmojiCluster(bytes, &index)) |cluster| {
        if (cluster.start >= offset) break;
        if (!emojiClusterOnVisualLine(layout_text, cluster, line_y)) continue;

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

fn emojiClusterOnVisualLine(layout_text: *c.TTF_Text, cluster: ByteRange, line_y: c_int) bool {
    var substring: c.TTF_SubString = undefined;
    if (!c.TTF_GetTextSubString(layout_text, @intCast(cluster.start), &substring)) return false;
    return substring.rect.y == line_y;
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

const TextAnalysis = struct {
    has_emoji: bool = false,
    has_cjk_baseline: bool = false,
    has_symbol_overlay: bool = false,
};

fn analyzeText(bytes: []const u8) TextAnalysis {
    var result: TextAnalysis = .{};
    var index: usize = 0;
    while (index < bytes.len) {
        const start = index;
        const codepoint = nextCodepointValue(bytes, &index) orelse {
            index = start + 1;
            continue;
        };
        if (!result.has_emoji and isEmojiBase(codepoint)) result.has_emoji = true;
        if (!result.has_cjk_baseline and isCjkBaselineCodepoint(codepoint)) result.has_cjk_baseline = true;
        if (!result.has_symbol_overlay and symbolOverlayKindForCodepoint(codepoint) != null) result.has_symbol_overlay = true;
        if (result.has_emoji and result.has_cjk_baseline and result.has_symbol_overlay) break;
    }
    return result;
}

fn overlaySafeLayoutText(allocator: std.mem.Allocator, bytes: []const u8) !?[]u8 {
    const needs_emoji_safe_text = emojiOverlayEnabled() and containsEmojiCluster(bytes);
    const needs_symbol_safe_text = containsSymbolOverlay(bytes);
    if (!needs_emoji_safe_text and !needs_symbol_safe_text) return null;

    const safe = try allocator.dupe(u8, bytes);
    if (needs_emoji_safe_text) {
        var index: usize = 0;
        while (nextEmojiCluster(bytes, &index)) |cluster| {
            @memset(safe[cluster.start..cluster.end], ' ');
        }
        replaceEmojiJoiners(safe);
    }
    if (needs_symbol_safe_text) {
        replaceSymbolOverlaysWithPlaceholders(bytes, safe);
    }
    return safe;
}

fn replaceEmojiJoiners(bytes: []u8) void {
    var index: usize = 0;
    while (index < bytes.len) {
        const start = index;
        const codepoint = nextCodepointValue(bytes, &index) orelse {
            index = start + 1;
            continue;
        };
        if (codepoint == 0x200d) {
            @memset(bytes[start..index], ' ');
        }
    }
}

const symbol_placeholder = "\u{2007}";

fn containsSymbolOverlay(bytes: []const u8) bool {
    var index: usize = 0;
    return nextSymbolOverlay(bytes, &index) != null;
}

fn replaceSymbolOverlaysWithPlaceholders(original: []const u8, safe: []u8) void {
    std.debug.assert(original.len == safe.len);
    var index: usize = 0;
    while (nextSymbolOverlay(original, &index)) |symbol| {
        const target = safe[symbol.range.start..symbol.range.end];
        if (target.len == symbol_placeholder.len) {
            @memcpy(target, symbol_placeholder);
        } else {
            @memset(target, ' ');
        }
    }
}

fn previousEmojiBoundary(bytes: []const u8, byte_offset: usize) ?usize {
    const offset = @min(byte_offset, bytes.len);
    var index: usize = 0;
    while (nextEmojiCluster(bytes, &index)) |cluster| {
        if (cluster.start < offset and offset <= cluster.end) return cluster.start;
        if (cluster.start >= offset) break;
    }
    return null;
}

fn nextEmojiBoundary(bytes: []const u8, byte_offset: usize) ?usize {
    const offset = @min(byte_offset, bytes.len);
    var index: usize = 0;
    while (nextEmojiCluster(bytes, &index)) |cluster| {
        if (cluster.start <= offset and offset < cluster.end) return cluster.end;
        if (cluster.start > offset) break;
    }
    return null;
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

fn isFastSingleBytePreviousBoundary(text: []const u8, offset: usize) bool {
    const bounded = @min(offset, text.len);
    if (bounded == 0) return false;
    const byte = text[bounded - 1];
    return byte < 0x80 and byte != '\r' and byte != '\n';
}

fn isFastSingleByteNextBoundary(text: []const u8, offset: usize) bool {
    if (offset >= text.len) return false;
    const byte = text[offset];
    return byte < 0x80 and byte != '\r' and byte != '\n';
}

fn boundaryWindow(text: []const u8, byte_offset: usize) BoundaryWindow {
    const offset = @min(byte_offset, text.len);
    var start = offset -| boundary_context_bytes;
    if (std.mem.lastIndexOfScalar(u8, text[start..offset], '\n')) |newline| {
        start += newline + 1;
    }
    start = utf8StartAtOrBefore(text, start);

    var end = @min(text.len, offset + boundary_context_bytes);
    if (std.mem.indexOfScalar(u8, text[offset..end], '\n')) |newline| {
        end = offset + newline;
    }
    end = utf8EndAtOrAfter(text, end);
    if (end <= start) end = @min(text.len, nextCodepoint(text, start));
    return .{ .start = start, .end = end };
}

fn utf8StartAtOrBefore(text: []const u8, offset: usize) usize {
    var result = @min(offset, text.len);
    while (result > 0 and result < text.len and (text[result] & 0xc0) == 0x80) result -= 1;
    return result;
}

fn utf8EndAtOrAfter(text: []const u8, offset: usize) usize {
    var result = @min(offset, text.len);
    while (result < text.len and (text[result] & 0xc0) == 0x80) result += 1;
    return result;
}

fn previousEmojiBoundaryNear(bytes: []const u8, byte_offset: usize) ?usize {
    const window = boundaryWindow(bytes, byte_offset);
    if (previousEmojiBoundary(bytes[window.start..window.end], byte_offset - window.start)) |boundary| {
        return window.start + boundary;
    }
    return null;
}

fn nextEmojiBoundaryNear(bytes: []const u8, byte_offset: usize) ?usize {
    const window = boundaryWindow(bytes, byte_offset);
    if (nextEmojiBoundary(bytes[window.start..window.end], byte_offset - window.start)) |boundary| {
        return window.start + boundary;
    }
    return null;
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

const SymbolOverlay = struct {
    range: ByteRange,
    kind: SymbolOverlayKind,
};

const SymbolOverlayKind = enum {
    square_outline,
    square_filled,
    small_square_outline,
    small_square_filled,
    triangle_up,
    triangle_down,
    triangle_left,
    triangle_right,
    triangle_up_outline,
    triangle_down_outline,
    triangle_left_outline,
    triangle_right_outline,
};

fn nextSymbolOverlay(text: []const u8, index: *usize) ?SymbolOverlay {
    while (index.* < text.len) {
        const start = index.*;
        const codepoint = nextCodepointValue(text, index) orelse return null;
        const kind = symbolOverlayKindForCodepoint(codepoint) orelse continue;
        return .{ .range = .{ .start = start, .end = index.* }, .kind = kind };
    }
    return null;
}

fn symbolOverlayKindForCodepoint(codepoint: u21) ?SymbolOverlayKind {
    return switch (codepoint) {
        0x25a0 => .square_filled, // BLACK SQUARE
        0x25a1, 0x25a2 => .square_outline, // WHITE SQUARE, WHITE SQUARE WITH ROUNDED CORNERS
        0x25aa => .small_square_filled, // BLACK SMALL SQUARE
        0x25ab => .small_square_outline, // WHITE SMALL SQUARE
        0x25b2, 0x25b4, 0x25b6, 0x25b8, 0x25ba, 0x25bc, 0x25be, 0x25c0, 0x25c2, 0x25c4 => |cp| switch (cp) {
            0x25b2, 0x25b4 => .triangle_up,
            0x25b6, 0x25b8, 0x25ba => .triangle_right,
            0x25bc, 0x25be => .triangle_down,
            0x25c0, 0x25c2, 0x25c4 => .triangle_left,
            else => unreachable,
        },
        0x25b3, 0x25b5, 0x25b7, 0x25b9, 0x25bd, 0x25bf, 0x25c1, 0x25c3 => |cp| switch (cp) {
            0x25b3, 0x25b5 => .triangle_up_outline,
            0x25b7, 0x25b9 => .triangle_right_outline,
            0x25bd, 0x25bf => .triangle_down_outline,
            0x25c1, 0x25c3 => .triangle_left_outline,
            else => unreachable,
        },
        else => null,
    };
}

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

test "emoji safe layout text preserves byte offsets" {
    if (!emojiOverlayEnabled()) return;

    const safe = (try overlaySafeLayoutText(std.testing.allocator, "a😂b")).?;
    defer std.testing.allocator.free(safe);

    try std.testing.expectEqualStrings("a    b", safe);
}

test "symbol safe layout text preserves byte offsets" {
    const text = "a▫▼b";
    const safe = (try overlaySafeLayoutText(std.testing.allocator, text)).?;
    defer std.testing.allocator.free(safe);

    try std.testing.expectEqual(text.len, safe.len);
    try std.testing.expectEqualStrings("a\u{2007}\u{2007}b", safe);
}

test "text analysis detects emoji and cjk in one scan" {
    const plain = analyzeText("Shellowo");
    try std.testing.expect(!plain.has_emoji);
    try std.testing.expect(!plain.has_cjk_baseline);
    try std.testing.expect(!plain.has_symbol_overlay);

    const mixed = analyzeText("连接 😊");
    try std.testing.expect(mixed.has_emoji);
    try std.testing.expect(mixed.has_cjk_baseline);
    try std.testing.expect(!mixed.has_symbol_overlay);
}

test "text analysis detects symbol overlays" {
    const square = analyzeText("▫");
    try std.testing.expect(square.has_symbol_overlay);

    const triangle = analyzeText("▼");
    try std.testing.expect(triangle.has_symbol_overlay);
}

test "symbol overlay scanner maps geometric shapes" {
    var index: usize = 0;
    const first = nextSymbolOverlay("a▫▼", &index).?;
    try std.testing.expectEqual(SymbolOverlayKind.small_square_outline, first.kind);
    const second = nextSymbolOverlay("a▫▼", &index).?;
    try std.testing.expectEqual(SymbolOverlayKind.triangle_down, second.kind);
    try std.testing.expectEqual(@as(?SymbolOverlay, null), nextSymbolOverlay("a▫▼", &index));
}

test "measure cache only accepts short unwrapped text" {
    var options: dvui.Font.TextSizeOptions = .{};
    try std.testing.expect(measureCacheEligible("连接", options));

    options.max_width = 120;
    try std.testing.expect(!measureCacheEligible("连接", options));

    options.max_width = null;
    const long = "a" ** (max_measure_cache_text_bytes + 1);
    try std.testing.expect(!measureCacheEligible(long, options));
}

test "emoji boundaries treat utf8 emoji as one cluster" {
    const text = "a😂b";

    try std.testing.expectEqual(@as(?usize, 1), previousEmojiBoundary(text, 5));
    try std.testing.expectEqual(@as(?usize, 5), nextEmojiBoundary(text, 1));
    try std.testing.expectEqual(@as(?usize, null), previousEmojiBoundary(text, 1));
    try std.testing.expectEqual(@as(?usize, null), nextEmojiBoundary(text, 5));
}

test "near emoji boundaries do not require scanning from the beginning" {
    const prefix = "0123456789" ** 80;
    const text = prefix ++ "a😂b";
    const emoji_start = prefix.len + 1;
    const emoji_end = emoji_start + "😂".len;

    try std.testing.expectEqual(@as(?usize, emoji_start), previousEmojiBoundaryNear(text, emoji_end));
    try std.testing.expectEqual(@as(?usize, emoji_end), nextEmojiBoundaryNear(text, emoji_start));
}

test "boundary window is local and utf8 aligned" {
    const text = ("a" ** 600) ++ "你" ++ ("b" ** 600);
    const offset = 600 + "你".len;
    const window = boundaryWindow(text, offset);

    try std.testing.expect(window.start > 0);
    try std.testing.expect(window.end < text.len);
    try std.testing.expectEqual(@as(usize, 600), previousCodepoint(text, offset));
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
