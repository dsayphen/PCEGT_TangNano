//
// HuCard ROM loading (.PCE / .SGX, and the data BIN of a .CUE).
//

#include "common.h"
#include "osd.h"
#include "settings.h"
#include "saves.h"
#include "cd.h"
#include "rom.h"

static char path_buf[PWD_SIZE + NAME_MAX + 2];

// ---------------------------------------------------------------------------
// PC Engine / SuperGrafx ROM filter
// ---------------------------------------------------------------------------
int is_rom(const char *name) {
    int n = (int)strlen(name);
    if (n < 5)
        return 0;
    return strcasecmp(name + n - 4, ".pce") == 0 ||
           strcasecmp(name + n - 4, ".sgx") == 0;
}

int is_cue(const char *name) {
    int n = (int)strlen(name);
    if (n < 5)
        return 0;
    return strcasecmp(name + n - 4, ".cue") == 0;
}

static int is_sgx(const char *name) {
    int n = (int)strlen(name);
    return n >= 5 && strcasecmp(name + n - 4, ".sgx") == 0;
}

static int is_populous_image(FIL *file, uint32_t size) {
    static const uint32_t offsets[2] = { 0x1f26, 0x2126 };
    static const char signature[8] = { 'P', 'O', 'P', 'U', 'L', 'O', 'U', 'S' };

    for (int i = 0; i < 2; i++) {
        UINT br;
        if (size < offsets[i] + sizeof(signature) ||
            f_lseek(file, offsets[i]) != FR_OK)
            continue;
        if (f_read(file, io_buf, sizeof(signature), &br) == FR_OK &&
            br == sizeof(signature) &&
            memcmp(io_buf, signature, sizeof(signature)) == 0) {
            f_lseek(file, 0);
            return 1;
        }
    }
    f_lseek(file, 0);
    return 0;
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

        if (!starts_with_ci_n(p, "FILE", 4))
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

        size_t path_len = strlen(p);
        if (path_len >= bin_len)
            continue;

        strncpy(bin_path, p, bin_len - 1);
        bin_path[bin_len - 1] = '\0';
        found = 1;
        break;
    }

    f_close(&f);
    return found ? 0 : -1;
}

// ---------------------------------------------------------------------------
// ROM loading
//
// The whole file is streamed to the SDRAM from byte 0, copier header included.
// The hardware derives rom_sz = size >> 16 and rom_offset = 512 when
// (size & 0x3FF) == 0x200, exactly like the UART loader does.
// ---------------------------------------------------------------------------
int load_rom(const char *fname, uint32_t size) {
    FIL f;
    UINT br;
    uint32_t total = 0;
    int last_pct = -1;
    int is_cue_image = 0;
    int is_populous = 0;

    char cue_path[PWD_SIZE + NAME_MAX + 2];
    char bin_path[PWD_SIZE + NAME_MAX + 2];

    cd_close();

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

    if (!is_cue_image)
        is_populous = is_populous_image(&f, size);
    reg_rom_pop = is_populous;
    current_game_populous = is_populous;

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
    load_game_saves(current_game_name, current_game_populous);

    // releases the PC Engine once the last byte has reached the SDRAM
    pce_load_end();

    uart_print("load done\n");
    uart_printf("dcc=%d hds=%d hds_px=%d hdw=%d hdw_px=%d\n",
                reg_vid_dcc_dbg(), reg_vid_hds_dbg(), reg_vid_hds_dbg() * 8,
                reg_vid_hdw_dbg(), reg_vid_hdw_dbg() * 8);
    return 0;
}
