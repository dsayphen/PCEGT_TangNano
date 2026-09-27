//
// Shared definitions of the IO subsystem firmware: sizes, globals owned by
// firmware.c / browser.c, and the small string helpers of util.c.
//

#ifndef H_COMMON
#define H_COMMON

#include "picorv32.h"
#include "fatfs/ff.h"

#define NAME_MAX    64          // characters kept per entry (the OSD is 32 wide)
#define PWD_SIZE    256

#define ROM_MIN_SIZE 1024
#define ROM_MAX_SIZE (4*1024*1024)

extern char pwd[PWD_SIZE];                  // browser.c
extern uint8_t io_buf[2048];                // firmware.c
extern char current_game_name[NAME_MAX];    // firmware.c
extern int current_game_populous;           // firmware.c

// ---- util.c ---------------------------------------------------------------
uint8_t to_bcd(uint32_t v);
int     from_bcd(uint8_t value);
void    extract_filename(char *dst, const char *path);
void    build_cfg_path(char *dst, size_t max_len, const char *game_name);
int     u8_to_str(char *buf, uint8_t val);
int     starts_with(const char *line, const char *prefix);
int     starts_with_ci_n(const char *line, const char *prefix, int n);
uint8_t parse_u8(const char *str);
int     contains_ci(const char *line, const char *needle);

#endif
