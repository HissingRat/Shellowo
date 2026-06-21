#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dwmapi.h>

void shellowo_windows_configure_chrome(void *window_pointer) {
  HWND window = (HWND)window_pointer;
  if (window == NULL) {
    return;
  }

  LONG_PTR style = GetWindowLongPtrW(window, GWL_STYLE);
  style |= WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_SYSMENU;
  style &= ~WS_CAPTION;
  SetWindowLongPtrW(window, GWL_STYLE, style);

  enum DWMNCRENDERINGPOLICY policy = DWMNCRP_ENABLED;
  DwmSetWindowAttribute(window, DWMWA_NCRENDERING_POLICY, &policy,
                        sizeof(policy));

  MARGINS margins = {1, 1, 1, 1};
  DwmExtendFrameIntoClientArea(window, &margins);

  SetWindowPos(window, NULL, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                   SWP_FRAMECHANGED);
}
