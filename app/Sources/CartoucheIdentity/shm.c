#include "cartouche_shm.h"

#include <fcntl.h>
#include <sys/mman.h>

int cartouche_shm_open_read(const char *name)
{
	return shm_open(name, O_RDONLY);
}

int cartouche_shm_open_write(const char *name)
{
	return shm_open(name, O_RDWR | O_CREAT, 0600);
}
