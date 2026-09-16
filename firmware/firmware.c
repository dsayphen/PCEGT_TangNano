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
//   Select+Start  pause a running game and open the pause menu (transparent
//                 OSD): Resume / Video Settings / Reset Game / Return to
//                 Browser
//   Select+Up/Down    cycle the display zoom (2x / stretch) over a running game
//   Select+Left/Right cycle the scanline strength (0/25/50/100%) over a running game
//

#include "picorv32.h"
#include "fatfs/ff.h"
#include "font8x8.h"

// TODO: move alongside reg_video_zoom / reg_scanline in picorv32.h.
// See rtl/tang/iosys/iosys.v for the register semantics.
#define reg_pause       (*(volatile uint32_t*)0x02000054)  // bit0: freeze HuC6280
#define reg_soft_reset  (*(volatile uint32_t*)0x02000058)  // any write pulses core_reset

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
    print("PC-Engine / SuperGrafx");
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

#define VIDEO_CFG_FILE    "/video.cfg"
#define GAME_CFG_DIR      "/pcecfg"
#define CHEAT_DIR         "/cheat"
#define MAX_CHEATS        32
#define CHEAT_CODE_MAX    256

static int video_zoom = 1;       // hardware reset default: stretch
static int video_scanline = 0;   // hardware reset default: off
static int game_pad_mode = 0;     // 0 = 2-button pad, 1 = 6-button pad
static int cheat_count = 0;
static char current_game_cfg[PWD_SIZE];
static char cheat_codes[MAX_CHEATS][CHEAT_CODE_MAX];
static char cheat_desc[MAX_CHEATS][NAME_MAX];
static uint8_t cheat_enabled[MAX_CHEATS];

static void strip_extension(char *name) {
    char *dot = strrchr(name, '.');
    if (dot && strchr(dot, '/'))
        return;
    if (dot)
        *dot = '\0';
}

static void build_game_cfg_path(const char *rom_name, char *out, int out_size) {
    char base[NAME_MAX];
    const char *p = strrchr(rom_name, '/');
    const char *n = p ? p + 1 : rom_name;
    const int len = (int)strlen(n);
    int i = 0;

    while (i < len && i < (int)sizeof(base) - 1 && n[i] != '.') {
        base[i] = n[i];
        i++;
    }
    base[i] = '\0';

    if (out_size <= 0)
        return;
    strcpy(out, GAME_CFG_DIR);
    strncat(out, "/", out_size - strlen(out));
    strncat(out, base, out_size - strlen(out));
    strncat(out, ".cfg", out_size - strlen(out));
}

static void build_game_cheat_path(const char *rom_name, char *out, int out_size) {
    char base[NAME_MAX];
    const char *p = strrchr(rom_name, '/');
    const char *n = p ? p + 1 : rom_name;
    int i = 0;

    while (n[i] && n[i] != '.' && i < (int)sizeof(base) - 1) {
        base[i] = n[i];
        i++;
    }
    base[i] = '\0';
    if (out_size <= 0)
        return;
    strcpy(out, CHEAT_DIR);
    strncat(out, "/", out_size - strlen(out));
    strncat(out, base, out_size - strlen(out));
    strncat(out, ".cht", out_size - strlen(out));
}

static int hex_digit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int parse_hex(const char *s, const char **end, uint32_t *value) {
    uint32_t v = 0;
    int digits = 0;
    while (hex_digit(*s) >= 0) {
        v = (v << 4) | (uint32_t)hex_digit(*s++);
        digits++;
    }
    if (end) *end = s;
    if (value) *value = v;
    return digits != 0;
}

static int cheat_index_and_field(char *line, int *index, char **field) {
    char *p = line + 5;
    int n = 0;
    if (!starts_with(line, "cheat") || *p < '0' || *p > '9')
        return 0;
    while (*p >= '0' && *p <= '9')
        n = n * 10 + (*p++ - '0');
    if (*p++ != '_' || n >= MAX_CHEATS)
        return 0;
    *index = n;
    *field = p;
    return 1;
}

static char *cheat_field_value(char *field, const char *name) {
    while (*field == ' ' || *field == '\t') field++;
    if (!starts_with(field, name))
        return 0;
    field += strlen(name);
    while (*field == ' ' || *field == '\t') field++;
    if (*field++ != '=')
        return 0;
    while (*field == ' ' || *field == '\t') field++;
    return field;
}

static int parse_bool(const char *value) {
    return starts_with(value, "true") || starts_with(value, "1");
}

static void cheat_hw_reset(void) {
    reg_cheat_cmd = 2;
}

static void cheat_hw_load(uint32_t address, uint8_t value) {
    reg_cheat_code0 = value;
    reg_cheat_code1 = 0;
    reg_cheat_code2 = address & 0x001fffff;
    reg_cheat_code3 = 0;
    reg_cheat_cmd = 1;
}

static void apply_cheats_to_hw(void) {
    int any_enabled = 0;

    reg_cheat_enable = 0;
    cheat_hw_reset();
    for (int i = 0; i < cheat_count; i++) {
        if (!cheat_enabled[i])
            continue;
        any_enabled = 1;
        const char *p = cheat_codes[i];
        while (*p) {
            uint32_t address;
            uint32_t value;
            const char *end;
            if (!parse_hex(p, &end, &address) || *end != ':') break;
            p = end + 1;
            if (!parse_hex(p, &end, &value) || value > 0xff || address > 0x1fffff)
                break;
            cheat_hw_load(address, (uint8_t)value);
            p = (*end == '+') ? end + 1 : end;
        }
    }
    reg_cheat_enable = any_enabled;
}

static void load_cheat_file(const char *rom_name) {
    FIL file;
    char line[CHEAT_CODE_MAX + 32];
    char path[PWD_SIZE];
    int index;
    char *field;

    cheat_count = 0;
    memset(cheat_codes, 0, sizeof(cheat_codes));
    memset(cheat_desc, 0, sizeof(cheat_desc));
    memset(cheat_enabled, 0, sizeof(cheat_enabled));
    build_game_cheat_path(rom_name, path, sizeof(path));
    if (f_open(&file, path, FA_READ) != FR_OK)
        return;

    while (f_gets(line, sizeof(line), &file)) {
        if (!cheat_index_and_field(line, &index, &field))
            continue;
        char *value = cheat_field_value(field, "code");
        if (value) {
            while (*value == '\"') value++;
            int i = 0;
            while (*value && *value != '\"' && *value != '\r' && *value != '\n' &&
                   i < CHEAT_CODE_MAX - 1)
                cheat_codes[index][i++] = *value++;
            cheat_codes[index][i] = '\0';
        }
        value = cheat_field_value(field, "desc");
        if (value) {
            while (*value == '\"') value++;
            int i = 0;
            while (*value && *value != '\"' && *value != '\r' && *value != '\n' &&
                   i < NAME_MAX - 1)
                cheat_desc[index][i++] = *value++;
            cheat_desc[index][i] = '\0';
        }
        value = cheat_field_value(field, "enable");
        if (value)
            cheat_enabled[index] = parse_bool(value);
        if (index + 1 > cheat_count)
            cheat_count = index + 1;
    }
    f_close(&file);
}

static int detect_6button_game(const char *rom_name) {
    const char *n = strrchr(rom_name, '/');
    const char *name = n ? n + 1 : rom_name;
    static const char *known[] = {
        "street fighter ii",
        "advanced variable geo",
        "battlefield",
        "emerald",
        "fire pro jyoshi",
        "wresling universe",
        "flash hiders",
        "garou densetsu",
        "kakutou haou densetsu",
        "linda cube",
        "mahjong sword",
        "martial champions",
        "princess maker 2",
        "ryuuko no ken",
        "sotsugyou ii",
        "super real mahjong p",
        "tengai makyo",
        "world heroes 2",
        "ys iv",
        "darius",
        "ddragon",
        "cadash",
        "wonderboy",
        "gradius",
        "final fight"
    };
    for (int i = 0; i < (int)(sizeof(known) / sizeof(known[0])); i++) {
        if (strcasestr(name, known[i]))
            return 1;
    }
    return 0;
}

static int game_pad_mode_load(const char *rom_name) {
    FIL file;
    char line[64];
    char cfg_path[PWD_SIZE];
    int mode = detect_6button_game(rom_name);

    build_game_cfg_path(rom_name, cfg_path, sizeof(cfg_path));
    strcpy(current_game_cfg, cfg_path);

    if (f_mkdir(GAME_CFG_DIR) != FR_OK && f_mkdir(GAME_CFG_DIR) != FR_EXIST) {
        // keep the default and continue; the SD may be read-only
    }

    if (f_open(&file, cfg_path, FA_READ) != FR_OK) {
        return mode;
    }

    memset(cheat_enabled, 0, sizeof(cheat_enabled));

    while (f_gets(line, sizeof(line), &file)) {
        if (line[0] == '#' || line[0] == '\r' || line[0] == '\n' || line[0] == '\0')
            continue;
        if (starts_with(line, "pad_mode=")) {
            mode = (parse_u8(line + 9) != 0);
        } else if (line[0] == 'c' && line[1] == 'h' && line[2] == 'e' &&
                   line[3] == 'a' && line[4] == 't' && line[5] >= '0' &&
                   line[5] <= '9') {
            int index = parse_u8(line + 5);
            char *equals = strchr(line, '=');
            if (equals && index < cheat_count)
                cheat_enabled[index] = (parse_u8(equals + 1) != 0);
        }
    }

    f_close(&file);
    return mode;
}

static void game_pad_mode_save(void) {
    FIL file;
    UINT bw;
    char cfg_path[PWD_SIZE];

    if (current_game_cfg[0] == '\0')
        return;
    strcpy(cfg_path, current_game_cfg);

    if (f_mkdir(GAME_CFG_DIR) != FR_OK && f_mkdir(GAME_CFG_DIR) != FR_EXIST) {
        return;
    }

    if (f_open(&file, cfg_path, FA_WRITE | FA_CREATE_ALWAYS) != FR_OK)
        return;

    f_write(&file, "# PC Engine game settings\n", 26, &bw);
    f_write(&file, "pad_mode=", 9, &bw);
    if (game_pad_mode)
        f_write(&file, "1\n", 2, &bw);
    else
        f_write(&file, "0\n", 2, &bw);
    for (int i = 0; i < cheat_count; i++) {
        if (!cheat_enabled[i])
            continue;
        char index = (char)('0' + i);
        f_write(&file, "cheat", 5, &bw);
        if (i >= 10) {
            char tens = (char)('0' + i / 10);
            f_write(&file, &tens, 1, &bw);
        }
        index = (char)('0' + i % 10);
        f_write(&file, &index, 1, &bw);
        f_write(&file, "=", 1, &bw);
        f_write(&file, cheat_enabled[i] ? "1\n" : "0\n", 2, &bw);
    }

    f_close(&file);
}

static void apply_pad_mode_to_hw(void) {
    reg_pad_mode = game_pad_mode ? 1u : 0u;
}

static void video_config_load(void) {
    FIL file;
    char line[64];

    if (f_open(&file, "/video.cfg", FA_READ) != FR_OK) {
        return; // Conserve les valeurs par défaut si le fichier n'existe pas encore
    }

    // f_gets fonctionne parfaitement maintenant grâce à FF_USE_STRFUNC = 1
    while (f_gets(line, sizeof(line), &file)) {
        // Ignore les commentaires (#), les lignes vides et les saut de ligne
        if (line[0] == '#' || line[0] == '\r' || line[0] == '\n' || line[0] == '\0') {
            continue;
        }

        if (starts_with(line, "reg_video_zoom=")) {
            reg_video_zoom = parse_u8(line + 15);
        } else if (starts_with(line, "reg_scanline=")) {
            reg_scanline = parse_u8(line + 13);
        }
    }

    f_close(&file);
}

static void video_config_save(void) {
    FIL file;
    UINT bw;
    char num[4];
    int len;

    if (f_open(&file, "/video.cfg", FA_WRITE | FA_CREATE_ALWAYS) != FR_OK) {
        return;
    }

    // Commentaires explicatifs rédigés directement dans le fichier CFG
    const char *header = 
        "# PCEngine / SuperGrafx Video Settings\n"
        "# -----------------------------------\n"
        "# reg_video_zoom :\n"
        "#   0 = Original / Integer Scale (1x)\n"
        "#   1 = Stretched / Fit Screen (Full)\n"
        "#\n"
        "# reg_scanline :\n"
        "#   0 = Off (No Scanlines)\n"
        "#   1 = 25% Intensity\n"
        "#   2 = 50% Intensity\n"
        "#   3 = 100% Intensity\n"
        "# -----------------------------------\n";

    f_write(&file, header, (UINT)strlen(header), &bw); // Écrit la documentation complète

    // Écriture de reg_video_zoom
    f_write(&file, "reg_video_zoom=", 15, &bw);
    len = u8_to_str(num, reg_video_zoom);
    f_write(&file, num, len, &bw);
    f_write(&file, "\n", 1, &bw);

    // Écriture de reg_scanline
    f_write(&file, "reg_scanline=", 13, &bw);
    len = u8_to_str(num, reg_scanline);
    f_write(&file, num, len, &bw);
    f_write(&file, "\n", 1, &bw);

    f_close(&file);
}

// Cycle the display zoom mode (2x -> stretch -> ...) and flash the new
// setting on the OSD for a moment.  Kept in sync with rtl/tang/iosys/iosys.v
// (reg_video_zoom) and rtl/tang/video_scandoubler.v.
static void zoom_cycle(void) {
    static const char *names[2] = { "Zoom: Integer", "Zoom: Stretch" };

    video_zoom = (video_zoom + 1) % 2;
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

static int is_sgx(const char *name) {
    int n = (int)strlen(name);
    return n >= 5 && strcasecmp(name + n - 4, ".sgx") == 0;
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
        if (!(fno.fattrib & AM_DIR) && !is_rom(fno.fname))
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

    build_game_cfg_path(fname, current_game_cfg, sizeof(current_game_cfg));
    load_cheat_file(fname);
    game_pad_mode = game_pad_mode_load(fname);
    apply_cheats_to_hw();
    apply_pad_mode_to_hw();

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

    uart_printf("loading %s, %d bytes\n", path_buf, (int)size);

    // holds the PC Engine in reset and publishes the image description
    pce_load_start(size, is_sgx(fname));

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

    // releases the PC Engine once the last byte has reached the SDRAM
    pce_load_end();

    uart_print("load done\n");
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
        if (is_dir[i])
            putchar('/');
        else
            putchar(' ');
        print_field(2, y, names[i], OSD_COLS - 2);
    }
    selection_row(page_len ? ROW_FIRST + active : 31);

    int pages = (total + PAGESIZE - 1) / PAGESIZE;
    if (pages < 1)
        pages = 1;
    clear_line(ROW_STATUS);
    cursor(1, ROW_STATUS);
    if (total == 0)
        print("     -- NO PCE/SGX ROMS --");
    else
        printf("Page %d/%d  1=OK 2=Back", page + 1, pages);
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
            if (active >= page_len)
                active = page_len ? page_len - 1 : 0;
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

// Pulses the core reset. The SDRAM still holds the last loaded ROM, so this
// is equivalent to pressing a physical Reset button - no reload from SD.
static void reset_core(void) {
    reg_soft_reset = 1;
}

// Small video settings screen reachable from the pause menu. Adjusts the
// same reg_video_zoom / reg_scanline state (and .cfg file) as the
// Select+Up/Down/Left/Right shortcuts; kept separate from zoom_cycle() /
// scanline_cycle() because those flash their own transient overlay, which
// would fight with the pause menu that is already on screen.
static void video_settings_menu(void) {
    static const char *zoom_names[2] = { "Zoom: Integer", "Zoom: Stretch" };
    static const char *scan_names[4] = {
        "Scanlines: off", "Scanlines: 25%", "Scanlines: 50%", "Scanlines: 100%"
    };
    int selected = 0;
    const int item_count = 2;

    for (;;) {
        clear();
        cursor(2, 1);
        print("=== VIDEO SETTINGS ===");

        cursor(2, 3);
        print(selected == 0 ? "> " : "  ");
        print(zoom_names[video_zoom]);

        cursor(2, 4);
        print(selected == 1 ? "> " : "  ");
        print(scan_names[video_scanline]);

        cursor(2, 6);
        print("Left/Right: change   B: back");

        uint32_t e = joy_edge();

        if (e & JOY_UP) {
            selected = (selected - 1 + item_count) % item_count;
        } else if (e & JOY_DOWN) {
            selected = (selected + 1) % item_count;
        } else if (e & (JOY_LEFT | JOY_RIGHT | JOY_A)) {
            int dir = (e & JOY_LEFT) ? -1 : 1;
            if (selected == 0) {
                video_zoom = (video_zoom + 1) % 2;
                reg_video_zoom = video_zoom;
            } else {
                video_scanline = (video_scanline + dir + 4) % 4;
                reg_scanline = video_scanline;
            }
            video_config_save();
        } else if (e & JOY_B) {
            break;
        }

        delay(20);
    }
}

static void cheat_menu(void) {
    int selected = 0;
    const int visible = 15;

    for (;;) {
        int page = selected / visible;
        int first = page * visible;
        int last = first + visible;
        if (last > cheat_count)
            last = cheat_count;

        clear();
        cursor(2, 1);
        print("=== CHEATS ===");
        if (cheat_count == 0) {
            cursor(2, 8);
            print("No cheats found");
        } else {
            for (int i = first; i < last; i++) {
                int y = 3 + i - first;
                cursor(0, y);
                putchar(i == selected ? '>' : ' ');
                print_field(2, y, cheat_desc[i][0] ? cheat_desc[i] : "Unnamed cheat", 25);
                cursor(29, y);
                print(cheat_enabled[i] ? "ON" : "--");
            }
        }
        cursor(1, 19);
        print("A: toggle   B: back");

        uint32_t e = joy_edge();
        if (e & JOY_UP) {
            selected = selected ? selected - 1 : (cheat_count ? cheat_count - 1 : 0);
        } else if (e & JOY_DOWN) {
            selected = (cheat_count && selected + 1 < cheat_count) ? selected + 1 : 0;
        } else if (e & (JOY_A | JOY_LEFT | JOY_RIGHT)) {
            if (cheat_count) {
                cheat_enabled[selected] = !cheat_enabled[selected];
                apply_cheats_to_hw();
                game_pad_mode_save();
            }
        } else if (e & JOY_B) {
            break;
        }
        delay(20);
    }
}

// Affiche et gère le menu in-game suspendu (Select+Start).
// Returns 1 if the caller should go back to the ROM browser, 0 to keep
// running the current game.
static int ingame_menu(void) {
    int selected = 0;
    const int item_count = 6;
    static const char *pad_menu_names[2] = { "Pad: 2 Buttons", "Pad: 6 Buttons" };

    reg_pause = 1;      // freeze the HuC6280 - VDC keeps scanning the same
    overlay(1);         // VRAM out, so the picture just holds still

    for (;;) {
        clear();

        cursor(2, 1);
        print("=== GAME PAUSED ===");

        cursor(2, 3);
        print(selected == 0 ? "> 1. Resume Game" : "  1. Resume Game");

        cursor(2, 4);
        print(selected == 1 ? "> 2. Video Settings" : "  2. Video Settings");

        cursor(2, 5);
        print(selected == 2 ? "> 3. Reset Game" : "  3. Reset Game");

        cursor(2, 6);
        print(selected == 3 ? "> 4. Return to Browser" : "  4. Return to Browser");

        cursor(2, 7);
        print(selected == 4 ? "> 5. Pad Mode" : "  5. Pad Mode");
        cursor(14, 7);
        print(pad_menu_names[game_pad_mode]);

        cursor(2, 8);
        print(selected == 5 ? "> 6. Cheat Menu" : "  6. Cheat Menu");
        cursor(14, 8);
        print(cheat_count ? "Available" : "Not found");

        uint32_t e = joy_edge();

        if (e & JOY_UP) {
            selected = (selected - 1 + item_count) % item_count;
        } else if (e & JOY_DOWN) {
            selected = (selected + 1) % item_count;
        } else if (e & (JOY_LEFT | JOY_RIGHT | JOY_A | JOY_START)) {
            if (selected == 0) {
                break;
            } else if (selected == 1) {
                video_settings_menu();
            } else if (selected == 2) {
                reset_core();
                break;
            } else if (selected == 3) {
                clear();
                overlay(0);
                reg_pause = 0;
                return 1;
            } else if (selected == 4) {
                game_pad_mode = (game_pad_mode + ((e & JOY_RIGHT) ? 1 : -1) + 2) % 2;
                apply_pad_mode_to_hw();
                game_pad_mode_save();
                delay(100);
            } else {
                cheat_menu();
            }
        } else if (e & JOY_B) {
            break;
        }

        delay(20);
    }

    clear();
    overlay(0);
    reg_pause = 0;
    return 0;
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

// ---------------------------------------------------------------------------
int main(void) {
    // 43.2 MHz / 375 = 115200 baud
    uart_init(375);
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

    // Restore the last video settings saved on the SD card.
    video_config_load();

    browse();

    // The console is running now.  Stay alive so the user can bring the menu
    // back with Select+Start and pick another game without a power cycle,
    // Select+Up/Down cycles the display zoom mode and Select+Left/Right
    // cycles the scanline strength.
    // Select must be held for at least 500 ms before it can be used
    // as a modifier for the zoom/scanline shortcuts.
    int select_armed = 0;
    int select_count = 0;

    for (;;) {
        uint32_t raw = joy_raw();
        uint32_t e = joy_edge();

        if (!(raw & JOY_SELECT)) {
            // Select released: require another 500 ms hold next time.
            select_armed = 0;
            select_count = 0;
        } else if (!select_armed) {
            // This loop runs every 20 ms, so 25 iterations = 500 ms.
            if (++select_count >= 25)
                select_armed = 1;
        }

        if (select_armed &&
                   (raw & JOY_SELECT) &&
                   (e & (JOY_UP | JOY_DOWN))) {
            zoom_cycle();
        } else if (select_armed &&
                   (raw & JOY_SELECT) &&
                   (e & (JOY_LEFT | JOY_RIGHT))) {
            scanline_cycle((e & JOY_RIGHT) ? 1 : -1);
        } else if (select_armed &&
                   (raw & JOY_SELECT) &&
                   (e & (JOY_START))) {
            // Select+Start: pause the game and open the pause menu.
            if (ingame_menu()) {
                // "Return to Browser" was picked: browse() blocks until a
                // new game is loaded, then we fall straight back into this
                // same loop for the newly running game.
                browse();
                select_armed = 0;
                select_count = 0;
            }
        }

        delay(20);
    }

    return 0;
}