/*
 * unarc-driver: extracts a FreeArc archive through the unarc.dll an installer
 * ships, without running the installer itself.
 *
 * The CLS helper DLLs the installers carry open their shared-memory channels
 * through names like "Global\Read_MapFile_CLS-srepXX". They find the namespace
 * by reading a 256-byte named mapping called "Init_MapFile_", which the
 * installer creates before loading unarc.dll. When it is absent they open a
 * nonexistent local name, fail with error 2 and wait on an event nothing
 * signals, which is the stall this driver exists to avoid: create the mapping
 * with "Global\" in it BEFORE LoadLibrary, keep it until FreeArcExtract
 * returns.
 *
 *   unarc-driver.exe x -o+ -dpC:\G\Game -wC:\T -cfgC:\U\arc.ini -- S:\fg-01.bin
 *
 * Extra driver-side switches (consumed here, not passed to FreeArcExtract):
 *   --dll=NAME     module to load instead of unarc.dll
 *   --password=PW  archive password, answered to unarc's "password" callback
 */

#include <windows.h>
#include <stdio.h>
#include <string.h>

typedef int (__stdcall *cbtype)(char *what, int int1, int int2, char *str);
typedef int (__cdecl *extract_t)(cbtype, ...);

static const char *password;

static int __stdcall cb(char *what, int int1, int int2, char *str) {
    if (!strcmp(what, "password") && password) { strcpy(str, password); return 1; }
    if (!strcmp(what, "filename") || !strcmp(what, "error") || !strcmp(what, "total"))
        printf("%s %d %d %s\n", what, int1, int2, str ? str : "");
    else if (!strcmp(what, "write")) printf("write %d MB\r", int1);
    fflush(stdout);
    return 0;
}

int main(int argc, char **argv) {
    const char *module = "unarc.dll";
    char *a[10] = {0};
    int n = 0;
    for (int i = 1; i < argc; i++) {
        if (!strncmp(argv[i], "--password=", 11)) { password = argv[i] + 11; continue; }
        if (!strncmp(argv[i], "--dll=", 6)) { module = argv[i] + 6; continue; }
        if (n < 9) a[n++] = argv[i];
    }
    if (!n) {
        fprintf(stderr, "usage: unarc-driver.exe [--dll=unarc.dll] [--password=PW] x -o+ -dpDIR -wTMP -cfgINI -- PART\n");
        return 2;
    }

    HANDLE init = CreateFileMappingA(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE,
                                    0, 256, "Init_MapFile_");
    if (!init) { fprintf(stderr, "CreateFileMapping: %lu\n", GetLastError()); return 3; }
    char *scope = MapViewOfFile(init, FILE_MAP_ALL_ACCESS, 0, 0, 256);
    if (!scope) { fprintf(stderr, "MapViewOfFile: %lu\n", GetLastError()); CloseHandle(init); return 3; }
    strcpy(scope, "Global\\");
    fprintf(stderr, "CLS namespace initialized: %s\n", scope);

    HMODULE dll = LoadLibraryA(module);
    if (!dll) { fprintf(stderr, "cannot load %s: %lu\n", module, GetLastError()); return 2; }
    extract_t extract = (extract_t)GetProcAddress(dll, "FreeArcExtract");
    if (!extract) { fprintf(stderr, "%s exports no FreeArcExtract\n", module); return 2; }

    int r = extract(cb, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9]);
    printf("\nresult %d\n", r);

    UnmapViewOfFile(scope);
    CloseHandle(init);
    return r;
}
