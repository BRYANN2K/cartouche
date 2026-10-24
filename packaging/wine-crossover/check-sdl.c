#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv)
{
    if (argc != 2) return 2;
    void *sdl = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!sdl) { fprintf(stderr, "check-sdl: %s\n", dlerror()); return 1; }
    int (*init)(unsigned) = dlsym(sdl, "SDL_Init");
    const char *(*error)(void) = dlsym(sdl, "SDL_GetError");
    void (*quit)(void) = dlsym(sdl, "SDL_Quit");
    if (!init || !error || !quit) return 1;
    if (init(0x00002000) < 0) {
        fprintf(stderr, "check-sdl: %s\n", error());
        return 1;
    }
    quit();
    dlclose(sdl);
    puts("check-sdl: game controller backend initialized");
    return 0;
}
