//
// HuCard ROM loading (.PCE / .SGX, and the data BIN of a .CUE).
//

#ifndef H_ROM
#define H_ROM

#include <stdint.h>

int is_rom(const char *name);
int is_cue(const char *name);
int load_rom(const char *fname, uint32_t size);

#endif
