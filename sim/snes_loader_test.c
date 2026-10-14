#include "../firmware/common.h"

static uint32_t test_profile = CORE_PROFILE_SNES;
#undef reg_core_id
#define reg_core_id test_profile

static uint32_t streamed[16400];
static uint32_t word_count, stream_size, starts, finishes;
static uint32_t file_size, file_position, copier_size, header_position;
static uint8_t header[64];
static int restores, messages, fail_read, opens, closes;

static void capture_start(uint32_t size, int sgx) {
    (void)sgx;
    stream_size = size;
    word_count = 0;
    starts++;
}
static void capture_word(uint32_t word) {
    if (word_count < sizeof(streamed) / sizeof(streamed[0]))
        streamed[word_count++] = word;
}
static int capture_end(void) {
    finishes++;
    return 0;
}

#define pce_load_start capture_start
#define pce_load_word capture_word
#define pce_load_end capture_end
#include "../firmware/rom.c"

char pwd[PWD_SIZE] = "/games";
uint8_t io_buf[2048];
char current_game_name[NAME_MAX];
int current_game_populous;
uint32_t current_game_snes_ram_size;

FRESULT f_open(FIL *file, const TCHAR *path, BYTE mode) {
    (void)path;
    (void)mode;
    file->obj.objsize = file_size;
    file_position = 0;
    opens++;
    return FR_OK;
}
FRESULT f_lseek(FIL *file, FSIZE_t position) {
    (void)file;
    file_position = (uint32_t)position;
    return FR_OK;
}
FRESULT f_read(FIL *file, void *buffer, UINT count, UINT *read) {
    (void)file;
    if (fail_read && starts) {
        *read = 0;
        return FR_DISK_ERR;
    }
    uint8_t *bytes = buffer;
    *read = file_position < file_size ?
            (UINT)imin(count, file_size - file_position) : 0;
    for (UINT index = 0; index < *read; index++) {
        uint32_t position = file_position + index;
        bytes[index] = position >= header_position && position < header_position + 64 ?
                       header[position - header_position] : (uint8_t)(position - copier_size);
    }
    file_position += *read;
    return FR_OK;
}
FRESULT f_close(FIL *file) {
    (void)file;
    closes++;
    return FR_OK;
}
void cd_close(void) {}
void extract_filename(char *destination, const char *source) {
    strcpy(destination, source);
}
void message(const char *first, const char *second) {
    (void)first;
    (void)second;
    messages++;
}
void loading_status(const char *name) { (void)name; }
void progress_bar(int percent) { (void)percent; }
int load_game_saves(const char *name, int populous) {
    (void)name;
    (void)populous;
    restores++;
    return 0;
}

static void prepare(int hirom, int copier) {
    memset(header, 0, sizeof(header));
    memset(header, ' ', 21);
    header[21] = hirom ? 0x21 : 0x20;
    header[23] = hirom ? 6 : 5;
    header[24] = 1;
    header[30] = 0xff;
    header[31] = 0xff;
    header[61] = 0x80;
    copier_size = copier ? 512 : 0;
    file_size = (hirom ? 65536 : 32768) + copier_size;
    header_position = (hirom ? 0xffc0 : 0x7fc0) + copier_size;
    word_count = starts = finishes = restores = messages = opens = closes = 0;
    fail_read = 0;
    test_profile = CORE_PROFILE_SNES;
}
static void check(int condition, uint32_t code) {
    if (!condition) {
        (*(volatile uint32_t *)0x03000000) = code;
        for (;;) {}
    }
}
static void check_loaded(uint32_t code) {
    check(load_snes_rom("game.sfc", file_size) == 0, code);
    check(starts == 1 && finishes == 1 && restores == 1 && opens == closes, code);
    check(stream_size == file_size - copier_size + 64 && word_count * 4 == stream_size, code);
    check(memcmp(streamed, header, 64) == 0 && streamed[16] == 0x03020100u, code);
    check(current_game_snes_ram_size == 2048, code);
}
int main(void) {
    prepare(0, 0);
    check_loaded(1);
    prepare(0, 1);
    check_loaded(2);
    prepare(1, 0);
    check_loaded(3);
    prepare(0, 0);
    header[61] = 0;
    check(load_snes_rom("game.sfc", file_size) != 0 && !starts && opens == closes, 4);
    prepare(0, 0);
    header[22] = 0x13;
    check(load_snes_rom("game.sfc", file_size) != 0 && !starts && opens == closes, 5);
    prepare(0, 0);
    check(load_snes_rom("game.sfc", 4u * 1024u * 1024u) != 0 && !opens, 6);
    prepare(0, 0);
    header[24] = 8;
    check(load_snes_rom("game.sfc", file_size) != 0 && !starts && opens == closes, 7);
    prepare(0, 0);
    test_profile = CORE_PROFILE_SUPERSET;
    check(load_snes_rom("game.sfc", file_size) != 0 && !opens, 8);
    prepare(0, 0);
    fail_read = 1;
    check(load_snes_rom("game.sfc", file_size) != 0 && starts == 1 && opens == closes, 9);
    (*(volatile uint32_t *)0x03000000) = 0;
    for (;;) {}
}