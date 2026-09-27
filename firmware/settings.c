//
// Video configuration, audio configuration and per-game pad mode.
//

#include "common.h"
#include "settings.h"

// ---------------------------------------------------------------------------
// Video configuration & Persistence
// ---------------------------------------------------------------------------
// Saved at the root of the SD card so the last zoom/scanline settings survive
// a power cycle. 

#define VIDEO_CFG_FILE    "/config/video.cfg"

int video_zoom = 1;       // hardware reset default: stretch
int video_scanline = 0;   // hardware reset default: off
int game_pad_mode = 0;    // hardware reset default: 2 buttons
int video_color = 0;      // hardware reset default: raw RGB

void game_pad_mode_load(const char *game_name) {
    FIL file;
    char cfg_path[PWD_SIZE + NAME_MAX + 16];
    char line[64];

    // Valeur par défaut : 2 boutons
    game_pad_mode = 0;
    reg_pad_mode = 0;

    if (!game_name || game_name[0] == '\0') return;

    // Construction du chemin : /config/[nomdujeu].cfg
    build_cfg_path(cfg_path, sizeof(cfg_path), game_name);

    if (f_open(&file, cfg_path, FA_READ) != FR_OK) {
        return; // Conserve la valeur par défaut si le fichier n'existe pas
    }

    while (f_gets(line, sizeof(line), &file)) {
        if (line[0] == '#' || line[0] == '\r' || line[0] == '\n' || line[0] == '\0') {
            continue;
        }

        if (starts_with(line, "pad_mode=")) {
            game_pad_mode = parse_u8(line + 9) ? 1 : 0;
            reg_pad_mode = game_pad_mode;
        }
    }

    f_close(&file);
}

void game_pad_mode_save(const char *game_name) {
    FIL file;
    UINT bw;
    char num[4];
    int len;
    char cfg_path[PWD_SIZE + NAME_MAX + 16];

    if (!game_name || game_name[0] == '\0') return;

    // S'assurer que le dossier /config existe
    f_mkdir("/config");

    // Construction du chemin : /config/[nomdujeu].cfg
    build_cfg_path(cfg_path, sizeof(cfg_path), game_name);

    if (f_open(&file, cfg_path, FA_WRITE | FA_CREATE_ALWAYS) != FR_OK) {
        return;
    }

    const char *header = 
        "# PCEngine / SuperGrafx Game Pad Settings\n"
        "# -----------------------------------\n"
        "# pad_mode : 0 = 2 buttons, 1 = 6 buttons\n"
        "# -----------------------------------\n";

    f_write(&file, header, (UINT)strlen(header), &bw);

    f_write(&file, "pad_mode=", 9, &bw);
    len = u8_to_str(num, game_pad_mode);
    f_write(&file, num, len, &bw);
    f_write(&file, "\n", 1, &bw);

    f_close(&file);
}

void video_config_load(void) {
    FIL file;
    char line[64];

    if (f_open(&file, VIDEO_CFG_FILE, FA_READ) != FR_OK) {
        return;
    }

    while (f_gets(line, sizeof(line), &file)) {
        if (line[0] == '#' || line[0] == '\r' || line[0] == '\n' || line[0] == '\0') {
            continue;
        }

        if (starts_with(line, "reg_video_zoom=")) {
            video_zoom = parse_u8(line + 15);
            if (video_zoom > 2)
                video_zoom = 1;
            reg_video_zoom = video_zoom;
        } else if (starts_with(line, "reg_scanline=")) {
            video_scanline = reg_scanline = parse_u8(line + 13);
        } else if (starts_with(line, "color_palette=")) {
            video_color = parse_u8(line + 14) ? 1 : 0;
            reg_color_mode = video_color;
        }
    }

    f_close(&file);
}

void video_config_save(void) {
    FIL file;
    UINT bw;
    char num[4];
    int len;

    if (f_open(&file, VIDEO_CFG_FILE, FA_WRITE | FA_CREATE_ALWAYS) != FR_OK) {
        return;
    }

    // S'assurer que le dossier /config existe
    f_mkdir("/config");

    const char *header = 
        "# PCEngine / SuperGrafx Video Settings\n"
        "# -----------------------------------\n"
        "# reg_video_zoom :\n"
        "#   0 = Original / Integer Scale (1x)\n"
        "#   1 = Stretched / Fit Screen (Full)\n"
        "#   2 = Bilinear / Fit Screen (Smooth)\n"
        "#\n"
        "# reg_scanline :\n"
        "#   0 = Off (No Scanlines)\n"
        "#   1 = 25% Intensity\n"
        "#   2 = 50% Intensity\n"
        "#   3 = 100% Intensity\n"
        "# color_palette : 0 = RAW RGB, 1 = Composite\n"
        "# -----------------------------------\n";

    f_write(&file, header, (UINT)strlen(header), &bw);

    f_write(&file, "reg_video_zoom=", 15, &bw);
    len = u8_to_str(num, reg_video_zoom);
    f_write(&file, num, len, &bw);
    f_write(&file, "\n", 1, &bw);

    f_write(&file, "color_palette=", 14, &bw);
    len = u8_to_str(num, video_color);
    f_write(&file, num, len, &bw);
    f_write(&file, "\n", 1, &bw);

    f_write(&file, "reg_scanline=", 13, &bw);
    len = u8_to_str(num, reg_scanline);
    f_write(&file, num, len, &bw);
    f_write(&file, "\n", 1, &bw);

    f_close(&file);
}

// ---------------------------------------------------------------------------
// Audio configuration & Persistence
// ---------------------------------------------------------------------------
// Global settings (not per-game), saved next to video.cfg.

#define AUDIO_CFG_FILE    "/config/audio.cfg"

int audio_volume = 10;   // 0..10, hardware reset default: unity gain
int audio_bass = 0;      // -5..5, hardware reset default: flat
int audio_treble = 0;    // -5..5, hardware reset default: flat
int audio_paused = 0;

// Pushes the current settings to reg_audio; bass/treble are biased by +5 to
// match the unsigned 0..10 range iosys.v stores them in.
void audio_apply(void) {
    uint32_t volume = audio_paused ? 0 : (uint32_t)audio_volume;

    reg_audio = volume |
                ((uint32_t)(audio_bass + 5) << 4) |
                ((uint32_t)(audio_treble + 5) << 8);
}

void audio_config_load(void) {
    FIL file;
    char line[64];

    if (f_open(&file, AUDIO_CFG_FILE, FA_READ) != FR_OK) {
        audio_apply();
        return;
    }

    while (f_gets(line, sizeof(line), &file)) {
        if (line[0] == '#' || line[0] == '\r' || line[0] == '\n' || line[0] == '\0') {
            continue;
        }

        if (starts_with(line, "volume=")) {
            audio_volume = parse_u8(line + 7);
        } else if (starts_with(line, "bass=")) {
            audio_bass = (int)parse_u8(line + 5) - 5;
        } else if (starts_with(line, "treble=")) {
            audio_treble = (int)parse_u8(line + 7) - 5;
        }
    }

    f_close(&file);
    audio_apply();
}

void audio_config_save(void) {
    FIL file;
    UINT bw;
    char num[4];
    int len;

    f_mkdir("/config");

    if (f_open(&file, AUDIO_CFG_FILE, FA_WRITE | FA_CREATE_ALWAYS) != FR_OK) {
        return;
    }

    const char *header =
        "# PCEngine / SuperGrafx Audio Settings\n"
        "# -----------------------------------\n"
        "# volume : 0 (mute) .. 10 (max)\n"
        "# bass, treble : 0 (min) .. 10 (max), stored biased by +5 (5 = flat)\n"
        "# -----------------------------------\n";

    f_write(&file, header, (UINT)strlen(header), &bw);

    f_write(&file, "volume=", 7, &bw);
    len = u8_to_str(num, (uint8_t)audio_volume);
    f_write(&file, num, len, &bw);
    f_write(&file, "\n", 1, &bw);

    f_write(&file, "bass=", 5, &bw);
    len = u8_to_str(num, (uint8_t)(audio_bass + 5));
    f_write(&file, num, len, &bw);
    f_write(&file, "\n", 1, &bw);

    f_write(&file, "treble=", 7, &bw);
    len = u8_to_str(num, (uint8_t)(audio_treble + 5));
    f_write(&file, num, len, &bw);
    f_write(&file, "\n", 1, &bw);

    f_close(&file);
}
