#ifndef H_CHEATS
#define H_CHEATS

enum cheat_game_type {
    CHEAT_GAME_PCE,
    CHEAT_GAME_SGX,
    CHEAT_GAME_CD
};

void cheats_load(const char *game_name, enum cheat_game_type type);
void cheats_clear(void);
int cheats_count(void);
int cheats_active_count(void);
int cheats_is_active(int index);
const char *cheats_description(int index);
const char *cheats_status(void);
int cheats_toggle(int index);

#endif