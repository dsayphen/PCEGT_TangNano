#include "../firmware/common.h"

static uint32_t profile = CORE_PROFILE_MEGADRIVE;
#undef reg_core_id
#define reg_core_id profile
static void test_load_start(uint32_t size, int sgx);
static void test_load_word(uint32_t word);
static int test_load_end(void);
static void test_stop(void);
static void test_pause(int paused);
#define pce_load_start test_load_start
#define pce_load_word test_load_word
#define pce_load_end test_load_end
#define pce_stop test_stop
#define pce_pause test_pause
#include "../firmware/rom.c"
#include "../firmware/core.c"
#include "../firmware/saves.c"
static uint32_t audio_register;
#undef reg_audio
#define reg_audio audio_register
#include "../firmware/settings.c"
static int test_offer_switch(uint32_t required, const char *game);
#define core_offer_switch test_offer_switch
#include "../firmware/browser.c"
#undef core_offer_switch

char current_game_name[NAME_MAX];
uint8_t io_buf[2048];
uint32_t current_game_snes_ram_size;
int current_game_cgb, current_game_populous;
static uint32_t image_size, position, streamed, transfer_size;
static unsigned opened, closed, messages, starts, ends, stops, pauses;
static unsigned switches;
static int signature, short_header, fail_read, fail_seek, end_failure;
static int open_failure;

static void check(int condition, unsigned code) {
    if (!condition) {
        (*(volatile uint32_t *)0x03000000) = code;
        for (;;) {}
    }
}
static uint8_t image_byte(uint32_t offset) {
    if (offset >= 0x100 && offset < 0x104 && signature)
        return (uint8_t)"SEGA"[offset - 0x100];
    return (uint8_t)(offset * 17u + 3u);
}
FRESULT f_open(FIL *file, const TCHAR *path, BYTE mode) {
    (void)path; (void)mode;
    opened++;
    position = 0;
    file->obj.objsize = image_size;
    return open_failure ? FR_DISK_ERR : FR_OK;
}
FRESULT f_close(FIL *file) {
    (void)file;
    closed++;
    return FR_OK;
}
FRESULT f_lseek(FIL *file, FSIZE_t offset) {
    (void)file;
    if (fail_seek && offset == 0)
        return FR_DISK_ERR;
    check(offset <= image_size, 100);
    position = offset;
    return FR_OK;
}
FRESULT f_read(FIL *file, void *buffer, UINT length, UINT *read) {
    (void)file;
    if (short_header && position == 0x100 && length == 4)
        length--;
    if (fail_read && starts) {
        if (fail_read == 2) {
            *read = length - 1;
            return FR_OK;
        }
        *read = 0;
        return FR_DISK_ERR;
    }
    check(position + length <= image_size, 101);
    for (UINT i = 0; i < length; i++)
        ((uint8_t *)buffer)[i] = image_byte(position + i);
    position += length;
    *read = length;
    return FR_OK;
}
FRESULT f_write(FIL *file, const void *buffer, UINT length, UINT *written) {
    (void)file; (void)buffer; (void)length; (void)written;
    check(0, 102);
    return FR_DISK_ERR;
}
FRESULT f_mkdir(const TCHAR *path) {
    (void)path;
    check(0, 103);
    return FR_DISK_ERR;
}
void message(const char *first, const char *second) {
    (void)first; (void)second;
    messages++;
}
void loading_status(const char *text) { (void)text; }
void progress_bar(int percent) { (void)percent; }
static void test_load_start(uint32_t size, int sgx) {
    check(sgx == 0 && size <= MD_ROM_MAX_SIZE && !(size & 3u), 105);
    starts++;
    transfer_size = size;
}
static void test_load_word(uint32_t word) {
    uint32_t expected = 0;
    for (unsigned i = 0; i < 4; i++)
        expected |= (uint32_t)(streamed + i < image_size ?
                    image_byte(streamed + i) : 0xffu) << (i * 8);
    check(word == expected, 106);
    streamed += 4;
    check(streamed <= transfer_size, 107);
}
static int test_load_end(void) {
    ends++;
    return end_failure ? -1 : 0;
}
static void test_stop(void) { stops++; }
static void test_pause(int paused) { (void)paused; pauses++; }
static int test_offer_switch(uint32_t required, const char *game) {
    check(required == CORE_PROFILE_MEGADRIVE && is_megadrive(game), 108);
    switches++;
    return 0;
}

static void prepare(uint32_t size) {
    profile = CORE_PROFILE_MEGADRIVE;
    image_size = size;
    position = streamed = transfer_size = 0;
    opened = closed = messages = starts = ends = stops = pauses = switches = 0;
    signature = 1;
    short_header = fail_read = fail_seek = end_failure = open_failure = 0;
    current_game_name[0] = 0;
}
int main(void) {
    check(is_megadrive("a.md") && is_rom("a.md"), 1);
    check(is_megadrive("GAME.MD") && is_megadrive("GAME.GEN") &&
          is_megadrive("GAME.BIN"), 2);
    check(!is_megadrive("game.smd") && !is_megadrive("game.md.zip") &&
          !is_megadrive(".md") && !is_megadrive("md"), 3);
    check(core_game_profile("game.bin") == CORE_PROFILE_MEGADRIVE &&
          core_game_profile("game.gen") == CORE_PROFILE_MEGADRIVE, 4);
    check(core_supports_game(CORE_PROFILE_MEGADRIVE, "game.md") &&
          !core_supports_game(CORE_PROFILE_SGX, "game.bin") &&
          !core_supports_game(CORE_PROFILE_MEGADRIVE, "game.cue"), 5);
    check(core_game_profile("game.pce") == CORE_PROFILE_SGX &&
          core_game_profile("game.cue") == CORE_PROFILE_CD &&
          core_game_profile("game.sfc") == CORE_PROFILE_SNES &&
          core_game_profile("game.gb") == CORE_PROFILE_NINTENDO8, 6);
    check(core_flash_slot(CORE_PROFILE_SGX) == 1 &&
          core_flash_slot(CORE_PROFILE_CD) == 2 &&
          core_flash_slot(CORE_PROFILE_SNES) == 3 &&
          core_flash_slot(CORE_PROFILE_NINTENDO8) == 4 &&
          core_flash_slot(CORE_PROFILE_MEGADRIVE) == 6, 7);
    for (uint32_t size = 512; size <= 515; size++) {
        prepare(size);
        check(load_megadrive_rom("raw.md", size) == 0, 8);
        check(starts == 1 && ends == 1 && !stops && closed == 1 &&
              !messages && streamed == ((size + 3) & ~3u), 9);
        check(!strcmp(current_game_name, "raw.md") &&
              !current_game_cgb && !current_game_populous &&
              !current_game_snes_ram_size, 10);
    }
    prepare(2049);
    check(load_megadrive_rom("raw.gen", image_size) == 0 &&
          streamed == 2052 && transfer_size == 2052, 11);
    prepare(511);
    check(load_megadrive_rom("tiny.md", image_size) == -1 &&
          messages == 1 && !opened && !starts, 12);
    prepare(MD_ROM_MAX_SIZE + 1);
    check(load_megadrive_rom("huge.bin", image_size) == -1 &&
          !opened && !starts, 13);
    prepare(MD_ROM_MAX_SIZE);
    fail_read = 1;
    check(load_megadrive_rom("limit.md", image_size) == -1 &&
          transfer_size == MD_ROM_MAX_SIZE && starts == 1 &&
          ends == 1 && stops == 1 && closed == 1, 14);
    prepare(512);
    signature = 0;
    check(load_megadrive_rom("cd-track.bin", image_size) == -1 &&
          messages == 1 && closed == 1 && !starts, 15);
    prepare(512);
    check(load_megadrive_rom("interleaved.smd", image_size) == -1 &&
          !opened, 16);
    prepare(1024);
    signature = 0;
    check(load_megadrive_rom("copier.md", image_size) == -1 && !starts, 17);
    prepare(512);
    short_header = 1;
    check(load_megadrive_rom("short.md", image_size) == -1 &&
          closed == 1 && !starts, 18);
    prepare(512);
    check(load_megadrive_rom("changed.md", 513) == -1 &&
          closed == 1 && !starts, 19);
    prepare(512);
    fail_seek = 1;
    check(load_megadrive_rom("seek.md", image_size) == -1 &&
          closed == 1 && !starts, 20);
    prepare(512);
    end_failure = 1;
    check(load_megadrive_rom("timeout.md", image_size) == -1 &&
          closed == 1 && ends == 1 && stops == 1, 21);
    prepare(512);
    open_failure = 1;
    check(load_megadrive_rom("open.md", image_size) == -1 &&
          !closed && !starts, 22);
    prepare(512);
    profile = CORE_PROFILE_NINTENDO8;
    check(load_megadrive_rom("wrong.md", image_size) == -1 && !opened, 23);
    check(validate_megadrive_rom("valid.bin", image_size) == 0 &&
          opened == 1 && closed == 1 && !starts, 31);
    signature = 0;
    check(validate_megadrive_rom("cd-track.bin", image_size) == -1 &&
          opened == 2 && closed == 2 && !starts, 32);
    check(check_entry_profile("cd-track.bin", image_size) == 0 &&
          !switches && !starts, 33);
    signature = 1;
    check(check_entry_profile("valid.bin", image_size) == 0 &&
          switches == 1 && !starts, 34);
    profile = CORE_PROFILE_MEGADRIVE;
    check(check_entry_profile("valid.md", image_size) == 1 &&
          switches == 1, 35);
    prepare(512);
    strcpy(current_game_name, "raw.md");
    check(load_game_saves(current_game_name, 0) == 0 &&
          save_game_saves(0) == 0 && save_game_saves(1) == 0 &&
          !opened && !pauses, 24);
    check(video_zoom_count() == 2, 25);
    audio_bass = 5;
    audio_treble = -5;
    audio_output_hdmi = audio_cdda_enabled = audio_adpcm_enabled = 1;
    audio_volume = 7;
    audio_paused = 0;
    audio_apply();
    check(audio_register == (7 | (1u << 12)), 27);
    audio_paused = 1;
    audio_apply();
    check(audio_register == (1u << 12), 28);
    audio_output_hdmi = 0;
    audio_paused = 0;
    audio_apply();
    check(audio_register == 7, 31);
    prepare(MD_ROM_MAX_SIZE - 1);
    fail_read = 1;
    check(load_megadrive_rom("padded.md", image_size) == -1 &&
          transfer_size == MD_ROM_MAX_SIZE, 29);
    prepare(512);
    fail_read = 2;
    check(load_megadrive_rom("short-read.bin", image_size) == -1 &&
          starts == 1 && ends == 1 && stops == 1 && closed == 1, 30);
    profile = CORE_PROFILE_SGX;
    check(video_zoom_count() == 3, 26);
    (*(volatile uint32_t *)0x03000000) = 0;
    for (;;) {}
}
