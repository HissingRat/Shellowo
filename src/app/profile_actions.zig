pub fn select(app: anytype, id: u64) void {
    app.selected_profile_id = id;
    if (app.profiles.get(id)) |item| {
        app.draft.load(item.*);
        app.message = "Profile selected";
    }
}

pub fn create(app: anytype) void {
    app.selected_profile_id = null;
    app.draft.reset();
    app.show_config = true;
    app.message = "New profile";
}

pub fn edit(app: anytype, id: u64) void {
    select(app, id);
    app.show_config = true;
}

pub fn cancel(app: anytype) void {
    if (app.selected_profile_id) |id| {
        if (app.profiles.get(id)) |item| app.draft.load(item.*);
    } else {
        app.draft.reset();
    }
    app.show_config = false;
    app.message = "Home";
}
