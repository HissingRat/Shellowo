const dvui = @import("dvui");

const workspace = @import("../../core/workspace.zig");
const theme = @import("../theme.zig");

pub const Options = struct {
    id_extra: usize,
};

pub fn show(tab: workspace.WorkspaceTab, palette: theme.Palette, opts: Options) void {
    var panel = dvui.box(@src(), .{ .dir = .vertical }, theme.panel(.{
        .expand = .both,
        .padding = .{ .x = 12, .y = 10, .w = 12, .h = 10 },
        .id_extra = opts.id_extra,
    }, palette).override(.{
        .color_fill = palette.app_bg,
        .color_border = palette.border_subtle,
    }));
    defer panel.deinit();

    const transcript = if (tab.status == .connected)
        "Connecting host...\nConnection accepted\nLinux debian 6.12.86 #1 SMP PREEMPT_DYNAMIC x86_64\n\nThe programs included with the Debian GNU/Linux system are free software;\nthe exact distribution terms for each program are described in the\nindividual files in /usr/share/doc/*/copyright.\n\nLast login: Fri Jun  5 09:49:31 2026 from 127.0.0.1\nstoffel@debian:~$ "
    else
        "Session is not connected yet.\n";

    terminalText(transcript, palette, opts.id_extra + 1);
}

fn terminalText(text: []const u8, palette: theme.Palette, id_extra: usize) void {
    var host = dvui.box(@src(), .{}, theme.panel(.{
        .expand = .both,
        .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .corner_radius = .all(0),
        .id_extra = id_extra,
    }, palette).override(.{
        .color_fill = palette.app_bg,
        .color_border = palette.border_subtle,
    }));
    defer host.deinit();

    dvui.labelNoFmt(@src(), text, .{ .align_x = 0, .align_y = 0 }, .{
        .font = theme.textFont(text, 11),
        .color_text = palette.text,
        .padding = .all(0),
        .id_extra = id_extra + 1,
    });
}
