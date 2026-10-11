#ifndef H_CORE
#define H_CORE

#include <stdint.h>

const char *core_name(uint32_t profile);
void core_menu(void);
int core_offer_switch(uint32_t profile, const char *game);
int core_autorun(void);

#endif