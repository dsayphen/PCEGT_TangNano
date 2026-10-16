#include "../firmware/common.h"

static uint32_t test_profile;
#undef reg_core_id
#define reg_core_id test_profile
#include "../firmware/core.c"

char pwd[PWD_SIZE] = "/";
static Autorun stored_request;
static int present, unlink_failure, load_failure;
static int rom_loads, cd_loads, messages;
static uint32_t stored_size;

FRESULT f_open(FIL *file, const TCHAR *path, BYTE mode) {
    (void)mode;
    if (strcmp(path, AUTORUN_PATH) || !present)
        return FR_NO_FILE;
    file->obj.objsize = stored_size;
    return FR_OK;
}
FRESULT f_read(FIL *file, void *buffer, UINT length, UINT *read) {
    (void)file;
    *read = length < stored_size ? length : stored_size;
    memcpy(buffer, &stored_request, *read);
    return FR_OK;
}
FRESULT f_close(FIL *file) {
    (void)file;
    return FR_OK;
}
FRESULT f_unlink(const TCHAR *path) {
    (void)path;
    if (unlink_failure)
        return FR_DISK_ERR;
    if (!present)
        return FR_NO_FILE;
    present = 0;
    return FR_OK;
}
FRESULT f_stat(const TCHAR *path, FILINFO *info) {
    if (strcmp(path, "/games/game.pce") && strcmp(path, "/games/game.sgx") &&
        strcmp(path, "/games/game.sfc") && strcmp(path, "/games/game.smc"))
        return FR_NO_FILE;
    info->fsize = 4096;
    info->fattrib = 0;
    return FR_OK;
}
void message(const char *first, const char *second) {
    (void)first;
    (void)second;
    messages++;
}
int load_rom(const char *name, uint32_t size) {
    (void)name;
    rom_loads++;
    return size == 4096 && !load_failure ? 0 : -1;
}
int open_cd_image(const char *name) {
    (void)name;
    cd_loads++;
    return load_failure ? -1 : 0;
}

static void prepare(uint32_t profile, const char *name) {
    memset(&stored_request, 0, sizeof(stored_request));
    stored_request.magic = AUTORUN_MAGIC;
    stored_request.profile = profile;
    strcpy(stored_request.directory, "/games");
    strcpy(stored_request.game, name);
    stored_request.crc = buffer_crc(&stored_request, sizeof(stored_request) - 4);
    test_profile = profile;
    present = 1;
    unlink_failure = 0;
    load_failure = 0;
    rom_loads = 0;
    cd_loads = 0;
    messages = 0;
    stored_size = sizeof(stored_request);
}
static void check(int condition, uint32_t code) {
    if (!condition) {
        (*(volatile uint32_t *)0x03000000) = code;
        for (;;) {}
    }
}
int main(void) {
    check(buffer_crc("123456789", 9) == 0xcbf43926u, 1);
    prepare(CORE_PROFILE_SGX, "game.pce");
    check(core_autorun() == 1 && rom_loads == 1 && !present, 2);
    check(core_autorun() == 0 && rom_loads == 1, 3);
    prepare(CORE_PROFILE_SGX, "game.sgx");
    check(core_autorun() == 1 && rom_loads == 1, 4);
    prepare(CORE_PROFILE_CD, "game.cue");
    check(core_autorun() == 1 && cd_loads == 1, 5);
    prepare(CORE_PROFILE_SUPERSET, "game.pce");
    check(core_autorun() == 0 && !present && !rom_loads, 6);
    prepare(CORE_PROFILE_SUPERSET, "game.cue");
    check(core_autorun() == 0 && !present && !cd_loads, 7);
    prepare(CORE_PROFILE_CD, "game.cue");
    test_profile = CORE_PROFILE_SGX;
    check(core_autorun() == 0 && !present && !cd_loads, 8);
    prepare(CORE_PROFILE_SGX, "game.pce");
    stored_request.crc ^= 1;
    check(core_autorun() == 0 && !present && !rom_loads, 9);
    prepare(CORE_PROFILE_SGX, "game.pce");
    stored_size--;
    check(core_autorun() == 0 && !present && !rom_loads, 10);
    prepare(CORE_PROFILE_SGX, "game.pce");
    unlink_failure = 1;
    check(core_autorun() == 0 && present && !rom_loads, 11);
    prepare(CORE_PROFILE_SGX, "game.pce");
    load_failure = 1;
    check(core_autorun() == 0 && !present && messages == 1, 12);
    prepare(CORE_PROFILE_CD, "game.pce");
    check(core_autorun() == 0 && !present && !rom_loads, 13);
    prepare(CORE_PROFILE_SGX, "game.cue");
    check(core_autorun() == 0 && !present && !cd_loads, 14);
    prepare(CORE_PROFILE_SGX, "../game.pce");
    check(core_autorun() == 0 && !present && !rom_loads, 15);
    prepare(CORE_PROFILE_SNES, "game.sfc");
    check(core_autorun() == 1 && !present && rom_loads == 1, 16);
    prepare(CORE_PROFILE_SNES, "game.smc");
    check(core_autorun() == 1 && !present && rom_loads == 1, 17);
    prepare(CORE_PROFILE_SNES, "game.pce");
    check(core_autorun() == 0 && !present && !rom_loads, 18);
    prepare(CORE_PROFILE_SNES, "game.cue");
    check(core_autorun() == 0 && !present && !cd_loads, 19);
    prepare(CORE_PROFILE_SUPERSET, "game.sfc");
    check(core_autorun() == 0 && !present && !rom_loads, 20);
    prepare(CORE_PROFILE_SGX, "game.sfc");
    check(core_autorun() == 0 && !present && !rom_loads, 21);
    prepare(CORE_PROFILE_SNES, "game.txt");
    check(core_autorun() == 0 && !present && !rom_loads, 22);
    (*(volatile uint32_t *)0x03000000) = 0;
    for (;;) {}
}