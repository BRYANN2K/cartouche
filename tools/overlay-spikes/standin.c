// A D3D11 stand-in game for the in-game menu spikes: a window that clears to a moving colour at
// vsync, logs its rate, focus and cursor state once a second, and can capture the cursor as a game.
// Usage: standin.exe x y w h seconds [border|popup] [capture|clip|aggressive] [activate]
//   x y w h: the window, in Wine's virtual screen pixels (the built-in screen, from the caller).
//   popup: no frame, as a borderless fullscreen game when the rect is the whole screen.
//   capture: while the game is active, clip the cursor to the window, hide it and re-centre it
//   every frame (mouse look); release on WM_ACTIVATEAPP false. clip: the same without re-centring,
//   as a strategy game. aggressive: as capture, but never release.
//   activate: take the focus at start (SetForegroundWindow).
// Every line starts with the Unix time in ms, to line up with the Swift side.

#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int running = 1, active, capture, aggressive, cliponly, hidden, f1Seen;
static HWND window;

static long long now_ms(void)
{
	FILETIME ft;
	GetSystemTimeAsFileTime(&ft);
	return (long long)((((unsigned long long)ft.dwHighDateTime << 32) | ft.dwLowDateTime) / 10000ULL - 11644473600000ULL);
}

static void say(const char *what)
{
	printf("%lld %s\n", now_ms(), what);
	fflush(stdout);
}

static void grab(void)
{
	RECT r;
	GetClientRect(window, &r);
	MapWindowPoints(window, NULL, (POINT *)&r, 2);
	ClipCursor(&r);
	if (!cliponly)
		SetCursorPos((r.left + r.right) / 2, (r.top + r.bottom) / 2);
	if (!hidden) {
		ShowCursor(FALSE);
		hidden = 1;
	}
}

static void release(void)
{
	ClipCursor(NULL);
	if (hidden) {
		ShowCursor(TRUE);
		hidden = 0;
	}
}

static LRESULT CALLBACK proc(HWND w, UINT message, WPARAM wp, LPARAM lp)
{
	char line[96];
	switch (message) {
	case WM_CLOSE:
	case WM_DESTROY:
		running = 0;
		return 0;
	case WM_ACTIVATEAPP:
		active = wp != 0;
		say(active ? "activateapp 1" : "activateapp 0");
		if (capture && !active && !aggressive)
			release();
		break;
	case WM_KEYDOWN:
	case WM_SYSKEYDOWN:
		snprintf(line, sizeof line, "key vk=0x%02x alt=%d", (unsigned)wp, (GetKeyState(VK_MENU) & 0x8000) != 0);
		say(line);
		if (wp == VK_F1)
			f1Seen++;
		if (message == WM_SYSKEYDOWN)
			return 0;
		break;
	}
	return DefWindowProcA(w, message, wp, lp);
}

int main(int argc, char **argv)
{
	if (argc < 6) {
		fputs("usage: standin.exe x y w h seconds [border|popup] [capture|aggressive] [activate]\n", stderr);
		return 2;
	}
	int x = atoi(argv[1]), y = atoi(argv[2]), width = atoi(argv[3]), height = atoi(argv[4]);
	double seconds = atof(argv[5]);
	int popup = 0, activate = 0;
	for (int i = 6; i < argc; i++) {
		popup |= strcmp(argv[i], "popup") == 0;
		capture |= strcmp(argv[i], "capture") == 0 || strcmp(argv[i], "aggressive") == 0 || strcmp(argv[i], "clip") == 0;
		cliponly |= strcmp(argv[i], "clip") == 0;
		aggressive |= strcmp(argv[i], "aggressive") == 0;
		activate |= strcmp(argv[i], "activate") == 0;
	}

	WNDCLASSA wc = { 0 };
	wc.lpfnWndProc = proc;
	wc.hInstance = GetModuleHandleA(NULL);
	wc.hCursor = LoadCursor(NULL, IDC_ARROW);
	wc.lpszClassName = "standin";
	RegisterClassA(&wc);
	DWORD style = popup ? WS_POPUP : WS_OVERLAPPEDWINDOW;
	RECT rect = { x, y, x + width, y + height };
	if (!popup)
		AdjustWindowRect(&rect, style, FALSE);
	window = CreateWindowExA(0, "standin", "Cartouche overlay stand-in", style, rect.left, rect.top,
	                         rect.right - rect.left, rect.bottom - rect.top, NULL, NULL, wc.hInstance, NULL);
	ShowWindow(window, activate ? SW_SHOW : SW_SHOWNOACTIVATE);
	if (activate)
		SetForegroundWindow(window);

	DXGI_SWAP_CHAIN_DESC sd = { 0 };
	sd.BufferDesc.Width = width;
	sd.BufferDesc.Height = height;
	sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
	sd.SampleDesc.Count = 1;
	sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
	sd.BufferCount = 2;
	sd.OutputWindow = window;
	sd.Windowed = TRUE;
	sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
	IDXGISwapChain *chain;
	ID3D11Device *device;
	ID3D11DeviceContext *context;
	if (FAILED(D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION, &sd,
	                                         &chain, &device, NULL, &context))) {
		say("error no D3D11 device");
		return 1;
	}
	ID3D11Texture2D *back;
	ID3D11RenderTargetView *target;
	IDXGISwapChain_GetBuffer(chain, 0, &IID_ID3D11Texture2D, (void **)&back);
	ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)back, NULL, &target);

	char line[256];
	snprintf(line, sizeof line, "start rect=%d,%d,%dx%d popup=%d capture=%d clip=%d aggressive=%d", x, y, width, height,
	         popup, capture, cliponly, aggressive);
	say(line);
	LARGE_INTEGER freq, t0, t, last;
	QueryPerformanceFrequency(&freq);
	QueryPerformanceCounter(&t0);
	last = t0;
	long frames = 0, total = 0;
	while (running) {
		MSG message;
		while (PeekMessageA(&message, NULL, 0, 0, PM_REMOVE)) {
			TranslateMessage(&message);
			DispatchMessageA(&message);
		}
		QueryPerformanceCounter(&t);
		double elapsed = (double)(t.QuadPart - t0.QuadPart) / (double)freq.QuadPart;
		if (elapsed >= seconds)
			break;
		if (capture && (active || aggressive))
			grab();
		float phase = (float)elapsed;
		float colour[4] = { 0.5f + 0.5f * (float)__builtin_sin(phase * 2.0f), 0.3f,
		                    0.5f + 0.5f * (float)__builtin_cos(phase * 1.3f), 1.0f };
		ID3D11DeviceContext_OMSetRenderTargets(context, 1, &target, NULL);
		ID3D11DeviceContext_ClearRenderTargetView(context, target, colour);
		IDXGISwapChain_Present(chain, 1, 0);
		frames++;
		total++;
		double since = (double)(t.QuadPart - last.QuadPart) / (double)freq.QuadPart;
		if (since >= 1.0) {
			POINT p;
			RECT clip;
			GetCursorPos(&p);
			GetClipCursor(&clip);
			snprintf(line, sizeof line, "tick fps=%.1f fg=%d active=%d hidden=%d cursor=%ld,%ld clip=%ld,%ld,%ld,%ld",
			         frames / since, GetForegroundWindow() == window, active, hidden, p.x, p.y, clip.left, clip.top,
			         clip.right, clip.bottom);
			say(line);
			frames = 0;
			last = t;
		}
	}
	release();
	snprintf(line, sizeof line, "end frames=%ld f1=%d", total, f1Seen);
	say(line);
	return 0;
}
