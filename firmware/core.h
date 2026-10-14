#ifndef H_CORE
#define H_CORE

#include <stdint.h>

const char *core_name(uint32_t profile);
uint32_t core_game_profile(const char *game);
int core_supports_game(uint32_t profile, const char *game);
void core_menu(void);
int core_offer_switch(uint32_t profile, const char *game);
int core_autorun(void);

#endif