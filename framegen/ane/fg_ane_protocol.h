// What the frame generation library (x86_64, in the game) and its Neural Engine helper (arm64)
// share: a Mach service to meet, four IOSurfaces and one control page
#pragma once
#include <mach/mach.h>
#include <stdatomic.h>
#include <stdint.h>

enum { fg_ane_width = 512, fg_ane_height = 256 };

typedef struct {
	_Atomic uint32_t request; // bumped by the library once both input surfaces hold frames
	_Atomic uint32_t parity;  // 0: surface 0 is the earlier frame, 1: surface 1 is
	_Atomic uint32_t done;    // the helper copies request here once flow and mask are written
	_Atomic uint32_t quit;
	_Atomic uint32_t ready;   // set by the helper once the model is loaded
	_Atomic uint32_t micros;  // the last inference, in microseconds
} FGANEControl;

typedef struct {
	mach_msg_header_t header;
	mach_msg_body_t body;
	mach_msg_port_descriptor_t surfaces[4]; // frame 0, frame 1 (planar RGB), flow (4 planes), mask
	char control[64];                       // shm_open name of the control page
} FGANEHello;
