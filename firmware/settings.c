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
int cheat_cd_enabled = 0;

static int open_game_config(FIL *file, const char *game_name) {
    char path[PWD_SIZE + NAME_MAX + 16];
    FRESULT result;
    if (build_game_path(path, sizeof(path), "/config/", game_name,
                        ".cfg", 1) != 0)
        return -1;
    result = f_open(file, path, FA_READ);
    if (result == FR_OK)
        return 1;
    if (result != FR_NO_FILE && result != FR_NO_PATH)
        return -1;
    if (build_game_path(path, sizeof(path), "/config/", game_name,
                        ".cfg", 0) != 0)
        return -1;
    result = f_open(file, path, FA_READ);
    return result == FR_OK ? 1 : result == FR_NO_FILE || result == FR_NO_PATH ? 0 : -1;
}

static int config_index_list(char *text, uint8_t *indices, int capacity,
                             int *count) {
    int used = 0;
    char *cursor = text;
    while (*cursor == ' ' || *cursor == '\t') cursor++;
    if (*cursor++ != '[')
        return -1;
    for (;;) {
        unsigned value = 0;
        int digits = 0;
        while (*cursor == ' ' || *cursor == '\t') cursor++;
        if (*cursor == ']') {
            cursor++;
            break;
        }
        while (*cursor >= '0' && *cursor <= '9') {
            digits = 1;
            if (value <= 1000)
                value = value * 10 + (unsigned)(*cursor - '0');
            cursor++;
        }
        while (*cursor == ' ' || *cursor == '\t') cursor++;
        if (*cursor != ',' && *cursor != ']') {
            digits = 0;
            while (*cursor && *cursor != ',' && *cursor != ']') cursor++;
            uart_print("config: ignoring malformed cheat index\n");
        }
        if (digits) {
            if (value < 64) {
                int duplicate = 0;
                for (int i = 0; i < used; i++)
                    duplicate |= indices[i] == value;
                if (!duplicate && used < capacity)
                    indices[used++] = (uint8_t)value;
            } else {
                uart_printf("config: ignoring cheat index %d\n", (int)value);
            }
        } else if (*cursor != ',' && *cursor != ']') {
            while (*cursor && *cursor != ',' && *cursor != ']') cursor++;
        }
        while (*cursor == ' ' || *cursor == '\t') cursor++;
        if (*cursor == ',') {
            cursor++;
            continue;
        }
        if (*cursor == ']') {
            cursor++;
            break;
        }
        return -1;
    }
    while (*cursor == ' ' || *cursor == '\t' || *cursor == '\r' || *cursor == '\n')
        cursor++;
    if (*cursor)
        return -1;
    *count = used;
    return 0;
}

int game_cheats_activated_load(const char *game_name, uint8_t *indices,
                               int max_indices, int *count) {
    FIL file;
    char line[256];
    int opened;
    int found = 0;
    if (count)
        *count = 0;
    if (!game_name || !*game_name || !indices || !count || max_indices < 0)
        return -1;
    opened = open_game_config(&file, game_name);
    if (opened <= 0)
        return opened;
    while (f_gets(line, sizeof(line), &file)) {
        char *entry = line;
        while (*entry == ' ' || *entry == '\t') entry++;
        if (!starts_with(entry, "cheats_activated="))
            continue;
        if (found || config_index_list(entry + 17, indices, max_indices, count) != 0) {
            f_close(&file);
            uart_print("config: invalid cheats_activated list\n");
            return -1;
        }
        found = 1;
    }
    f_close(&file);
    return found ? 1 : 0;
}

static void read_config_values(const char *game_name, int *pad_mode,
                               char *cheats_line, size_t cheats_size) {
    FIL file;
    char line[256];
    int opened = open_game_config(&file, game_name);
    if (opened != 1)
        return;
    while (f_gets(line, sizeof(line), &file)) {
        char *entry = line;
        while (*entry == ' ' || *entry == '\t') entry++;
        if (starts_with(entry, "pad_mode=")) {
            *pad_mode = parse_u8(entry + 9) ? 1 : 0;
        } else if (starts_with(entry, "cheats_activated=") && cheats_size) {
            strncpy(cheats_line, entry, cheats_size - 1);
            cheats_line[cheats_size - 1] = '\0';
            size_t length = strlen(cheats_line);
            while (length && (cheats_line[length - 1] == '\n' ||
                              cheats_line[length - 1] == '\r'))
                cheats_line[--length] = '\0';
        }
    }
    f_close(&file);
}

static int write_game_config(const char *game_name, int pad_mode,
                             const char *cheats_line) {
    FIL file;
    UINT bw;
    char path[PWD_SIZE + NAME_MAX + 16];
    char num[4];
    int len;
    static const char header[] =
        "# PCEngine / SuperGrafx game settings\n"
        "# pad_mode: 0 = 2 buttons, 1 = 6 buttons\n";
    if (build_game_path(path, sizeof(path), "/config/", game_name,
                        ".cfg", 1) != 0)
        return -1;
    f_mkdir("/config");
    if (f_open(&file, path, FA_WRITE | FA_CREATE_ALWAYS) != FR_OK)
        return -1;
    if (f_write(&file, header, sizeof(header) - 1, &bw) != FR_OK ||
        bw != sizeof(header) - 1 ||
        f_write(&file, "pad_mode=", 9, &bw) != FR_OK || bw != 9) {
        f_close(&file);
        return -1;
    }
    len = u8_to_str(num, (uint8_t)pad_mode);
    if (f_write(&file, num, (UINT)len, &bw) != FR_OK || bw != (UINT)len ||
        f_write(&file, "\n", 1, &bw) != FR_OK || bw != 1) {
        f_close(&file);
        return -1;
    }
    if (cheats_line && *cheats_line) {
        UINT length = (UINT)strlen(cheats_line);
        if (f_write(&file, cheats_line, length, &bw) != FR_OK || bw != length ||
            f_write(&file, "\n", 1, &bw) != FR_OK || bw != 1) {
            f_close(&file);
            return -1;
        }
    }
    FRESULT result = f_close(&file);
    return result == FR_OK ? 0 : -1;
}

void game_pad_mode_load(const char *game_name) {
    char ignored_cheats[256] = "";
    game_pad_mode = 0;
    reg_pad_mode = 0;
    if (!game_name || !*game_name)
        return;
    read_config_values(game_name, &game_pad_mode, ignored_cheats,
                       sizeof(ignored_cheats));
    reg_pad_mode = game_pad_mode;
}

void game_pad_mode_save(const char *game_name) {
    int pad_mode = game_pad_mode;
    char cheats_line[256] = "";
    if (!game_name || !*game_name)
        return;
    read_config_values(game_name, &pad_mode, cheats_line, sizeof(cheats_line));
    if (write_game_config(game_name, game_pad_mode, cheats_line) != 0)
        uart_print("config: could not save game settings\n");
}

int game_cheats_activated_save(const char *game_name, const uint8_t *indices,
                               int count) {
    int pad_mode = game_pad_mode;
    char previous[256] = "";
    char list[256];
    int used = 0;
    if (!game_name || !*game_name || count < 0 || count > 64 ||
        (count && !indices))
        return -1;
    read_config_values(game_name, &pad_mode, previous, sizeof(previous));
    memcpy(list, "cheats_activated=[", 17);
    used = 17;
    for (int i = 0; i < count; i++) {
        char num[4];
        int len;
        if (i)
            list[used++] = ',';
        len = u8_to_str(num, indices[i]);
        memcpy(list + used, num, (size_t)len);
        used += len;
    }
    list[used++] = ']';
    list[used] = '\0';
    return write_game_config(game_name, pad_mode, list);
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

    f_mkdir("/config");

    if (f_open(&file, VIDEO_CFG_FILE, FA_WRITE | FA_CREATE_ALWAYS) != FR_OK) {
        return;
    }

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
int audio_output_hdmi = 0; // 0 = onboard speaker, 1 = HDMI
int audio_cdda_enabled = 1;
int audio_adpcm_enabled = 1;
int audio_paused = 0;

// Pushes the current settings to reg_audio; bass/treble are biased by +5 to
// match the unsigned 0..10 range iosys.v stores them in.
void audio_apply(void) {
    uint32_t volume = audio_paused ? 0 : (uint32_t)audio_volume;

    reg_audio = volume |
                ((uint32_t)(audio_bass + 5) << 4) |
                ((uint32_t)(audio_treble + 5) << 8) |
                ((uint32_t)audio_output_hdmi << 12) |
                ((uint32_t)audio_cdda_enabled << 13) |
                ((uint32_t)audio_adpcm_enabled << 14);
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
        } else if (starts_with(line, "output=")) {
            audio_output_hdmi = parse_u8(line + 7) == 1;
        } else if (starts_with(line, "cd_audio=")) {
            audio_cdda_enabled = parse_u8(line + 9) == 1;
        } else if (starts_with(line, "adpcm=")) {
            audio_adpcm_enabled = parse_u8(line + 6) == 1;
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
        "# output : 0 = onboard speaker, 1 = HDMI\n"
        "# cd_audio : 0 = mute CD-DA output, 1 = play it\n"
        "# adpcm : 0 = mute ADPCM audio output, 1 = play it (DMA unchanged)\n"
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

    f_write(&file, "output=", 7, &bw);
    f_write(&file, audio_output_hdmi ? "1\n" : "0\n", 2, &bw);

    f_write(&file, "cd_audio=", 9, &bw);
    f_write(&file, audio_cdda_enabled ? "1\n" : "0\n", 2, &bw);

    f_write(&file, "adpcm=", 6, &bw);
    f_write(&file, audio_adpcm_enabled ? "1\n" : "0\n", 2, &bw);

    f_close(&file);
}

// ---------------------------------------------------------------------------
// System configuration & Persistence
// ---------------------------------------------------------------------------

#define SYSTEM_CFG_FILE   "/config/system.cfg"

void system_config_load(void) {
    FIL file;
    char line[64];

    if (f_open(&file, SYSTEM_CFG_FILE, FA_READ) != FR_OK)
        return;

    while (f_gets(line, sizeof(line), &file)) {
        if (starts_with(line, "debug_uart="))
            debug_uart = parse_u8(line + 11) ? 1 : 0;
        else if (starts_with(line, "cheat_cd="))
            cheat_cd_enabled = parse_u8(line + 9) ? 1 : 0;
    }

    f_close(&file);
}

void system_config_save(void) {
    FIL file;
    UINT bw;
    static const char text[] =
        "# PCEngine / SuperGrafx System Settings\n"
        "# debug_uart : 0 = off, 1 = debug traces on the UART\n"
        "# cheat_cd : 0 = off, 1 = experimental CD cheats\n"
        "debug_uart=";

    f_mkdir("/config");

    if (f_open(&file, SYSTEM_CFG_FILE, FA_WRITE | FA_CREATE_ALWAYS) != FR_OK)
        return;

    f_write(&file, text, sizeof(text) - 1, &bw);
    f_write(&file, debug_uart ? "1\n" : "0\n", 2, &bw);
    f_write(&file, "cheat_cd=", 9, &bw);
    f_write(&file, cheat_cd_enabled ? "1\n" : "0\n", 2, &bw);
    f_close(&file);
}
