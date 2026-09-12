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
    print("PCEtang - pick a ROM");
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

// Cycle the display zoom mode (2x -> stretch -> ...) and flash the new
// setting on the OSD for a moment.  Kept in sync with rtl/tang/iosys/iosys.v
// (reg_video_zoom) and rtl/tang/video_scandoubler.v.
static void zoom_cycle(void) {
    static const char *names[2] = { "Zoom: 2x", "Zoom: stretch" };
    static int zoom = 1;         // matches the hardware reset default (stretch)

    zoom = (zoom + 1) % 2;
    reg_video_zoom = zoom;

    clear();
    print_field(1, 10, names[zoom], OSD_COLS - 2);
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
    static int level = 0;        // matches the hardware reset default (off)

    level = (level + dir + 4) % 4;
    reg_scanline = level;

    clear();
    print_field(1, 10, names[level], OSD_COLS - 2);
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
        print("No .PCE/.SGX files here");
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

    browse();

    // The console is running now.  Stay alive so the user can bring the menu
    // back with Select+Start and pick another game without a power cycle,
    // Select+Up/Down cycles the display zoom mode and Select+Left/Right
    // cycles the scanline strength.
    for (;;) {
        uint32_t raw = joy_raw();
        uint32_t e = joy_edge();

        if ((raw & JOY_MENU) == JOY_MENU) {
            delay(300);                     // let the buttons be released
            overlay(1);
            if (mount_card() != 0) {
                message("No SD card, or it is not",
                        "FAT16/FAT32/exFAT formatted");
                overlay(0);
                continue;
            }
            browse();
        } else if ((raw & JOY_SELECT) && (e & (JOY_UP | JOY_DOWN))) {
            zoom_cycle();
        } else if ((raw & JOY_SELECT) && (e & (JOY_LEFT | JOY_RIGHT))) {
            scanline_cycle((e & JOY_RIGHT) ? 1 : -1);
        }
        delay(20);
    }

    return 0;
}
