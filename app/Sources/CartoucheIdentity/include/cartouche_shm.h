// The shared memory blocks the framegen library and the app exchange, and shm_open without
// its variadic signature, which Swift cannot call
#ifndef CARTOUCHE_SHM_H
#define CARTOUCHE_SHM_H

#include "fg_metrics_shm.h"
#include "fg_control_shm.h"

int cartouche_shm_open_read(const char *name);
int cartouche_shm_open_write(const char *name);

#endif
