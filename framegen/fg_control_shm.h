// The control block the Cartouche app writes for the library: the in-game menu's live HUD
// settings. Plain C, the same layout on x86_64 and arm64.
//
// Name: "/cartouche-control.<game pid>" (shm_open), 4096 bytes, created by the app, mode 0600.
// Reading: as fg_metrics_shm.h (magic, version, size, then an even sequence that is the same
// before and after the copy). A missing block leaves the launch variables in force.

#ifndef FG_CONTROL_SHM_H
#define FG_CONTROL_SHM_H

#include <stddef.h>
#include <stdint.h>

#define FG_CONTROL_MAGIC 0x4c525443u // "CTRL"
#define FG_CONTROL_VERSION 1u
#define FG_CONTROL_SIZE 4096u
#define FG_CONTROL_NAME "/cartouche-control.%d"

enum { FG_HUD_HIDDEN, FG_HUD_MINI, FG_HUD_STANDARD, FG_HUD_FULL };
enum { FG_CORNER_TL, FG_CORNER_TR, FG_CORNER_BL, FG_CORNER_BR };

typedef struct {
	uint32_t magic;
	uint32_t version;
	uint32_t size;
	int32_t pid;             // the game's
	uint32_t sequence;       // odd while the app writes
	uint32_t reserved0;

	int32_t hud_level;       // FG_HUD_*
	int32_t hud_corner;      // FG_CORNER_*
	int32_t hud_scale;       // percent: 100, 125, 150
	int32_t menu_open;       // 1 while the menu is shown: the warning capsule hides
	int32_t reduce_motion;   // 1: level and corner changes cross-fade, no spring
	int32_t battery_percent; // -1 without a battery
	float gpu_watts;         // GPU power read by the app (IOReport), < 0 when unknown
	float reserved1;
	char warning[128];       // UTF-8, empty for none: the "Mac surchargé" capsule under the HUD
	char hotkey[16];         // UTF-8 label of the menu shortcut shown in the capsule, "⌥C"
	// Added after 0.2.0-beta1, zero from an older app: the HUD then keeps its margins and its language
	float safe_top;          // points the notch and the menu bar take at the top of the game's screen
	float screen_height;     // that screen's height in points: the inset applies to a target that fills it
	char language[8];        // "en", "fr": the app's language for the HUD's labels
} FGControlBlock;

_Static_assert(offsetof(FGControlBlock, hud_level) == 24, "control layout");
_Static_assert(offsetof(FGControlBlock, warning) == 56, "control layout");
_Static_assert(offsetof(FGControlBlock, safe_top) == 200, "control layout");
_Static_assert(sizeof(FGControlBlock) <= FG_CONTROL_SIZE, "control block");

#endif
