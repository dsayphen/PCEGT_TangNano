//
// SD card file browser.
//

#include "common.h"
#include "osd.h"
#include "rom.h"
#include "cd.h"
#include "browser.h"

char pwd[PWD_SIZE] = "/";
static char names[PAGESIZE][NAME_MAX];
static uint8_t is_dir[PAGESIZE];
static uint32_t sizes[PAGESIZE];
static int page_len;            // entries actually on this page

// Directories to never show in the browser, regardless of their
// FAT hidden/system attribute.
static const char *hidden_dirs[] = {
    "pcecfg",
    "cheats",
    "gamecfg",
    "config",
    "saves",
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

typedef struct {
    char name[FF_LFN_BUF + 1];
    uint32_t size;
    uint8_t is_dir;
} BrowserEntry;

static int is_visible_entry(const FILINFO *fno) {
    if (fno->fattrib & (AM_HID | AM_SYS))
        return 0;
    if ((fno->fattrib & AM_DIR) && is_hidden_dir(fno->fname))
        return 0;
    if (!(fno->fattrib & AM_DIR) && !is_rom(fno->fname) && !is_cue(fno->fname))
        return 0;
    return 1;
}

static int compare_entry(const BrowserEntry *a, const BrowserEntry *b) {
    int result;

    if (a->is_dir != b->is_dir)
        return a->is_dir ? -1 : 1;
    result = strcasecmp(a->name, b->name);
    if (result != 0)
        return result;
    return strcmp(a->name, b->name);
}

static void copy_entry(BrowserEntry *entry, const FILINFO *fno) {
    strcpy(entry->name, fno->fname);
    entry->size = (uint32_t)fno->fsize;
    entry->is_dir = (fno->fattrib & AM_DIR) ? 1 : 0;
}

static int select_next_entries(const char *dir, const BrowserEntry *after,
                               BrowserEntry *entries, int max_entries,
                               int *visible_count) {
    DIR d;
    FILINFO fno;
    FRESULT result;
    int selected = 0;

    if (visible_count)
        *visible_count = 0;
    if (f_opendir(&d, dir) != FR_OK)
        return -1;

    for (;;) {
        BrowserEntry entry;
        int pos;

        result = f_readdir(&d, &fno);
        if (result != FR_OK) {
            f_closedir(&d);
            return -1;
        }
        if (fno.fname[0] == 0)
            break;
        if (!is_visible_entry(&fno))
            continue;
        if (visible_count)
            (*visible_count)++;

        copy_entry(&entry, &fno);
        if (after && compare_entry(&entry, after) <= 0)
            continue;

        for (pos = 0; pos < selected; pos++) {
            if (compare_entry(&entry, &entries[pos]) < 0)
                break;
        }
        if (pos >= max_entries)
            continue;
        if (selected < max_entries)
            selected++;
        for (int i = selected - 1; i > pos; i--)
            entries[i] = entries[i - 1];
        entries[pos] = entry;
    }

    f_closedir(&d);
    return selected;
}

// ---------------------------------------------------------------------------
// Directory listing
//
// Fills names[] / is_dir[] / sizes[] with up to `len` entries starting at
// `start` in the global sorted order. *count receives the total number of
// entries shown by the menu.
// Returns 0 on success.
// ---------------------------------------------------------------------------
static int load_dir(const char *dir, int start, int len, int *count) {
    BrowserEntry selected[PAGESIZE];
    BrowserEntry after;
    int have_after = 0;
    int idx = 0;

    page_len = 0;
    *count = 0;

    while (page_len < len) {
        int selected_count = select_next_entries(
            dir, have_after ? &after : NULL, selected, PAGESIZE,
            have_after ? NULL : count);
        if (selected_count < 0)
            return -1;
        if (selected_count == 0)
            break;

        for (int i = 0; i < selected_count; i++, idx++) {
            if (idx < start)
                continue;
            strncpy(names[page_len], selected[i].name, NAME_MAX - 1);
            names[page_len][NAME_MAX - 1] = '\0';
            is_dir[page_len] = selected[i].is_dir;
            sizes[page_len] = selected[i].size;
            page_len++;
            if (page_len == len)
                break;
        }

        after = selected[selected_count - 1];
        have_after = 1;
        if (selected_count < PAGESIZE)
            break;
    }

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
void browse(void) {
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

                    if (is_cd_dir(names[active])) {
                        char cue_name[NAME_MAX];
                        if (find_cd_cue(cue_name, sizeof(cue_name)) == 0 &&
                            open_cd_image(cue_name) == 0) {
                            overlay(0);
                            uart_printf("browser: CD started, overlay=%d\n", overlay_status());
                            return;
                        }
                        go_parent();
                    }
                    page = 0;
                    active = 0;
                    need_redraw = 1;
                } else {
                    message("Path is too long", 0);
                    need_redraw = 1;
                }
            } else {
                int loaded = is_cue(names[active])
                    ? open_cd_image(names[active])
                    : load_rom(names[active], sizes[active]);
                if (loaded == 0) {
                    overlay(0);         // hand the screen back to the console
                    uart_printf("browser: launch ok cd=%d overlay=%d\n",
                                cd_active, overlay_status());
                    return;
                }
                need_redraw = 1;
            }
        }
    }
}
