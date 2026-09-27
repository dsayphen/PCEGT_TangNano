//
// Backup RAM (.brm) and Populous SRAM (.pop) persistence under /saves.
//

#ifndef H_SAVES
#define H_SAVES

int load_game_saves(const char *game_name, int is_populous);
int save_game_saves(int resume_game);

#endif
