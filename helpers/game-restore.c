// Restores the minimized top-level windows of one game, by executable name: a fullscreen
// Direct3D game minimizes itself when it loses focus to the in-game menu and stays minimized.
#include <windows.h>
#include <stdio.h>
#include <string.h>

static const char *wanted;
static int restored;

static BOOL CALLBACK each(HWND window, LPARAM unused) {
    (void)unused;
    if (!IsIconic(window) || GetWindow(window, GW_OWNER)) return TRUE;
    DWORD pid = 0;
    GetWindowThreadProcessId(window, &pid);
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!process) return TRUE;
    char path[MAX_PATH] = {0};
    DWORD size = sizeof path;
    BOOL named = QueryFullProcessImageNameA(process, 0, path, &size);
    CloseHandle(process);
    if (!named) return TRUE;
    const char *name = strrchr(path, '\\');
    name = name ? name + 1 : path;
    if (_stricmp(name, wanted) != 0) return TRUE;
    ShowWindow(window, SW_RESTORE);
    SetForegroundWindow(window);
    restored++;
    return TRUE;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: game-restore.exe <game.exe>\n");
        return 2;
    }
    wanted = argv[1];
    EnumWindows(each, 0);
    printf("restored %d\n", restored);
    return restored > 0 ? 0 : 1;
}
