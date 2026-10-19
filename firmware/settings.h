//
// Video, audio and per-game pad settings, persisted under /config on the SD.
//

#ifndef H_SETTINGS
#define H_SETTINGS

extern int video_zoom;
extern int video_scanline;
extern int game_pad_mode;
extern int video_color;
extern int nes_palette;
extern int gbc_color;
extern int gb_palette;
int video_is_gameboy(void);
int video_is_gbc(void);
int video_zoom_count(void);
void nintendo_color_apply(void);
extern int cheats_enabled;
extern int vdc_sprites_double;

extern int audio_volume;
extern int audio_bass;
extern int audio_treble;
extern int audio_output_hdmi;
extern int audio_cdda_enabled;
extern int audio_adpcm_enabled;
extern int audio_paused;
extern int console_region;

void game_pad_mode_load(const char *game_name);
void game_pad_mode_save(const char *game_name);
int game_pad_mode_sf2_default(const char *game_name);
int game_cheats_activated_load(const char *game_name, uint8_t *indices,
							   int max_indices, int *count);
int game_cheats_activated_save(const char *game_name, const uint8_t *indices,
							   int count);
void video_config_load(void);
void video_config_save(void);
void audio_apply(void);
void audio_config_load(void);
void audio_config_save(void);
void system_config_load(void);
void system_config_save(void);
void console_region_apply(void);
void vdc_options_apply(void);

#endif
