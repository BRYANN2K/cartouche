#include <windows.h>
#include <stdio.h>
static FILE *lg; static HWND wnd; static int minimizes;
static void note(const char *fmt, ...) {
  SYSTEMTIME t; GetLocalTime(&t); va_list a; va_start(a, fmt);
  fprintf(lg, "%02d:%02d:%02d.%03d ", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
  vfprintf(lg, fmt, a); fputc('\n', lg); fflush(lg); va_end(a);
}
static LRESULT CALLBACK proc(HWND h, UINT m, WPARAM w, LPARAM l) {
  switch (m) {
  case WM_ACTIVATEAPP: note("ACTIVATEAPP %d", (int)w);
    if (!w) { minimizes++; note("MINIMIZE #%d", minimizes); ShowWindow(h, SW_MINIMIZE); } return 0;
  case WM_ACTIVATE: note("ACTIVATE %d", LOWORD(w)); break;
  case WM_SETFOCUS: note("SETFOCUS"); break;
  case WM_KILLFOCUS: note("KILLFOCUS"); break;
  case WM_SIZE: if (w == SIZE_MINIMIZED) note("SIZE minimized"); else if (w == SIZE_RESTORED) note("SIZE restored"); break;
  case WM_PAINT: { PAINTSTRUCT ps; HDC dc = BeginPaint(h, &ps); RECT r; GetClientRect(h, &r);
    HBRUSH b = CreateSolidBrush(RGB(30, 60, 120)); FillRect(dc, &r, b); DeleteObject(b);
    char s[64]; sprintf(s, "focus probe  minimizes=%d", minimizes); SetBkMode(dc, TRANSPARENT); SetTextColor(dc, RGB(255,255,255));
    TextOutA(dc, 40, 40, s, lstrlenA(s)); EndPaint(h, &ps); return 0; }
  case WM_TIMER: InvalidateRect(h, NULL, FALSE); return 0;
  case WM_KEYDOWN: if (w == VK_F10) DestroyWindow(h); return 0;
  case WM_DESTROY: note("EXIT minimizes=%d", minimizes); PostQuitMessage(0); return 0;
  }
  return DefWindowProcA(h, m, w, l);
}
static RECT mr; static int found;
static BOOL CALLBACK pick(HMONITOR m, HDC d, LPRECT r, LPARAM p) {
  MONITORINFO mi = { sizeof mi }; GetMonitorInfoA(m, &mi);
  note("seen %ld,%ld %ldx%ld primary=%d", mi.rcMonitor.left, mi.rcMonitor.top, mi.rcMonitor.right - mi.rcMonitor.left, mi.rcMonitor.bottom - mi.rcMonitor.top, (int)(mi.dwFlags & MONITORINFOF_PRIMARY));
  if (!found || !(mi.dwFlags & MONITORINFOF_PRIMARY)) { mr = mi.rcMonitor; found = 1; }
  return TRUE;
}
int WINAPI WinMain(HINSTANCE i, HINSTANCE p, LPSTR c, int s) {
  lg = fopen("C:\\focus-probe.log", "a"); note("START");
  WNDCLASSA wc = {0}; wc.lpfnWndProc = proc; wc.hInstance = i; wc.lpszClassName = "FocusProbe"; wc.hCursor = LoadCursor(NULL, IDC_ARROW);
  RegisterClassA(&wc);
  EnumDisplayMonitors(NULL, NULL, pick, 0);
  note("monitor %ld,%ld %ldx%ld", mr.left, mr.top, mr.right - mr.left, mr.bottom - mr.top);
  wnd = CreateWindowExA(WS_EX_APPWINDOW, "FocusProbe", "Focus Probe", WS_POPUP | WS_VISIBLE, mr.left, mr.top, mr.right - mr.left, mr.bottom - mr.top, NULL, NULL, i, NULL);
  SetTimer(wnd, 1, 100, NULL); SetForegroundWindow(wnd);
  MSG m; while (GetMessageA(&m, NULL, 0, 0) > 0) { TranslateMessage(&m); DispatchMessageA(&m); }
  return 0;
}
