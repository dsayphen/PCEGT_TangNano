//
// Firmware for the PicoRV32 IO subsystem of the Tang Nano 20K PC Engine port.
//
// It mounts the microSD card with FatFs, shows a file browser on the OSD and
// streams the .PCE or .SGX image the user selects into the HuCard ROM area of the
// SDRAM.  Structure and the SD / FatFs plumbing follow nand2mario's SNESTang
// firmware (tag v0.7, GPLv3); the menu, the ROM loader and the controls are
// specific to this project.
//
// Build with firmware/build.ps1 (or build.bat) and burn firmware.bin to SPI
// flash offset 0x500000 - see README.md.
//
// Controls (SNES pad)
//   Up / Down     move the selection
//   Left / Right  previous / next page
//   A             open a directory or load the highlighted .PCE/.SGX file
//   B             go back to the parent directory
//   Select+Start  bring the menu back over a running game
//   Select+Up/Down    cycle the display zoom (2x / stretch) over a running game
//   Select+Left/Right cycle the scanline strength (0/25/50/100%) over a running game
//

#include "picorv32.h"
#include "fatfs/ff.h"
#include "font8x8.h"
#include <stdio.h>

// ---------------------------------------------------------------------------
// OSD layout, 32 x 20 characters
// ---------------------------------------------------------------------------
#define ROW_TITLE   0
#define ROW_PATH    1
#define ROW_FIRST   3
#define PAGESIZE    16
#define ROW_STATUS  19

#define NAME_MAX    64          // characters kept per entry (the OSD is 32 wide)
#define PWD_SIZE    256

#define ROM_MIN_SIZE 1024
#define ROM_MAX_SIZE (4*1024*1024)

static FATFS fs;

static char pwd[PWD_SIZE] = "/";
static char names[PAGESIZE][NAME_MAX];
static uint8_t is_dir[PAGESIZE];
static uint32_t sizes[PAGESIZE];
static int page_len;            // entries actually on this page

static char path_buf[PWD_SIZE + NAME_MAX + 2];
static uint8_t io_buf[2048];

static char current_game_name[NAME_MAX] = "";

// Extrait le nom du fichier sans le chemin
static void extract_filename(char *dst, const char *path) {
    const char *slash = strrchr(path, '/');
    const char *src = slash ? (slash + 1) : path;
    strncpy(dst, src, NAME_MAX - 1);
    dst[NAME_MAX - 1] = '\0';
}

// Construit le chemin /config/[game_name].cfg sans snprintf
static void build_cfg_path(char *dst, size_t max_len, const char *game_name) {
    const char *dir = "/config/";
    const char *ext = ".cfg";
    size_t i = 0;

    // Copie "/config/"
    while (*dir && i < max_len - 1) {
        dst[i++] = *dir++;
    }
    // Copie le nom du jeu
    while (*game_name && i < max_len - 1) {
        dst[i++] = *game_name++;
    }
    // Copie ".cfg"
    while (*ext && i < max_len - 1) {
        dst[i++] = *ext++;
    }
    dst[i] = '\0';
}

// Conversion d'un entier 8-bit en chaîne de caractères texte
static int u8_to_str(char *buf, uint8_t val) {
    if (val >= 100) {
        buf[0] = '0' + (val / 100);
        buf[1] = '0' + ((val / 10) % 10);
        buf[2] = '0' + (val % 10);
        buf[3] = '\0';
        return 3;
    } else if (val >= 10) {
        buf[0] = '0' + (val / 10);
        buf[1] = '0' + (val % 10);
        buf[2] = '\0';
        return 2;
    } else {
        buf[0] = '0' + val;
        buf[1] = '\0';
        return 1;
    }
}

// Comparaison de chaînes sans string.h
static int starts_with(const char *line, const char *prefix) {
    while (*prefix) {
        if (*line++ != *prefix++) return 0;
    }
    return 1;
}

// Extraction de la valeur numérique
static uint8_t parse_u8(const char *str) {
    uint8_t val = 0;
    while (*str >= '0' && *str <= '9') {
        val = val * 10 + (*str - '0');
        str++;
    }
    return val;
}

// ---------------------------------------------------------------------------
// Small OSD helpers
// ---------------------------------------------------------------------------
static void status(const char *msg) {
    clear_line(ROW_STATUS);
    cursor(1, ROW_STATUS);
    print(msg);
}

static void title(void) {
    clear_line(ROW_TITLE);
    cursor(1, ROW_TITLE);
    print("PCEngine - pick a ROM");
}

// Print a string right-truncated to `w` columns starting at column x.
static void print_field(int x, int y, const char *s, int w) {
    cursor(x, y);
    int i = 0;
    while (s[i] && i < w) {
        putchar(s[i]);
        i++;
    }
    while (i < w) {
        putchar(' ');
        i++;
    }
}

// Wait for A or B, used by the error pop-ups.
static void wait_button(void) {
    delay(250);
    for (;;) {
        uint32_t e = joy_edge();
        if (e & (JOY_A | JOY_B | JOY_START))
            break;
    }
    delay(150);
}

static void message(const char *l1, const char *l2) {
    clear();
    title();
    print_field(1, 8, l1, OSD_COLS - 2);
    if (l2)
        print_field(1, 9, l2, OSD_COLS - 2);
    status("Press A to continue");
    wait_button();
}

// ---------------------------------------------------------------------------
// Video configuration & Persistence
// ---------------------------------------------------------------------------
// Saved at the root of the SD card so the last zoom/scanline settings survive
// a power cycle. 

#define VIDEO_CFG_FILE    "/config/video.cfg"

static int video_zoom = 1;       // hardware reset default: stretch
static int video_scanline = 0;   // hardware reset default: off
static int game_pad_mode = 0;    // hardware reset default: 2 buttons
static int video_color = 0;      // hardware reset default: raw RGB

static void game_pad_mode_load(const char *game_name) {
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

static void game_pad_mode_save(const char *game_name) {
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

static void video_config_load(void) {
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

static void video_config_save(void) {
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

static int audio_volume = 10;   // 0..10, hardware reset default: unity gain
static int audio_bass = 0;      // -5..5, hardware reset default: flat
static int audio_treble = 0;    // -5..5, hardware reset default: flat
static int audio_paused = 0;

// Pushes the current settings to reg_audio; bass/treble are biased by +5 to
// match the unsigned 0..10 range iosys.v stores them in.
static void audio_apply(void) {
    uint32_t volume = audio_paused ? 0 : (uint32_t)audio_volume;

    reg_audio = volume |
                ((uint32_t)(audio_bass + 5) << 4) |
                ((uint32_t)(audio_treble + 5) << 8);
}

static void audio_config_load(void) {
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

static void audio_config_save(void) {
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

// Cycle the display zoom mode (2x -> stretch -> ...) and flash the new
// setting on the OSD for a moment.  Kept in sync with rtl/tang/iosys/iosys.v
// (reg_video_zoom) and rtl/tang/video_scandoubler.v.
static void zoom_cycle(void) {
    static const char *names[3] = {
        "Zoom: Integer", "Zoom: Stretch", "Zoom: Bilinear"
    };

    video_zoom = (video_zoom + 1) % 3;
    reg_video_zoom = video_zoom;
    video_config_save();

    clear();
    print_field(1, 10, names[video_zoom], OSD_COLS - 2);
    overlay(1);
    delay(600);
    overlay(0);
}

// Cycle the scanline strength (0/25/50/100%) and flash the new setting on
// the OSD for a moment.  `dir` is +1 to increase, -1 to decrease; the value
// wraps around in both directions.  Kept in sync with
// rtl/tang/iosys/iosys.v (reg_scanline) and rtl/tang/video_scandoubler.v.
static void scanline_cycle(int dir) {
    static const char *names[4] = {
        "Scanlines: off", "Scanlines: 25%", "Scanlines: 50%", "Scanlines: 100%"
    };

    video_scanline = (video_scanline + dir + 4) % 4;
    reg_scanline = video_scanline;
    video_config_save();

    clear();
    print_field(1, 10, names[video_scanline], OSD_COLS - 2);
    overlay(1);
    delay(600);
    overlay(0);
}

static const char *zoom_names[3] = { "Integer", "Stretch", "Bilinear" };
static const char *scan_names[4] = { "Off", "25%", "50%", "100%" };
static const char *color_names[2] = { "RAW RGB", "Composite" };

static void make_menu_label(char *buf, int type) {
    const char *prefix;
    const char *value;
    int i = 0;

    if (type == 3) {
        prefix = "Gamepad: ";
        value = game_pad_mode ? "6 buttons" : "2 buttons";
    } else if (type == 4) {
        prefix = "Color: ";
        value = color_names[video_color];
    } else if (type == 5) {
        prefix = "Zoom: ";
        value = zoom_names[video_zoom];
    } else {
        prefix = "Scanlines: ";
        value = scan_names[video_scanline];
    }

    while (*prefix)
        buf[i++] = *prefix++;

    while (*value)
        buf[i++] = *value++;

    buf[i] = '\0';
}

// Color/Zoom/Scanlines sub-menu, reached from "Video Settings >" in
// pause_menu.  Gamepad mode lives directly in pause_menu, not here.
static void video_menu(void) {
    static const char *back_label = "Back";
    int active = 0;
    const int n_items = 4;

    clear();
    print_field(5, 5, "Video Settings", OSD_COLS - 2);

    for (;;) {
        for (int i = 0; i < n_items; i++) {
            cursor(4, 8 + i);
            putchar(i == active ? '>' : ' ');

            char label[24];

            if (i == 3) {
                print_field(6, 8 + i, back_label, 20);
                continue;
            }

            make_menu_label(label, i + 4);
            print_field(6, 8 + i, label, 20);
        }
        selection_row(8 + active);

        uint32_t e = joy_edge();
        if (e & JOY_UP) {
            active = active ? active - 1 : n_items - 1;
        } else if (e & JOY_DOWN) {
            active = active < n_items - 1 ? active + 1 : 0;
        } else if ((e & JOY_B) || ((e & JOY_A) && active == 3)) {
            return;
        } else if ((e & JOY_A) && active == 0) {
            video_color = !video_color;
            reg_color_mode = video_color;
            video_config_save();
        } else if ((e & JOY_A) && active == 1) {
            video_zoom = (video_zoom + 1) % 3;
            reg_video_zoom = video_zoom;
            video_config_save();
        } else if ((e & JOY_A) && active == 2) {
            video_scanline = (video_scanline + 1) % 4;
            reg_scanline = video_scanline;
            video_config_save();
        }
        delay(20);
    }
}

// Volume/Bass/Treble sub-menu, reached from "Audio Settings >" in pause_menu.
static void audio_menu(void) {
    static const char *labels[4] = { "Volume", "Bass", "Treble", "Back" };
    int active = 0;
    const int n_items = 4;

    clear();
    print_field(5, 5, "Audio Settings", OSD_COLS - 2);

    for (;;) {
        for (int i = 0; i < n_items; i++) {
            cursor(4, 8 + i);
            putchar(i == active ? '>' : ' ');

            char label[24];
            int j = 0;
            const char *prefix = labels[i];
            while (*prefix)
                label[j++] = *prefix++;

            if (i < 3) {
                int val = (i == 0) ? audio_volume : (i == 1) ? audio_bass : audio_treble;
                char num[4];
                int len;

                label[j++] = ':';
                label[j++] = ' ';
                if (i > 0 && val > 0) {
                    label[j++] = '+';
                } else if (i > 0 && val < 0) {
                    label[j++] = '-';
                    val = -val;
                }
                len = u8_to_str(num, (uint8_t)val);
                for (int k = 0; k < len; k++)
                    label[j++] = num[k];
            }
            label[j] = '\0';

            print_field(6, 8 + i, label, 20);
        }
        selection_row(8 + active);

        uint32_t e = joy_edge();
        if (e & JOY_UP) {
            active = active ? active - 1 : n_items - 1;
        } else if (e & JOY_DOWN) {
            active = active < n_items - 1 ? active + 1 : 0;
        } else if (e & JOY_LEFT) {
            if (active == 0 && audio_volume > 0) {
                audio_volume--;
                audio_apply();
                audio_config_save();
            } else if (active == 1 && audio_bass > -5) {
                audio_bass--;
                audio_apply();
                audio_config_save();
            } else if (active == 2 && audio_treble > -5) {
                audio_treble--;
                audio_apply();
                audio_config_save();
            }
        } else if (e & JOY_RIGHT) {
            if (active == 0 && audio_volume < 10) {
                audio_volume++;
                audio_apply();
                audio_config_save();
            } else if (active == 1 && audio_bass < 5) {
                audio_bass++;
                audio_apply();
                audio_config_save();
            } else if (active == 2 && audio_treble < 5) {
                audio_treble++;
                audio_apply();
                audio_config_save();
            }
        } else if ((e & JOY_B) || ((e & JOY_A) && active == 3)) {
            return;
        }
        delay(20);
    }
}

// Returns non-zero when the player chooses to return to the ROM browser.
static int pause_menu(void) {
    static const char *items[3] = {
        "Resume Game", "Reset Game", "Return to browser"
    };
    int active = 0;
    const int n_items = 6;

    audio_paused = 1;
    audio_apply();
    pce_pause(1);
    clear();
    print_field(5, 5, "Game paused", OSD_COLS - 2);

    for (;;) {
        for (int i = 0; i < n_items; i++) {
            cursor(4, 8 + i);
            putchar(i == active ? '>' : ' ');

            char label[24];

            if (i < 3) {
                print_field(6, 8 + i, items[i], 20);
                continue;
            }

            if (i == 4) {
                print_field(6, 8 + i, "Video Settings >", 20);
                continue;
            }

            if (i == 5) {
                print_field(6, 8 + i, "Audio Settings >", 20);
                continue;
            }

            make_menu_label(label, 3);
            print_field(6, 8 + i, label, 20);
        }
        selection_row(8 + active);

        uint32_t e = joy_edge();
        if (e & JOY_UP) {
            active = active ? active - 1 : n_items - 1;
        } else if (e & JOY_DOWN) {
            active = active < n_items - 1 ? active + 1 : 0;
        } else if ((e & JOY_B) || (e & JOY_MENU) ||
                   ((e & JOY_A) && active == 0)) {
            pce_pause(0);
            audio_paused = 0;
            audio_apply();
            overlay(0);
            return 0;
        } else if ((e & JOY_A) && active == 1) {
            pce_reset();
            delay(20);
            pce_pause(0);
            audio_paused = 0;
            audio_apply();
            overlay(0);
            return 0;
        } else if ((e & JOY_A) && active == 2) {
            pce_stop();
            audio_paused = 0;
            audio_apply();
            return 1;
        } else if ((e & JOY_A) && active == 3) {
            game_pad_mode = !game_pad_mode;
            reg_pad_mode = game_pad_mode;
            game_pad_mode_save(current_game_name); // <--- Sauvegarde dans /config/[nomdujeu].cfg
        } else if ((e & JOY_A) && active == 4) {
            video_menu();
            clear();
            print_field(5, 5, "Game paused", OSD_COLS - 2);
        } else if ((e & JOY_A) && active == 5) {
            audio_menu();
            clear();
            print_field(5, 5, "Game paused", OSD_COLS - 2);
        }
        delay(20);
    }
}

// ---------------------------------------------------------------------------
// PC Engine / SuperGrafx ROM filter
// ---------------------------------------------------------------------------
static int is_rom(const char *name) {
    int n = (int)strlen(name);
    if (n < 5)
        return 0;
    return strcasecmp(name + n - 4, ".pce") == 0 ||
           strcasecmp(name + n - 4, ".sgx") == 0;
}

static int is_cue(const char *name) {
    int n = (int)strlen(name);
    if (n < 5)
        return 0;
    return strcasecmp(name + n - 4, ".cue") == 0;
}

static int is_cd_dir(const char *name) {
    int n = (int)strlen(name);
    if (n < 4)
        return 0;
    return strcasecmp(name + n - 4, "(CD)") == 0 ||
           (n >= 5 && strcasecmp(name + n - 5, " (CD)") == 0);
}

static int is_sgx(const char *name) {
    int n = (int)strlen(name);
    return n >= 5 && strcasecmp(name + n - 4, ".sgx") == 0;
}

static int parse_cue_bin_path(const char *cue_path, char *bin_path, size_t bin_len) {
    FIL f;
    char line[256];
    char *p;
    int found = 0;

    if (f_open(&f, cue_path, FA_READ) != FR_OK)
        return -1;

    bin_path[0] = '\0';

    while (f_gets(line, sizeof(line), &f)) {
        p = line;
        while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')
            p++;

        if (strncasecmp(p, "FILE", 4) != 0)
            continue;

        p += 4;
        while (*p == ' ' || *p == '\t')
            p++;

        if (*p != '"')
            continue;
        p++;

        char *q = p;
        while (*q && *q != '"')
            q++;
        if (*q != '"')
            continue;
        *q = '\0';

        if (strnlen(p, bin_len) >= bin_len)
            continue;

        strncpy(bin_path, p, bin_len - 1);
        bin_path[bin_len - 1] = '\0';
        found = 1;
        break;
    }

    f_close(&f);
    return found ? 0 : -1;
}

// Directories to never show in the browser, regardless of their
// FAT hidden/system attribute.
static const char *hidden_dirs[] = {
    "pcecfg",
    "cheats",
    "gamecfg",
    "config",
    "screenshot",
    NULL
};

static int is_hidden_dir(const char *name) {
    for (int i = 0; hidden_dirs[i]; i++) {
        if (strcasecmp(name, hidden_dirs[i]) == 0)
            return 1;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Directory listing
//
// Fills names[] / is_dir[] / sizes[] with up to `len` entries starting at
// `start`, counting only the entries the menu shows (directories and .PCE or
// .SGX files).  *count receives the total number of such entries.
// Returns 0 on success.
// ---------------------------------------------------------------------------
static int load_dir(const char *dir, int start, int len, int *count) {
    DIR d;
    FILINFO fno;
    int idx = 0;

    page_len = 0;
    *count = 0;

    if (f_opendir(&d, dir) != FR_OK)
        return -1;

    for (;;) {
        if (f_readdir(&d, &fno) != FR_OK)
            break;
        if (fno.fname[0] == 0)
            break;
        if (fno.fattrib & (AM_HID | AM_SYS))
            continue;
        if ((fno.fattrib & AM_DIR) && is_hidden_dir(fno.fname))
            continue;
        if (!(fno.fattrib & AM_DIR) && !is_rom(fno.fname) && !is_cue(fno.fname))
            continue;

        if (idx >= start && page_len < len) {
            strncpy(names[page_len], fno.fname, NAME_MAX - 1);
            names[page_len][NAME_MAX - 1] = '\0';
            is_dir[page_len] = (fno.fattrib & AM_DIR) ? 1 : 0;
            sizes[page_len] = (uint32_t)fno.fsize;
            page_len++;
        }
        idx++;
    }

    f_closedir(&d);
    *count = idx;
    return 0;
}

// ---------------------------------------------------------------------------
// ROM loading
//
// The whole file is streamed to the SDRAM from byte 0, copier header included.
// The hardware derives rom_sz = size >> 16 and rom_offset = 512 when
// (size & 0x3FF) == 0x200, exactly like the UART loader does.
// ---------------------------------------------------------------------------
static int load_rom(const char *fname, uint32_t size) {
    FIL f;
    UINT br;
    uint32_t total = 0;
    int last_pct = -1;
    int is_cue_image = 0;

    char cue_path[PWD_SIZE + NAME_MAX + 2];
    char bin_path[PWD_SIZE + NAME_MAX + 2];

    if (is_cue(fname)) {
        strncpy(cue_path, pwd, sizeof(cue_path));
        if (cue_path[1] != '\0')
            strncat(cue_path, "/", sizeof(cue_path));
        strncat(cue_path, fname, sizeof(cue_path));

        if (parse_cue_bin_path(cue_path, bin_path, sizeof(bin_path)) != 0) {
            message("No BIN inside CUE", fname);
            return -1;
        }

        strncpy(path_buf, pwd, sizeof(path_buf));
        if (path_buf[1] != '\0')
            strncat(path_buf, "/", sizeof(path_buf));
        strncat(path_buf, bin_path, sizeof(path_buf));

        if (f_open(&f, path_buf, FA_READ) != FR_OK) {
            message("Cannot open BIN from CUE", bin_path);
            return -1;
        }
        if ((size = (uint32_t)f_size(&f)) == 0) {
            f_close(&f);
            message("Empty BIN image", bin_path);
            return -1;
        }
        is_cue_image = 1;
    } else {
        if (size < ROM_MIN_SIZE) {
            message("File is too small", "not a HuCard image");
            return -1;
        }
        if (size > ROM_MAX_SIZE) {
            message("File is too large", "4 MiB maximum");
            return -1;
        }

        strncpy(path_buf, pwd, sizeof(path_buf));
        if (path_buf[1] != '\0')
            strncat(path_buf, "/", sizeof(path_buf));
        strncat(path_buf, fname, sizeof(path_buf));

        if (f_open(&f, path_buf, FA_READ) != FR_OK) {
            message("Cannot open", fname);
            return -1;
        }
    }

    uart_printf("loading %s, %d bytes\n", path_buf, (int)size);

    // holds the PC Engine in reset and publishes the image description
    pce_load_start(size, is_sgx(fname) || is_cue_image);

    while (total < size) {
        UINT want = (UINT)((size - total) > sizeof(io_buf) ? sizeof(io_buf)
                                                           : (size - total));
        if (f_read(&f, io_buf, want, &br) != FR_OK || br == 0) {
            pce_load_end();
            f_close(&f);
            message("Read error", fname);
            return -1;
        }

        // pad the tail to a whole word, the hardware only takes 32-bit writes
        while (br & 3)
            io_buf[br++] = 0xff;

        const uint32_t *w = (const uint32_t *)io_buf;
        for (UINT i = 0; i < br; i += 4)
            pce_load_word(*w++);

        total += br;

        int pct = (int)((total >> 8) * 100 / (size >> 8));
        if (pct != last_pct) {
            last_pct = pct;
            clear_line(ROW_STATUS);
            cursor(1, ROW_STATUS);
            printf("Loading %dK / %dK  %d%%",
                   (int)(total >> 10), (int)(size >> 10), pct);
        }
    }

    f_close(&f);

    // Enregistre le nom du jeu actuel
    extract_filename(current_game_name, fname);

    // Charge le mode de manette spécifique au jeu
    game_pad_mode_load(current_game_name);

    // releases the PC Engine once the last byte has reached the SDRAM
    pce_load_end();

    uart_print("load done\n");
    uart_printf("dcc=%d hds=%d hds_px=%d hdw=%d hdw_px=%d\n",
                reg_vid_dcc_dbg(), reg_vid_hds_dbg(), reg_vid_hds_dbg() * 8,
                reg_vid_hdw_dbg(), reg_vid_hdw_dbg() * 8);
    return 0;
}

// ---------------------------------------------------------------------------
// The browser
// ---------------------------------------------------------------------------
static void go_parent(void) {
    char *slash = strrchr(pwd, '/');
    if (!slash)
        return;
    if (slash == pwd)
        pwd[1] = '\0';          // already at the root
    else
        *slash = '\0';
}

static void draw_page(int page, int total, int active) {
    clear();
    title();
    print_field(1, ROW_PATH, pwd, OSD_COLS - 2);

    for (int i = 0; i < PAGESIZE; i++) {
        int y = ROW_FIRST + i;
        clear_line(y);
        if (i >= page_len)
            continue;
        cursor(0, y);
        putchar(i == active ? '>' : ' ');
        cursor(1, y);
        putchar(' ');
        print(names[i]);
        if (is_dir[i])
            putchar('/');
    }

    selection_row(page_len ? ROW_FIRST + active : 31);

    int pages = (total + PAGESIZE - 1) / PAGESIZE;
    if (pages < 1)
        pages = 1;
    clear_line(ROW_STATUS);
    cursor(1, ROW_STATUS);
    if (total == 0)
        print("No .PCE/.SGX/.CUE files here");
    else
        printf("Page %d/%d  A=open B=back", page + 1, pages);
}

static void move_cursor(int old_i, int new_i) {
    cursor(0, ROW_FIRST + old_i);
    putchar(' ');
    cursor(0, ROW_FIRST + new_i);
    putchar('>');
    selection_row(ROW_FIRST + new_i);
}

// Runs the browser until a ROM has been loaded.
static void browse(void) {
    int page = 0;
    int active = 0;
    int total = 0;
    int need_redraw = 1;

    for (;;) {
        if (need_redraw) {
            if (load_dir(pwd, page * PAGESIZE, PAGESIZE, &total) != 0) {
                message("Cannot open directory", pwd);
                strcpy(pwd, "/");
                page = 0;
                active = 0;
                continue;
            }
            int max_active = page_len + 1;   // dernier index = Scanlines
            if (active > max_active)
                active = max_active;
            draw_page(page, total, active);
            need_redraw = 0;
            delay(150);
        }

        uint32_t e = joy_edge();
        if (!e) {
            delay(8);
            continue;
        }

        if ((e & JOY_UP) && page_len) {
            int prev = active;
            active = active ? active - 1 : page_len - 1;
            move_cursor(prev, active);
        } else if ((e & JOY_DOWN) && page_len) {
            int prev = active;
            active = (active + 1 < page_len) ? active + 1 : 0;
            move_cursor(prev, active);
        } else if (e & JOY_LEFT) {
            if (page > 0) {
                page--;
                active = 0;
                need_redraw = 1;
            }
        } else if (e & JOY_RIGHT) {
            if ((page + 1) * PAGESIZE < total) {
                page++;
                active = 0;
                need_redraw = 1;
            }
        } else if (e & JOY_B) {
            if (pwd[1] != '\0') {
                go_parent();
                page = 0;
                active = 0;
                need_redraw = 1;
            }
        } else if (e & JOY_A) {
            if (!page_len)
                continue;
            if (is_dir[active]) {
                if (strlen(pwd) + strlen(names[active]) + 2 < PWD_SIZE) {
                    if (pwd[1] != '\0')
                        strncat(pwd, "/", PWD_SIZE);
                    strncat(pwd, names[active], PWD_SIZE);
                    page = 0;
                    active = 0;
                    need_redraw = 1;
                } else {
                    message("Path is too long", 0);
                    need_redraw = 1;
                }
            } else {
                if (load_rom(names[active], sizes[active]) == 0) {
                    overlay(0);         // hand the screen back to the console
                    return;
                }
                need_redraw = 1;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Mounting
// ---------------------------------------------------------------------------
static int mount_card(void) {
    clear();
    title();
    status("Mounting SD card...");

    for (int attempt = 0; attempt < 3; attempt++) {
        if (sd_init() == 0 && f_mount(&fs, "", 1) == FR_OK)
            return 0;
        delay(300);
    }
    return -1;
}

#define RET_BASE  ((volatile uint32_t *)0x00100000)  /* 64 Ko sous la pile */
#define RET_WORDS 16384u
static uint32_t ret_pat(uint32_t i) { return 0xA5A5A5A5u ^ (i << 7) ^ (i >> 3); }
static void ret_fill(void) { for (uint32_t i = 0; i < RET_WORDS; i++) RET_BASE[i] = ret_pat(i); }
static uint32_t ret_check(void) {
    uint32_t bad = 0;
    for (uint32_t i = 0; i < RET_WORDS; i++) if (RET_BASE[i] != ret_pat(i)) bad++;
    return bad;
}

// ---------------------------------------------------------------------------
int main(void) {
    // 43.2 MHz / 375 = 115200 baud
    uart_init(375);

    uint32_t sp_val;
    __asm__ volatile ("mv %0, sp" : "=r"(sp_val));
    uart_printf("sp=%x io_buf=%x fs=%x\n", sp_val, (uint32_t)io_buf, (uint32_t)&fs);
    
    uart_print("\nPCEtang iosys firmware\n");

    overlay(1);
    clear();
    title();
    status("Starting...");
    delay(200);

    for (;;) {
        if (mount_card() != 0) {
            message("No SD card, or it is not",
                    "FAT16/FAT32/exFAT formatted");
            continue;
        }
        break;
    }

    // Restore the last video and audio settings saved on the SD card.
    video_config_load();
    audio_config_load();

    browse();

    ret_fill(); 
    uint32_t last_ret = time_millis();

    // The console is running now.  Stay alive so the user can bring the menu
    // back with Select+Start and pick another game without a power cycle,
    // Select+Up/Down cycles the display zoom mode and Select+Left/Right
    // cycles the scanline strength.
    // Select must be held for at least 500 ms before it can be used
    // as a modifier for the zoom/scanline shortcuts.
    int select_armed = 0;
    int select_count = 0;

    uint32_t last_hb = time_millis();
    uint32_t last_raw = 0xffffffff;

    for (;;) {
        uint32_t raw = joy_raw();
        uint32_t e = joy_edge();
        static uint32_t loops = 0;

        loops++;
        if (time_millis() - last_hb >= 1000) {
            last_hb += 1000;
            uart_printf("alive loops=%d reg=%x dcc=%d hds=%d hds_px=%d hdw=%d hdw_px=%d\n",
                        (int)loops, reg_joystick, reg_vid_dcc_dbg(),
                        reg_vid_hds_dbg(), reg_vid_hds_dbg() * 8,
                        reg_vid_hdw_dbg(), reg_vid_hdw_dbg() * 8);
            loops = 0;
        }

        if (time_millis() - last_ret >= 10000) {
            last_ret += 10000;
            uart_printf("retention bad=%d\n", (int)ret_check());
            ret_fill();
        }

        if (raw != last_raw) {
            uart_printf("joy %x dcc=%d hds=%d hds_px=%d hdw=%d hdw_px=%d\n",
                        raw, reg_vid_dcc_dbg(), reg_vid_hds_dbg(),
                        reg_vid_hds_dbg() * 8, reg_vid_hdw_dbg(),
                        reg_vid_hdw_dbg() * 8);
            last_raw = raw;
        }

        static uint32_t last_reg = 0xffffffff;
        uint32_t r = reg_joystick;
        if (r != last_reg) { uart_printf("reg %x\n", r); last_reg = r; }

        if (!(raw & JOY_SELECT)) {
            // Select released: require another 500 ms hold next time.
            select_armed = 0;
            select_count = 0;
        } else if (!select_armed) {
            // This loop runs every 20 ms, so 25 iterations = 500 ms.
            if (++select_count >= 25)
                select_armed = 1;
        }

        if ((raw & JOY_MENU) == JOY_MENU) {
            delay(300);                     // let the buttons be released
            overlay(1);
            if (pause_menu()) {
                if (mount_card() != 0) {
                    message("No SD card, or it is not",
                            "FAT16/FAT32/exFAT formatted");
                    overlay(0);
                    continue;
                }
                browse();
            }
        } else if (select_armed &&
                   (raw & JOY_SELECT) &&
                   (e & (JOY_UP | JOY_DOWN))) {
            zoom_cycle();
        } else if (select_armed &&
                   (raw & JOY_SELECT) &&
                   (e & (JOY_LEFT | JOY_RIGHT))) {
            scanline_cycle((e & JOY_RIGHT) ? 1 : -1);
        }
        delay(20);
    }

    return 0;
}