const std = @import("std");
const dvui = @import("dvui");

const c = dvui.backend.c;

pub const System = struct {
    allocator: std.mem.Allocator,
    renderer: *c.SDL_Renderer,
    engine: *c.TTF_TextEngine,
    font_sources: FontSources,
    fonts: std.AutoHashMapUnmanaged(u64, Face) = .empty,
    layouts: std.AutoHashMapUnmanaged(u64, *c.TTF_Text) = .empty,

    pub const FontSources = struct {
        regular: []const u8,
        bold: []const u8,
        italic: []const u8,
        cjk: []const u8,
    };

    const Face = struct {
        primary: *c.TTF_Font,
        fallback: ?*c.TTF_Font,
    };

    const Layout = struct {
        text: *c.TTF_Text,
        cached: bool,

        fn release(self: Layout) void {
            if (!self.cached) c.TTF_DestroyText(self.text);
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
        };
    }

    pub fn deinit(self: *System) void {
        self.clearLayouts();
        self.layouts.deinit(self.allocator);
        var it = self.fonts.valueIterator();
        while (it.next()) |face| {
            c.TTF_CloseFont(face.primary);
            if (face.fallback) |fallback| c.TTF_CloseFont(fallback);
        }
        self.fonts.deinit(self.allocator);
        c.TTF_DestroyRendererTextEngine(self.engine);
        c.TTF_Quit();
        self.* = undefined;
    }

    pub fn dvuiEngine(self: *System) dvui.TextEngine {
        return .{ .context = self, .vtable = &vtable };
    }

    fn faceFor(self: *System, font: dvui.Font, scale: f32) ?Face {
        const physical_size = @max(1, font.size * safeScale(scale));
        var hasher = std.hash.Wyhash.init(font.hash());
        hasher.update(std.mem.asBytes(&physical_size));
        const key = hasher.final();
        if (self.fonts.get(key)) |face| return face;

        const family = font.familyName();
        const cjk_primary = std.mem.eql(u8, family, "Noto Sans CJK SC");
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

        var fallback: ?*c.TTF_Font = null;
        if (!cjk_primary) {
            fallback = openFont(self.font_sources.cjk, physical_size);
            if (fallback) |fallback_font| {
                applyFontStyle(fallback_font, font);
                if (!c.TTF_AddFallbackFont(primary, fallback_font)) {
                    c.TTF_CloseFont(fallback_font);
                    fallback = null;
                }
            }
        }

        const face: Face = .{ .primary = primary, .fallback = fallback };
        self.fonts.put(self.allocator, key, face) catch {
            if (fallback) |fallback_font| c.TTF_CloseFont(fallback_font);
            c.TTF_CloseFont(primary);
            return null;
        };
        return face;
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
                return .{ .text = cached, .cached = true };
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
            if (self.layouts.count() >= 2048) self.clearLayouts();
            self.layouts.put(self.allocator, key, result) catch
                return .{ .text = result, .cached = false };
            return .{ .text = result, .cached = true };
        }
        return .{ .text = result, .cached = false };
    }

    fn clearLayouts(self: *System) void {
        var it = self.layouts.valueIterator();
        while (it.next()) |text| c.TTF_DestroyText(text.*);
        self.layouts.clearRetainingCapacity();
    }

    fn measure(
        context: *anyopaque,
        font: dvui.Font,
        text: []const u8,
        options: dvui.Font.TextSizeOptions,
    ) dvui.Size {
        const self: *System = @ptrCast(@alignCast(context));
        const scale = currentScale();
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
        if (options.max_width) |max_width| {
            const point_x: c_int = @intFromFloat(@max(0, @round(max_width * scale)));
            var substring: c.TTF_SubString = undefined;
            if (c.TTF_GetTextSubStringForPoint(layout_text, point_x, @divTrunc(height_px, 2), &substring)) {
                end = boundaryForPoint(substring, point_x, options.end_metric);
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
            caretXPhysical(layout_text, end)
        else
            @as(f32, @floatFromInt(width_px));
        return .{
            .w = measured_width_px / scale,
            .h = @as(f32, @floatFromInt(height_px)) / scale,
        };
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

        if (options.background_color) |background| {
            var w: c_int = 0;
            var h: c_int = 0;
            if (c.TTF_GetTextSize(text, &w, &h)) {
                (dvui.Rect.Physical{
                    .x = start.x,
                    .y = start.y,
                    .w = @floatFromInt(w),
                    .h = @floatFromInt(h),
                }).fill(.{}, .{ .color = background, .fade = 0 });
            }
        }

        const sel_start = @min(options.sel_start orelse 0, options.text.len);
        const sel_end = @min(options.sel_end orelse 0, options.text.len);
        if (sel_start < sel_end) {
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

        if (!c.TTF_DrawRendererText(text, start.x, start.y)) return error.SdlTtfDrawFailed;
    }

    fn caretX(
        context: *anyopaque,
        font: dvui.Font,
        text: []const u8,
        byte_offset: usize,
    ) f32 {
        const self: *System = @ptrCast(@alignCast(context));
        const scale = currentScale();
        const shaped = self.layout(font, text, scale, null) orelse return 0;
        defer shaped.release();
        const layout_text = shaped.text;
        return caretXPhysical(layout_text, byte_offset) / scale;
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
        const shaped = self.layout(font, text, scale, wrap_width) orelse return .{};
        defer shaped.release();
        const layout_text = shaped.text;

        var substring: c.TTF_SubString = undefined;
        if (!c.TTF_GetTextSubString(layout_text, @intCast(byte_offset), &substring)) return .{};
        const rtl = (substring.flags & c.TTF_SUBSTRING_DIRECTION_MASK) == c.TTF_DIRECTION_RTL;
        const at_start = byte_offset <= @as(usize, @intCast(@max(0, substring.offset)));
        const x_px = if (at_start)
            (if (rtl) substring.rect.x + substring.rect.w else substring.rect.x)
        else
            (if (rtl) substring.rect.x else substring.rect.x + substring.rect.w);
        return .{
            .x = @as(f32, @floatFromInt(x_px)) / scale,
            .y = @as(f32, @floatFromInt(substring.rect.y)) / scale,
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
};

const vtable: dvui.TextEngine.VTable = .{
    .measure = System.measure,
    .render = System.render,
    .caret_x = System.caretX,
    .caret_point = System.caretPoint,
    .previous_boundary = System.previousBoundary,
    .next_boundary = System.nextBoundary,
};

fn openFont(bytes: []const u8, size: f32) ?*c.TTF_Font {
    const io = c.SDL_IOFromConstMem(bytes.ptr, bytes.len) orelse return null;
    return c.TTF_OpenFontIO(io, true, size);
}

fn applyFontStyle(font: *c.TTF_Font, requested: dvui.Font) void {
    var style: c.TTF_FontStyleFlags = c.TTF_STYLE_NORMAL;
    if (requested.weight == .bold) style |= c.TTF_STYLE_BOLD;
    if (requested.style == .italic) style |= c.TTF_STYLE_ITALIC;
    if (requested.underline != null) style |= c.TTF_STYLE_UNDERLINE;
    if (requested.strike != null) style |= c.TTF_STYLE_STRIKETHROUGH;
    c.TTF_SetFontStyle(font, style);
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

fn nextCodepoint(text: []const u8, offset: usize) usize {
    if (offset >= text.len) return text.len;
    return @min(text.len, offset + (std.unicode.utf8ByteSequenceLength(text[offset]) catch 1));
}

test "fallback boundaries preserve UTF-8 codepoints" {
    const text = "a你🙂z";
    try std.testing.expectEqual(@as(usize, 1), previousCodepoint(text, 4));
    try std.testing.expectEqual(@as(usize, 4), previousCodepoint(text, 8));
    try std.testing.expectEqual(@as(usize, 4), nextCodepoint(text, 1));
    try std.testing.expectEqual(@as(usize, 8), nextCodepoint(text, 4));
}

test "firstLine reports the consumed newline" {
    const line = firstLine("abc\n下一行");
    try std.testing.expectEqualStrings("abc", line.bytes);
    try std.testing.expect(line.has_newline);
}
