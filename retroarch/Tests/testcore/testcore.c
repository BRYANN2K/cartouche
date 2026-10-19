/* A small libretro core for the session tests, never shipped. It loads any
 * file, paints the screen in the colour the file's first three bytes name,
 * with a bar that moves each frame, and saves and loads its frame count as
 * its state. Built by make retroarch-testcore. */

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <libretro.h>

#define WIDTH 160
#define HEIGHT 144

static uint32_t frame[WIDTH * HEIGHT];
static uint32_t colour;
static uint8_t ram[256];
static struct { uint32_t frames; } state;

static retro_environment_t environ_cb;
static retro_video_refresh_t video_cb;
static retro_audio_sample_batch_t audio_batch_cb;
static retro_input_poll_t input_poll_cb;

RETRO_API unsigned retro_api_version(void) { return RETRO_API_VERSION; }

RETRO_API void retro_get_system_info(struct retro_system_info *info)
{
   memset(info, 0, sizeof(*info));
   info->library_name     = "Cartouche Test Core";
   info->library_version  = "1";
   info->valid_extensions = "ctc";
   info->need_fullpath    = false;
}

RETRO_API void retro_get_system_av_info(struct retro_system_av_info *info)
{
   memset(info, 0, sizeof(*info));
   info->geometry.base_width   = WIDTH;
   info->geometry.base_height  = HEIGHT;
   info->geometry.max_width    = WIDTH;
   info->geometry.max_height   = HEIGHT;
   info->geometry.aspect_ratio = (float)WIDTH / HEIGHT;
   info->timing.fps            = 60.0;
   info->timing.sample_rate    = 44100.0;
}

RETRO_API void retro_set_environment(retro_environment_t cb)
{
   bool no_game = false;
   environ_cb = cb;
   cb(RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME, &no_game);
}

RETRO_API void retro_set_video_refresh(retro_video_refresh_t cb) { video_cb = cb; }
RETRO_API void retro_set_audio_sample(retro_audio_sample_t cb) { (void)cb; }
RETRO_API void retro_set_audio_sample_batch(retro_audio_sample_batch_t cb) { audio_batch_cb = cb; }
RETRO_API void retro_set_input_poll(retro_input_poll_t cb) { input_poll_cb = cb; }
RETRO_API void retro_set_input_state(retro_input_state_t cb) { (void)cb; }
RETRO_API void retro_set_controller_port_device(unsigned port, unsigned device) { (void)port; (void)device; }

RETRO_API void retro_init(void) { state.frames = 0; }
RETRO_API void retro_deinit(void) {}
RETRO_API void retro_reset(void) { state.frames = 0; }

RETRO_API bool retro_load_game(const struct retro_game_info *game)
{
   enum retro_pixel_format format = RETRO_PIXEL_FORMAT_XRGB8888;
   const uint8_t *bytes;
   if (!game || !game->data || game->size < 3)
      return false;
   if (!environ_cb(RETRO_ENVIRONMENT_SET_PIXEL_FORMAT, &format))
      return false;
   bytes  = (const uint8_t*)game->data;
   colour = ((uint32_t)bytes[0] << 16) | ((uint32_t)bytes[1] << 8) | bytes[2];
   return true;
}

RETRO_API bool retro_load_game_special(unsigned type, const struct retro_game_info *info, size_t num)
{
   (void)type; (void)info; (void)num;
   return false;
}

RETRO_API void retro_unload_game(void) {}

RETRO_API void retro_run(void)
{
   static int16_t silence[2 * 735];
   unsigned x, y, bar;
   input_poll_cb();
   bar = state.frames % WIDTH;
   for (y = 0; y < HEIGHT; y++)
      for (x = 0; x < WIDTH; x++)
         frame[y * WIDTH + x] = (x >= bar && x < bar + 8) ? 0xFFFFFF : colour;
   state.frames++;
   memcpy(ram, &state.frames, sizeof(state.frames));
   video_cb(frame, WIDTH, HEIGHT, WIDTH * sizeof(uint32_t));
   audio_batch_cb(silence, 735);
}

RETRO_API unsigned retro_get_region(void) { return RETRO_REGION_NTSC; }

RETRO_API size_t retro_serialize_size(void) { return sizeof(state); }

RETRO_API bool retro_serialize(void *data, size_t size)
{
   if (size < sizeof(state))
      return false;
   memcpy(data, &state, sizeof(state));
   return true;
}

RETRO_API bool retro_unserialize(const void *data, size_t size)
{
   if (size < sizeof(state))
      return false;
   memcpy(&state, data, sizeof(state));
   return true;
}

RETRO_API void retro_cheat_reset(void) {}
RETRO_API void retro_cheat_set(unsigned index, bool enabled, const char *code) { (void)index; (void)enabled; (void)code; }

RETRO_API void *retro_get_memory_data(unsigned id) { return id == RETRO_MEMORY_SYSTEM_RAM ? ram : NULL; }
RETRO_API size_t retro_get_memory_size(unsigned id) { return id == RETRO_MEMORY_SYSTEM_RAM ? sizeof(ram) : 0; }
