const dvui = @import("dvui");

const remote_file = @import("../../../core/remote_file.zig");
const theme = @import("../../theme.zig");

pub const EntryOptions = struct {
    rect: dvui.Rect.Physical,
    can_mutate: bool,
    capabilities: remote_file.FilePaneCapabilities,
    kind: remote_file.RemoteFileKind,
    entry_busy: bool,
    path_busy: bool,
    id_extra: usize,
};

pub const BlankOptions = struct {
    rect: dvui.Rect.Physical,
    can_mutate: bool,
    capabilities: remote_file.FilePaneCapabilities,
    path_busy: bool,
    id_extra: usize,
};

pub const EntryAction = struct {
    kind: Kind,
    anchor: dvui.Point.Natural = .{},

    pub const Kind = enum {
        new_file,
        new_folder,
        rename,
        delete,
        edit,
        download,
        upload,
        upload_folder,
        refresh,
        details,
    };
};

pub const BlankAction = enum {
    new_file,
    new_folder,
    upload,
    upload_folder,
    refresh,
};

pub const DeleteAction = enum {
    none,
    cancel,
    confirm,
};

pub fn entry(palette: theme.Palette, opts: EntryOptions) ?EntryAction {
    if (opts.rect.empty()) return null;

    const context = dvui.context(@src(), .{ .rect = opts.rect }, .{ .id_extra = opts.id_extra });
    defer context.deinit();

    const active_point = context.activePoint() orelse return null;
    var menu = dvui.floatingMenu(@src(), .{ .from = .fromPoint(active_point) }, menuOptions(palette, opts.id_extra + 1));
    defer menu.deinit();

    const can_change_path = opts.can_mutate and !opts.path_busy;
    const can_change_entry = can_change_path and !opts.entry_busy;
    if (menuItem("New File", can_change_path, palette, opts.id_extra + 2)) |_| return closeEntry(menu, .new_file, .{});
    if (menuItem("New Folder", can_change_path and opts.capabilities.can_create_directory, palette, opts.id_extra + 3)) |_| return closeEntry(menu, .new_folder, .{});
    if (menuItem("Rename", can_change_entry and opts.capabilities.can_rename, palette, opts.id_extra + 4)) |_| return closeEntry(menu, .rename, .{});
    if (menuItem("Delete", can_change_entry and opts.capabilities.can_delete, palette, opts.id_extra + 5)) |_| return closeEntry(menu, .delete, active_point);
    if (menuItem("Edit", can_change_entry and opts.capabilities.can_edit and opts.kind == .file, palette, opts.id_extra + 6)) |_| return closeEntry(menu, .edit, .{});
    if (menuItem("Download", opts.can_mutate and opts.capabilities.can_download and !opts.entry_busy, palette, opts.id_extra + 7)) |_| return closeEntry(menu, .download, .{});
    rowSeparator(palette, opts.id_extra + 20);
    if (menuItem("Upload", can_change_path and opts.capabilities.can_upload, palette, opts.id_extra + 8)) |_| return closeEntry(menu, .upload, .{});
    if (menuItem("Upload Folder", can_change_path and opts.capabilities.can_upload, palette, opts.id_extra + 9)) |_| return closeEntry(menu, .upload_folder, .{});
    rowSeparator(palette, opts.id_extra + 21);
    if (menuItem("Refresh", opts.capabilities.can_refresh, palette, opts.id_extra + 10)) |_| return closeEntry(menu, .refresh, .{});
    if (menuItem("Details", opts.can_mutate, palette, opts.id_extra + 11)) |_| return closeEntry(menu, .details, .{});
    return null;
}

pub fn blank(palette: theme.Palette, opts: BlankOptions) ?BlankAction {
    if (opts.rect.empty()) return null;

    const context = dvui.context(@src(), .{ .rect = opts.rect }, .{ .id_extra = opts.id_extra });
    defer context.deinit();

    const active_point = context.activePoint() orelse return null;
    var menu = dvui.floatingMenu(@src(), .{ .from = .fromPoint(active_point) }, menuOptions(palette, opts.id_extra + 1));
    defer menu.deinit();

    const can_change_path = opts.can_mutate and !opts.path_busy;
    if (menuItem("New File", can_change_path, palette, opts.id_extra + 2)) |_| return closeBlank(menu, .new_file);
    if (menuItem("New Folder", can_change_path and opts.capabilities.can_create_directory, palette, opts.id_extra + 3)) |_| return closeBlank(menu, .new_folder);
    rowSeparator(palette, opts.id_extra + 20);
    if (menuItem("Upload", can_change_path and opts.capabilities.can_upload, palette, opts.id_extra + 4)) |_| return closeBlank(menu, .upload);
    if (menuItem("Upload Folder", can_change_path and opts.capabilities.can_upload, palette, opts.id_extra + 5)) |_| return closeBlank(menu, .upload_folder);
    rowSeparator(palette, opts.id_extra + 21);
    if (menuItem("Refresh", opts.capabilities.can_refresh, palette, opts.id_extra + 6)) |_| return closeBlank(menu, .refresh);
    return null;
}

pub fn deleteConfirm(palette: theme.Palette, name: []const u8, anchor: dvui.Point.Natural, id_extra: usize) DeleteAction {
    var menu = dvui.floatingMenu(@src(), .{ .from = .fromPoint(anchor) }, deleteConfirmOptions(palette, id_extra));
    defer menu.deinit();

    dvui.label(@src(), "Delete {s}?", .{name}, .{
        .font = theme.textFont("Delete file?", 12),
        .color_text = palette.text,
        .expand = .horizontal,
        .min_size_content = .{ .w = 142, .h = 18 },
        .max_size_content = .height(18),
        .padding = .{ .x = 4, .y = 1, .w = 4, .h = 1 },
        .id_extra = id_extra + 1,
    });

    var actions = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = 3, .w = 0, .h = 0 },
        .id_extra = id_extra + 2,
    });
    defer actions.deinit();

    if (theme.button(@src(), "Cancel", .{
        .min_size_content = .{ .w = 62, .h = 19 },
        .id_extra = id_extra + 3,
    }, palette, .{ .variant = .ghost, .font_size = 12 })) {
        menu.close();
        return .cancel;
    }
    if (theme.button(@src(), "Delete", .{
        .min_size_content = .{ .w = 62, .h = 19 },
        .id_extra = id_extra + 4,
    }, palette, .{ .variant = .solid, .intent = .danger, .font_size = 12 })) {
        menu.close();
        return .confirm;
    }

    if (outsideClick(menu.data().rectScale().r)) {
        menu.close();
        return .cancel;
    }
    return .none;
}

fn closeEntry(menu: anytype, kind: EntryAction.Kind, anchor: dvui.Point.Natural) EntryAction {
    menu.close();
    return .{ .kind = kind, .anchor = anchor };
}

fn closeBlank(menu: anytype, action: BlankAction) BlankAction {
    menu.close();
    return action;
}

fn menuOptions(palette: theme.Palette, id_extra: usize) dvui.Options {
    return .{
        .id_extra = id_extra,
        .background = true,
        .color_fill = palette.popup_bg,
        .color_border = palette.border,
        .color_text = palette.text,
        .border = .all(1),
        .padding = .all(0),
        .corner_radius = .all(3),
    };
}

fn menuItem(label: []const u8, enabled: bool, palette: theme.Palette, id_extra: usize) ?dvui.Rect.Natural {
    return theme.menuItem(@src(), label, palette, .{
        .id_extra = id_extra,
        .font_size = 12,
        .enabled = enabled,
        .layout = .{
            .expand = .horizontal,
            .padding = .{ .x = 2, .y = 1, .w = 2, .h = 1 },
            .min_size_content = .{ .h = 17 },
            .corner_radius = .all(2),
        },
    });
}

fn rowSeparator(palette: theme.Palette, id_extra: usize) void {
    var sep = dvui.box(@src(), .{}, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .background = true,
        .color_fill = palette.border_subtle,
        .color_border = palette.border_subtle,
        .min_size_content = .height(1),
        .max_size_content = .height(1),
        .padding = .all(0),
        .margin = .{ .y = 2, .h = 2 },
    });
    defer sep.deinit();
}

fn deleteConfirmOptions(palette: theme.Palette, id_extra: usize) dvui.Options {
    return .{
        .id_extra = id_extra,
        .background = true,
        .color_fill = palette.popup_bg,
        .color_border = palette.border,
        .color_text = palette.text,
        .border = .all(1),
        .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
        .corner_radius = .all(3),
        .min_size_content = .{ .w = 156, .h = 48 },
    };
}

fn outsideClick(menu_rect: dvui.Rect.Physical) bool {
    if (menu_rect.empty()) return false;
    for (dvui.events()) |event| {
        if (event.handled or event.evt != .mouse) continue;
        const mouse = event.evt.mouse;
        if (mouse.action != .press or !mouse.button.pointer()) continue;
        if (menu_rect.contains(mouse.p)) continue;
        return true;
    }
    return false;
}
