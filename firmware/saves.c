//
// Backup RAM (.brm) and Populous SRAM (.pop) persistence under /saves.
//

#include "common.h"
#include "saves.h"

#define BRM_SAVE_SIZE 2048
#define POP_SAVE_SIZE 32768
#define POP_SAVE_BASE ((volatile uint8_t *)0x001b0000)

static void build_save_path(char *dst, size_t len, const char *game_name,
                            const char *extension) {
    const char *prefix = "/saves/";
    size_t i = 0;

    while (*prefix && i < len - 1)
        dst[i++] = *prefix++;
    while (*game_name && i < len - 1)
        dst[i++] = *game_name++;
    while (*extension && i < len - 1)
        dst[i++] = *extension++;
    dst[i] = '\0';
}

static void brm_transfer(uint8_t *buffer, uint32_t offset, UINT count, int to_bram) {
    reg_brm_access = 1;
    for (UINT i = 0; i < count; i++) {
        reg_brm_addr = offset + i;
        if (to_bram) {
            reg_brm_data = buffer[i];
        } else {
            (void)reg_time;
            buffer[i] = (uint8_t)reg_brm_data;
        }
    }
    reg_brm_access = 0;
}

static void save_ram_transfer(uint8_t *buffer, uint32_t offset, UINT count,
                              int is_populous, int to_ram) {
    if (is_populous) {
        volatile uint8_t *ram = POP_SAVE_BASE + offset;
        for (UINT i = 0; i < count; i++) {
            if (to_ram)
                ram[i] = buffer[i];
            else
                buffer[i] = ram[i];
        }
    } else {
        brm_transfer(buffer, offset, count, to_ram);
    }
}

static int save_ram_file(const char *game_name, const char *extension,
                         uint32_t size, int is_populous, int save_to_sd) {
    FIL file;
    UINT br = 0;
    UINT bw = 0;
    uint32_t total = 0;
    char save_path[PWD_SIZE + NAME_MAX + 16];
    int file_open = 0;

    build_save_path(save_path, sizeof(save_path), game_name, extension);
    if (save_to_sd) {
        f_mkdir("/saves");
        if (f_open(&file, save_path, FA_WRITE | FA_CREATE_ALWAYS) != FR_OK)
            return -1;
        file_open = 1;
    } else {
        file_open = f_open(&file, save_path, FA_READ) == FR_OK;
    }

    while (total < size) {
        UINT chunk = (UINT)((size - total) > sizeof(io_buf) ? sizeof(io_buf)
                                                              : size - total);
        if (save_to_sd) {
            save_ram_transfer(io_buf, total, chunk, is_populous, 0);
            if (f_write(&file, io_buf, chunk, &bw) != FR_OK || bw != chunk) {
                f_close(&file);
                return -1;
            }
        } else {
            if (!file_open || f_read(&file, io_buf, chunk, &br) != FR_OK || br != chunk)
                memset(io_buf, 0, chunk);
            save_ram_transfer(io_buf, total, chunk, is_populous, 1);
        }
        total += chunk;
    }

    if (file_open)
        f_close(&file);
    return 0;
}

int load_game_saves(const char *game_name, int is_populous) {
    int ok = 0;

    pce_pause(1);
    if (save_ram_file(game_name, ".brm", BRM_SAVE_SIZE, 0, 0) != 0)
        ok = -1;
    if (is_populous && save_ram_file(game_name, ".pop", POP_SAVE_SIZE, 1, 0) != 0)
        ok = -1;
    pce_pause(0);

    if (ok == 0)
        uart_printf("save: restored %s%s\n", game_name,
                     is_populous ? " + Populous SRAM" : "");
    return ok;
}

int save_game_saves(int resume_game) {
    int ok = 0;

    if (!current_game_name[0])
        return 0;

    pce_pause(1);
    if (save_ram_file(current_game_name, ".brm", BRM_SAVE_SIZE, 0, 1) != 0)
        ok = -1;
    if (current_game_populous &&
        save_ram_file(current_game_name, ".pop", POP_SAVE_SIZE, 1, 1) != 0)
        ok = -1;
    if (resume_game)
        pce_pause(0);

    if (ok == 0)
        uart_printf("save: wrote %s%s\n", current_game_name,
                     current_game_populous ? " + Populous SRAM" : "");
    else
        uart_printf("save: write failed for %s\n", current_game_name);
    return ok;
}
