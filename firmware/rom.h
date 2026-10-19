//
// Cartridge ROM loading, including raw .MD/.GEN/.BIN (SEGA at 0x100).
// MD SMD/interleaved/copier formats and cartridge save persistence unsupported.
//

#ifndef H_ROM
#define H_ROM

#include <stdint.h>

int is_rom(const char *name);
int is_snes(const char *name);
int is_nes(const char *name);
int is_gameboy(const char *name);
int is_megadrive(const char *name);
int validate_megadrive_rom(const char *fname, uint32_t size);
int is_cue(const char *name);
int load_rom(const char *fname, uint32_t size);

#endif
