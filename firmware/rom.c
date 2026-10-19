//
// Cartridge ROM loading and HuCard-compatible BIN data referenced by CUE.
//

#include "common.h"
#include "osd.h"
#include "settings.h"
#include "saves.h"
#include "cd.h"
#include "rom.h"
#include "cheats.h"

static char path_buf[PWD_SIZE + NAME_MAX + 2];

// ---------------------------------------------------------------------------
// Cartridge extension filters (MD BIN candidates still require a SEGA header).
// ---------------------------------------------------------------------------
int is_rom(const char *name) {
    int n = (int)strlen(name);
    if (n < 4)
        return 0;
    return (n >= 5 && (strcasecmp(name + n - 4, ".pce") == 0 ||
                      strcasecmp(name + n - 4, ".sgx") == 0)) || is_snes(name) ||
           is_nes(name) || is_gameboy(name) || is_megadrive(name);
}

int is_snes(const char *name) {
    int length = (int)strlen(name);
    return length >= 5 &&
           (strcasecmp(name + length - 4, ".sfc") == 0 ||
            strcasecmp(name + length - 4, ".smc") == 0);
}

int is_nes(const char *name) {
    int length = (int)strlen(name);
    return length >= 5 && strcasecmp(name + length - 4, ".nes") == 0;
}

int is_gameboy(const char *name) {
    int length = (int)strlen(name);
    return (length >= 4 && strcasecmp(name + length - 3, ".gb") == 0) ||
           (length >= 5 && strcasecmp(name + length - 4, ".gbc") == 0);
}

int is_cue(const char *name) {
    int n = (int)strlen(name);
    if (n < 5)
        return 0;
    return strcasecmp(name + n - 4, ".cue") == 0;
}

int is_megadrive(const char *name) {
    int length = (int)strlen(name);
    return (length >= 4 && strcasecmp(name + length - 3, ".md") == 0) ||
           (length >= 5 && (strcasecmp(name + length - 4, ".gen") == 0 ||
                            strcasecmp(name + length - 4, ".bin") == 0));
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

static int decimal_width(uint32_t value) {
    int width = 1;
    while (value >= 10) {
        value /= 10;
        width++;
    }
    return width;
}

static void print_padded_decimal(uint32_t value, int width) {
    uint32_t divisor = 1;

    for (int i = 1; i < width; i++)
        divisor *= 10;
    while (divisor) {
        putchar('0' + (int)(value / divisor) % 10);
        divisor /= 10;
    }
}

static void show_rom_progress(uint32_t loaded, uint32_t size) {
    uint32_t loaded_kb = (loaded + 1023) >> 10;
    uint32_t size_kb = (size + 1023) >> 10;
    int width = decimal_width(size_kb);
    int percent = (int)(loaded * 100 / size);

    if (loaded_kb > size_kb)
        loaded_kb = size_kb;
    if (percent > 100)
        percent = 100;

    clear_line(ROW_PROGRESS);
    cursor(1, ROW_PROGRESS);
    print("Loading ROM ");
    print_padded_decimal(loaded_kb, width);
    putchar('/');
    print_padded_decimal(size_kb, width);
    printf(" KB %d%%", percent);
    progress_bar(percent);
}

static int snes_header_read(FIL *file, uint32_t offset, uint32_t size,
                            int hirom) {
    UINT read;
    uint32_t position = offset + (hirom ? 0xffc0u : 0x7fc0u);
    if (f_lseek(file, position) != FR_OK ||
        f_read(file, io_buf, 64, &read) != FR_OK || read != 64)
        return -1;

    uint32_t rom_exponent = io_buf[23];
    uint32_t ram_exponent = io_buf[24];
    uint32_t reset = io_buf[60] | ((uint32_t)io_buf[61] << 8);
    uint32_t checksum = io_buf[28] | ((uint32_t)io_buf[29] << 8);
    uint32_t complement = io_buf[30] | ((uint32_t)io_buf[31] << 8);
    uint8_t mapper = io_buf[21];
    if (rom_exponent >= 14 || ram_exponent > 7 || reset < 0x8000u ||
        (hirom ? (mapper & 3) != 1 : (mapper & 3) != 0 && mapper != 0x53))
        return -1;

    int ascii_name = 1;
    for (int index = 0; index < 21; index++) {
        if (io_buf[index] < 32 || io_buf[index] > 127)
            ascii_name = 0;
    }
    int score = ((1024u << rom_exponent) >= size) + (rom_exponent == 1) +
                (checksum + complement == 0xffffu) + ascii_name;
    return score ? 0 : -1;
}

static int snes_chip_supported(void) {
    uint8_t chip = io_buf[22];
    return chip != 0x13 && chip != 0x14 && chip != 0x15 && chip != 0x1a &&
           chip != 0x32 && chip != 0x34 && chip != 0x35 && chip != 0x43 &&
           chip != 0x45 && chip != 0xf3 && chip != 0xf5 && chip != 0xf6 &&
           chip != 0xf9;
}

static int load_snes_rom(const char *fname, uint32_t size) {
    FIL file;
    UINT read;
    uint32_t offset = (size & 0x3ffu) == 0x200u ? 512u : 0u;
    uint32_t payload = size - offset;
    uint32_t total = 0;
    int last_percent = -1;
    if (CORE_PROFILE_ID != CORE_PROFILE_SNES ||
        (size & 0x3ffu) != offset || payload < 32768u || payload > 0x3c0000u) {
        message("Unsupported SNES image", "32 KiB to 3.75 MiB maximum");
        return -1;
    }

    cd_close();
    strcpy(path_buf, pwd);
    if (pwd[1])
        strcat(path_buf, "/");
    strcat(path_buf, fname);
    if (f_open(&file, path_buf, FA_READ) != FR_OK) {
        message("Cannot open", fname);
        return -1;
    }
    if (snes_header_read(&file, offset, payload, 0) != 0 &&
        snes_header_read(&file, offset, payload, 1) != 0) {
        f_close(&file);
        message("Invalid SNES header", fname);
        return -1;
    }
    if (!snes_chip_supported()) {
        f_close(&file);
        message("Unsupported SNES chip", fname);
        return -1;
    }

    current_game_snes_ram_size = io_buf[24] ? 1024u << io_buf[24] : 0;
    current_game_populous = 0;
    extract_filename(current_game_name, fname);
    loading_status("");
    show_rom_progress(0, payload);
    pce_load_start(payload + 64u, 0);
    for (UINT index = 0; index < 64; index += 4)
        pce_load_word(*(const uint32_t *)(io_buf + index));

    if (f_lseek(&file, offset) != FR_OK)
        goto failed;
    while (total < payload) {
        UINT want = (UINT)imin((int)(payload - total), sizeof(io_buf));
        if (f_read(&file, io_buf, want, &read) != FR_OK || read != want)
            goto failed;
        for (UINT index = 0; index < read; index += 4)
            pce_load_word(*(const uint32_t *)(io_buf + index));
        total += read;
        int percent = (int)(total * 100u / payload);
        if (percent != last_percent) {
            last_percent = percent;
            show_rom_progress(total, payload);
        }
    }
    f_close(&file);
    load_game_saves(current_game_name, 0);
    if (pce_load_end() != 0) {
        message("ROM transfer timeout", fname);
        return -1;
    }
    return 0;

failed:
    f_close(&file);
    (void)pce_load_end();
    message("Read error", fname);
    return -1;
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

static int gameboy_mapper_supported(uint8_t mapper) {
    return mapper == 0x00 || mapper == 0x01 || mapper == 0x02 ||
           mapper == 0x03 || mapper == 0x08 || mapper == 0x09 ||
           (mapper >= 0x0f && mapper <= 0x13) ||
           (mapper >= 0x19 && mapper <= 0x1e);
}

static int load_nintendo8_rom(const char *fname, uint32_t size) {
    FIL file;
    UINT read;
    uint8_t header[16];
    uint32_t total = 0;
    int last_percent = -1;

    if (CORE_PROFILE_ID != CORE_PROFILE_NINTENDO8 ||
        size < (is_nes(fname) ? 16u : 0x150u) ||
        size > (is_nes(fname) ? 0x3e0000u : 0x3d8000u)) {
        message("Unsupported image", "Max size is just under 4 MiB");
        return -1;
    }

    strcpy(path_buf, pwd);
    if (pwd[1])
        strcat(path_buf, "/");
    strcat(path_buf, fname);
    if (f_open(&file, path_buf, FA_READ) != FR_OK) {
        message("Cannot open", fname);
        return -1;
    }

    if (is_nes(fname)) {
        if (f_read(&file, header, sizeof(header), &read) != FR_OK ||
            read != sizeof(header)) {
            f_close(&file);
            message("Cannot read NES header", fname);
            return -1;
        }
    } else if (f_lseek(&file, 0x143u) != FR_OK ||
               f_read(&file, header, 7, &read) != FR_OK || read != 7) {
        f_close(&file);
        message("Cannot read GB header", fname);
        return -1;
    }
    if (is_nes(fname) &&
        (header[0] != 'N' || header[1] != 'E' ||
         header[2] != 'S' || header[3] != 0x1a)) {
        f_close(&file);
        message("Invalid NES image", fname);
        return -1;
    }
    if (is_gameboy(fname) && !gameboy_mapper_supported(header[4])) {
        f_close(&file);
        message("Unsupported GB mapper", fname);
        return -1;
    }

    if (f_lseek(&file, 0) != FR_OK) {
        f_close(&file);
        message("Cannot seek image", fname);
        return -1;
    }

    extract_filename(current_game_name, fname);
    current_game_snes_ram_size = 0;
    current_game_cgb = is_gameboy(fname) && (header[0] & 0x80);
    loading_status("");
    show_rom_progress(0, size);
    nintendo8_load_start(size, is_nes(fname));
    while (total < size) {
        UINT want = (UINT)imin((int)(size - total), sizeof(io_buf));
        if (f_read(&file, io_buf, want, &read) != FR_OK || read != want)
            goto failed;
        for (UINT index = 0; index < read; index += 4) {
            uint32_t word = 0xffffffffu;
            UINT remaining = read - index;
            if (remaining > 4)
                remaining = 4;
            memcpy(&word, io_buf + index, remaining);
            pce_load_word(word);
        }
        total += read;
        int percent = (int)(total * 100u / size);
        if (percent != last_percent) {
            last_percent = percent;
            show_rom_progress(total, size);
        }
    }
    f_close(&file);
    if (pce_load_end() != 0) {
        message("ROM transfer timeout", fname);
        return -1;
    }
    return 0;

failed:
    f_close(&file);
    (void)pce_load_end();
    message("Read error", fname);
    return -1;
}

// ---------------------------------------------------------------------------
// Mega Drive raw ROM loading. The entire file, including the console header,
// is streamed unchanged; no copier header or interleaving is accepted.
// ---------------------------------------------------------------------------
static int open_megadrive_rom(FIL *file, const char *fname, uint32_t size) {
    UINT read;

    if (!is_megadrive(fname)) {
        message("Unsupported MD image", "Use raw .md/.gen/.bin only");
        return -1;
    }
    if (size < 0x200u || size > MD_ROM_MAX_SIZE) {
        message("Unsupported MD size", "512 bytes to 6 MiB maximum");
        return -1;
    }
    strcpy(path_buf, pwd);
    if (pwd[1])
        strcat(path_buf, "/");
    strcat(path_buf, fname);
    if (f_open(file, path_buf, FA_READ) != FR_OK) {
        message("Cannot open", fname);
        return -1;
    }
    if (f_size(file) != size || f_lseek(file, 0x100u) != FR_OK ||
        f_read(file, io_buf, 4, &read) != FR_OK || read != 4) {
        f_close(file);
        message("Cannot read MD header", fname);
        return -1;
    }
    if (memcmp(io_buf, "SEGA", 4) != 0) {
        f_close(file);
        message("Invalid MD header", "Raw SEGA only; no SMD/copier");
        return -1;
    }
    if (f_lseek(file, 0) != FR_OK) {
        f_close(file);
        message("Cannot seek MD image", fname);
        return -1;
    }
    return 0;
}

int validate_megadrive_rom(const char *fname, uint32_t size) {
    FIL file;
    if (open_megadrive_rom(&file, fname, size) != 0)
        return -1;
    f_close(&file);
    return 0;
}

static int load_megadrive_rom(const char *fname, uint32_t size) {
    FIL file;
    UINT read;
    uint32_t total = 0;
    int last_percent = -1;

    if (CORE_PROFILE_ID != CORE_PROFILE_MEGADRIVE) {
        message("Wrong core for MD image", "Select Mega Drive first");
        return -1;
    }
    if (open_megadrive_rom(&file, fname, size) != 0)
        return -1;

    current_game_populous = 0;
    current_game_snes_ram_size = 0;
    current_game_cgb = 0;
    extract_filename(current_game_name, fname);
    loading_status("");
    show_rom_progress(0, size);
    // ROM bytes are big-endian on disk; the host FIFO accepts little-endian
    // packed words, not byte-swapped 68000 words. FF pads odd/partial tails.
    pce_load_start((size + 3u) & ~3u, 0);
    while (total < size) {
        UINT want = (UINT)imin((int)(size - total), sizeof(io_buf));
        if (f_read(&file, io_buf, want, &read) != FR_OK || read != want)
            goto failed;
        for (UINT index = 0; index < read; index += 4) {
            uint32_t word = 0xffffffffu;
            UINT remaining = read - index;
            if (remaining > 4)
                remaining = 4;
            memcpy(&word, io_buf + index, remaining);
            pce_load_word(word);
        }
        total += read;
        int percent = (int)(total * 100u / size);
        if (percent != last_percent) {
            last_percent = percent;
            show_rom_progress(total, size);
        }
    }
    f_close(&file);
    if (pce_load_end() != 0) {
        pce_stop();
        message("ROM transfer timeout", fname);
        return -1;
    }
    return 0;

failed:
    f_close(&file);
    (void)pce_load_end();
    pce_stop();
    message("Read error", fname);
    return -1;
}

int load_rom(const char *fname, uint32_t size) {
    if (is_megadrive(fname) || CORE_PROFILE_ID == CORE_PROFILE_MEGADRIVE)
        return load_megadrive_rom(fname, size);
    if (is_nes(fname) || is_gameboy(fname))
        return load_nintendo8_rom(fname, size);
    if (is_snes(fname))
        return load_snes_rom(fname, size);

    // HuCards retain their existing optional 512-byte copier-header handling.
    FIL f;
    UINT br;
    uint32_t total = 0;
    int last_pct = -1;
    int is_cue_image = 0;
    int is_populous = 0;
    int load_sgx;
    enum cheat_game_type cheat_type;

    char cue_path[PWD_SIZE + NAME_MAX + 2];
    char bin_path[PWD_SIZE + NAME_MAX + 2];

    cd_close();
    current_game_snes_ram_size = 0;

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

    load_sgx = is_sgx(fname) || is_cue_image;
    cheat_type = is_cue_image ? CHEAT_GAME_CD :
                 load_sgx ? CHEAT_GAME_SGX : CHEAT_GAME_PCE;

    uart_printf("loading %s, %d bytes\n", path_buf, (int)size);

    // holds the PC Engine in reset and publishes the image description
    loading_status("");
    show_rom_progress(0, size);
    pce_load_start(size, load_sgx);
    extract_filename(current_game_name, fname);
    cheats_load(current_game_name, cheat_type);

    while (total < size) {
        UINT want = (UINT)((size - total) > sizeof(io_buf) ? sizeof(io_buf)
                                                           : (size - total));
        if (f_read(&f, io_buf, want, &br) != FR_OK || br == 0) {
            (void)pce_load_end();
            f_close(&f);
            message("Read error", fname);
            return -1;
        }

        UINT read = br;

        // pad the tail to a whole word, the hardware only takes 32-bit writes
        while (br & 3)
            io_buf[br++] = 0xff;

        const uint32_t *w = (const uint32_t *)io_buf;
        for (UINT i = 0; i < br; i += 4)
            pce_load_word(*w++);

        total += read;

        int pct = (int)(total * 100 / size);
        if (pct != last_pct) {
            last_pct = pct;
            show_rom_progress(total, size);
        }
    }

    f_close(&f);

    // Charge le mode de manette spécifique au jeu
    game_pad_mode_load(current_game_name);
    load_game_saves(current_game_name, current_game_populous);

    // releases the PC Engine once the last byte has reached the SDRAM
    if (pce_load_end() != 0) {
        message("ROM transfer timeout", fname);
        return -1;
    }

    uart_print("load done\n");
    return 0;
}
