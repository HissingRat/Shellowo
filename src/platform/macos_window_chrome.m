#import <Cocoa/Cocoa.h>

static void shellowo_move_window_button(NSButton *button,
                                        CGFloat horizontal_offset,
                                        CGFloat vertical_offset) {
  if (button == nil) {
    return;
  }

  NSPoint origin = button.frame.origin;
  origin.x += horizontal_offset;
  origin.y -= vertical_offset;
  [button setFrameOrigin:origin];
}

static void shellowo_position_traffic_lights(NSWindow *window,
                                             CGFloat horizontal_offset,
                                             CGFloat vertical_offset) {
  [window.contentView.superview layoutSubtreeIfNeeded];

  NSButton *close_button = [window standardWindowButton:NSWindowCloseButton];
  NSButton *minimize_button =
      [window standardWindowButton:NSWindowMiniaturizeButton];
  NSButton *zoom_button = [window standardWindowButton:NSWindowZoomButton];
  shellowo_move_window_button(close_button, horizontal_offset,
                              vertical_offset);
  shellowo_move_window_button(minimize_button, horizontal_offset,
                              vertical_offset);
  shellowo_move_window_button(zoom_button, horizontal_offset, vertical_offset);
}

static void shellowo_configure_titlebar(NSWindow *window) {
  window.titleVisibility = NSWindowTitleHidden;
  window.titlebarAppearsTransparent = YES;
  window.styleMask |= NSWindowStyleMaskFullSizeContentView;
  window.movableByWindowBackground = NO;
  window.tabbingMode = NSWindowTabbingModeDisallowed;
  window.title = @"";

  NSView *content_view = window.contentView;
  NSView *frame_view = content_view.superview;
  if (content_view != nil && frame_view != nil) {
    content_view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    content_view.frame = frame_view.bounds;
  }

  NSButton *close_button = [window standardWindowButton:NSWindowCloseButton];
  NSButton *minimize_button =
      [window standardWindowButton:NSWindowMiniaturizeButton];
  NSButton *zoom_button = [window standardWindowButton:NSWindowZoomButton];
  close_button.hidden = NO;
  minimize_button.hidden = NO;
  zoom_button.hidden = NO;
}

void shellowo_macos_configure_titlebar(void *window_pointer) {
  NSWindow *window = (__bridge NSWindow *)window_pointer;
  if (window == nil) {
    return;
  }

  shellowo_configure_titlebar(window);
}

void shellowo_macos_position_traffic_lights(void *window_pointer,
                                            double horizontal_offset,
                                            double vertical_offset) {
  NSWindow *window = (__bridge NSWindow *)window_pointer;
  if (window == nil) {
    return;
  }

  // Showing the SDL window triggers another AppKit titlebar layout pass. Apply
  // the offset on the next main-loop turn so that pass cannot overwrite it.
  dispatch_async(dispatch_get_main_queue(), ^{
    shellowo_position_traffic_lights(window, (CGFloat)horizontal_offset,
                                     (CGFloat)vertical_offset);
  });
}

void shellowo_macos_refresh_titlebar(void *window_pointer,
                                     double horizontal_offset,
                                     double vertical_offset) {
  NSWindow *window = (__bridge NSWindow *)window_pointer;
  if (window == nil) {
    return;
  }

  // Zoom, restore and fullscreen transitions rebuild AppKit's frame view.
  // Reapply the full-size content configuration after that layout settles.
  dispatch_async(dispatch_get_main_queue(), ^{
    shellowo_configure_titlebar(window);
    [window.contentView.superview setNeedsLayout:YES];
    [window.contentView.superview layoutSubtreeIfNeeded];

    dispatch_async(dispatch_get_main_queue(), ^{
      shellowo_configure_titlebar(window);
      shellowo_position_traffic_lights(window, (CGFloat)horizontal_offset,
                                       (CGFloat)vertical_offset);
    });
  });
}
