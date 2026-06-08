const dvui = @import("dvui");

const terminal_slot = @import("../../core/terminal_slot.zig");
const theme = @import("../theme.zig");

const bar_height: f32 = 22;
const chip_height: f32 = 20;
const chip_min_width: f32 = 58;
const chip_max_width: f32 = 132;
const chip_margin_width: f32 = 4;
const side_button_width: f32 = 20;
const side_button_margin_width: f32 = 8;
const font_size: f32 = 9;
const menu_item_height: f32 = 18;

pub const Action = union(enum) {
    activate: terminal_slot.TerminalSlotId,
    close: terminal_slot.TerminalSlotId,
    create,
};

pub const Options = struct {
    id_extra: usize,
    active_slot_id: ?terminal_slot.TerminalSlotId = null,
};

pub fn show(slots: []const terminal_slot.TerminalSlotSummary, palette: theme.Palette, opts: Options) ?Action {
    var action: ?Action = null;

    var bar = dvui.box(@src(), .{ .dir = .horizontal }, theme.panel(.{
        .expand = .horizontal,
        .min_size_content = .height(bar_height),
        .max_size_content = .height(bar_height),
        .padding = .{ .x = 8, .y = 2, .w = 8, .h = 2 },
        .id_extra = opts.id_extra,
    }, palette).override(.{
        .color_fill = palette.app_bg,
        .color_border = palette.border_subtle,
    }));
    defer bar.deinit();

    const active_slot_id = opts.active_slot_id orelse firstSlotId(slots);
    const content_rs = bar.data().contentRectScale();
    const visible_count = visibleSlotCount(slots, active_slot_id, content_rs.r.w / content_rs.s);
    const overflow = visible_count < slots.len;
    const overflow_open = dvui.dataGetPtrDefault(null, bar.data().id, "overflow_open", bool, false);

    for (0..visible_count) |i| {
        const slot = orderedSlot(slots, active_slot_id, i) orelse break;
        if (slotChip(slot, palette, active_slot_id, opts.id_extra + 10 + i)) |slot_action| {
            action = slot_action;
        }
    }

    flexSpacer(opts.id_extra + 180);
    if (overflow) {
        const dropdown = overflowButton(palette, opts.id_extra + 190);
        if (dropdown.clicked) overflow_open.* = !overflow_open.*;
        if (overflow_open.*) {
            if (overflowMenu(slots, active_slot_id, visible_count, dropdown.rect, overflow_open, palette, opts.id_extra + 300)) |slot_id| {
                action = .{ .activate = slot_id };
                overflow_open.* = false;
            }
        }
    } else {
        overflow_open.* = false;
    }

    if (addButton(palette, opts.id_extra + 200)) action = .create;
    return action;
}

fn slotChip(slot: terminal_slot.TerminalSlotSummary, palette: theme.Palette, active_slot_id: ?terminal_slot.TerminalSlotId, id_extra: usize) ?Action {
    var label_buf: [64]u8 = undefined;
    const label = slot.fallbackLabel(&label_buf);
    const active = active_slot_id != null and active_slot_id.? == slot.id;
    const chip_width = labelWidth(label);
    var action: ?Action = null;

    var chip = dvui.box(@src(), .{}, .{
        .min_size_content = .{ .w = chip_width, .h = chip_height },
        .max_size_content = .{ .w = chip_width, .h = chip_height },
        .padding = .{ .y = 1, .h = 1 },
        .margin = .{ .x = 2, .w = 2 },
        .id_extra = id_extra,
    });
    defer chip.deinit();

    const chip_rect = chip.data().rectScale().r;
    if (theme.button(@src(), label, .{
        .expand = .both,
        .padding = .{ .x = 8, .y = 1, .w = 8, .h = 1 },
        .corner_radius = .all(3),
        .id_extra = id_extra + 1,
        .margin = .all(0),
    }, palette, .{
        .variant = .ghost,
        .state = if (active) .selected else .normal,
        .font_size = font_size,
    })) {
        action = .{ .activate = slot.id };
    }

    if (slotContextMenu(slot.id, chip_rect, palette, id_extra + 20)) |_| {
        action = .{ .close = slot.id };
    }

    return action;
}

fn addButton(palette: theme.Palette, id_extra: usize) bool {
    return theme.button(@src(), "+", .{
        .min_size_content = .{ .w = side_button_width, .h = chip_height },
        .max_size_content = .{ .w = side_button_width, .h = chip_height },
        .padding = .all(0),
        .margin = .{ .x = 4, .y = 1 },
        .corner_radius = .all(3),
        .color_fill = palette.surface_bg,
        .color_border = palette.border_subtle,
        .id_extra = id_extra,
    }, palette, .{ .variant = .ghost, .font_size = font_size });
}

fn firstSlotId(slots: []const terminal_slot.TerminalSlotSummary) ?terminal_slot.TerminalSlotId {
    if (slots.len == 0) return null;
    return slots[0].id;
}

fn labelWidth(label: []const u8) f32 {
    const rough_width = @as(f32, @floatFromInt(label.len)) * 7 + 22;
    return @min(chip_max_width, @max(chip_min_width, rough_width));
}

fn slotOuterWidth(slot: terminal_slot.TerminalSlotSummary) f32 {
    var label_buf: [64]u8 = undefined;
    return labelWidth(slot.fallbackLabel(&label_buf)) + chip_margin_width;
}

fn sideButtonOuterWidth() f32 {
    return side_button_width + side_button_margin_width;
}

fn visibleSlotCount(slots: []const terminal_slot.TerminalSlotSummary, active_slot_id: ?terminal_slot.TerminalSlotId, content_width: f32) usize {
    if (slots.len == 0) return 0;

    var all_width = sideButtonOuterWidth();
    for (0..slots.len) |i| {
        const slot = orderedSlot(slots, active_slot_id, i) orelse break;
        all_width += slotOuterWidth(slot);
    }
    if (all_width <= content_width) return slots.len;

    const available = @max(0, content_width - sideButtonOuterWidth() * 2);
    var used: f32 = 0;
    var count: usize = 0;
    for (0..slots.len) |i| {
        const slot = orderedSlot(slots, active_slot_id, i) orelse break;
        const width = slotOuterWidth(slot);
        if (count > 0 and used + width > available) break;
        used += width;
        count += 1;
    }
    return @max(@as(usize, 1), count);
}

fn orderedSlot(slots: []const terminal_slot.TerminalSlotSummary, active_slot_id: ?terminal_slot.TerminalSlotId, order_index: usize) ?terminal_slot.TerminalSlotSummary {
    if (slots.len == 0) return null;
    if (active_slot_id) |active_id| {
        if (slotById(slots, active_id)) |active| {
            if (order_index == 0) return active;
            var seen: usize = 1;
            for (slots) |slot| {
                if (slot.id == active_id) continue;
                if (seen == order_index) return slot;
                seen += 1;
            }
            return null;
        }
    }
    if (order_index >= slots.len) return null;
    return slots[order_index];
}

fn slotById(slots: []const terminal_slot.TerminalSlotSummary, slot_id: terminal_slot.TerminalSlotId) ?terminal_slot.TerminalSlotSummary {
    for (slots) |slot| {
        if (slot.id == slot_id) return slot;
    }
    return null;
}

fn flexSpacer(id_extra: usize) void {
    var spacer = dvui.box(@src(), .{}, .{
        .expand = .horizontal,
        .min_size_content = .width(0),
        .padding = .all(0),
        .margin = .all(0),
        .id_extra = id_extra,
        .role = .none,
        .tab_index = 0,
    });
    defer spacer.deinit();
}

const OverflowButton = struct {
    clicked: bool = false,
    rect: dvui.Rect.Physical = .{},
};

fn overflowButton(palette: theme.Palette, id_extra: usize) OverflowButton {
    var wrapper = dvui.box(@src(), .{}, .{
        .min_size_content = .{ .w = side_button_width, .h = chip_height },
        .max_size_content = .{ .w = side_button_width, .h = chip_height },
        .padding = .all(0),
        .margin = .{ .x = 4, .y = 1 },
        .id_extra = id_extra,
    });
    defer wrapper.deinit();

    const rect = wrapper.data().rectScale().r;
    const clicked = theme.button(@src(), "v", .{
        .expand = .both,
        .padding = .all(0),
        .margin = .all(0),
        .corner_radius = .all(3),
        .id_extra = id_extra + 1,
    }, palette, .{ .variant = .ghost, .font_size = font_size });
    return .{ .clicked = clicked, .rect = rect };
}

fn overflowMenu(slots: []const terminal_slot.TerminalSlotSummary, active_slot_id: ?terminal_slot.TerminalSlotId, visible_count: usize, button_rect: dvui.Rect.Physical, open: *bool, palette: theme.Palette, id_extra: usize) ?terminal_slot.TerminalSlotId {
    if (button_rect.empty()) return null;

    var menu = dvui.floatingMenu(@src(), .{ .from = button_rect.toNatural() }, slotContextMenuOptions(palette, id_extra));
    defer menu.deinit();

    if (outsideOverflowMenuClick(button_rect, menu.data().rectScale().r)) {
        menu.close();
        open.* = false;
        return null;
    }

    for (visible_count..slots.len) |i| {
        const slot = orderedSlot(slots, active_slot_id, i) orelse break;
        var label_buf: [64]u8 = undefined;
        const label = slot.fallbackLabel(&label_buf);
        if (slotContextMenuItem(label, palette, id_extra + 1 + i)) |_| {
            menu.close();
            return slot.id;
        }
    }
    return null;
}

fn outsideOverflowMenuClick(button_rect: dvui.Rect.Physical, menu_rect: dvui.Rect.Physical) bool {
    for (dvui.events()) |event| {
        if (event.handled or event.evt != .mouse) continue;
        const mouse = event.evt.mouse;
        if (mouse.action != .press or !mouse.button.pointer()) continue;
        if (button_rect.contains(mouse.p) or menu_rect.contains(mouse.p)) continue;
        return true;
    }
    return false;
}

fn slotContextMenu(slot_id: terminal_slot.TerminalSlotId, rect: dvui.Rect.Physical, palette: theme.Palette, id_extra: usize) ?terminal_slot.TerminalSlotId {
    if (rect.empty()) return null;

    const context = dvui.context(@src(), .{ .rect = rect }, .{ .id_extra = id_extra });
    defer context.deinit();

    const active_point = context.activePoint() orelse return null;
    var menu = dvui.floatingMenu(@src(), .{ .from = .fromPoint(active_point) }, slotContextMenuOptions(palette, id_extra + 1));
    defer menu.deinit();

    if (slotContextMenuItem("Close", palette, id_extra + 2)) |_| {
        menu.close();
        return slot_id;
    }
    return null;
}

fn slotContextMenuOptions(palette: theme.Palette, id_extra: usize) dvui.Options {
    return .{
        .id_extra = id_extra,
        .background = true,
        .color_fill = palette.app_bg,
        .color_border = palette.border,
        .color_text = palette.text,
        .border = .all(1),
        .padding = .all(0),
        .corner_radius = .all(3),
    };
}

fn slotContextMenuItem(label: []const u8, palette: theme.Palette, id_extra: usize) ?dvui.Rect.Natural {
    return dvui.menuItemLabel(@src(), label, .{}, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .background = true,
        .font = theme.textFont(label, font_size),
        .color_fill = dvui.Color.transparent,
        .color_fill_hover = palette.surface_active,
        .color_fill_press = palette.active_bg,
        .color_text = palette.text,
        .color_text_hover = palette.text,
        .color_text_press = palette.text,
        .padding = .{ .x = 2, .y = 2, .w = 2, .h = 0 },
        .min_size_content = .{ .h = menu_item_height },
        .corner_radius = .all(3),
    });
}
