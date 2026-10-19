#include "../firmware/common.h"
static uint32_t profile = CORE_PROFILE_NINTENDO8;
#undef reg_core_id
#define reg_core_id profile
#include "../firmware/rom.c"

char pwd[PWD_SIZE] = "/";
char current_game_name[NAME_MAX];
uint8_t io_buf[2048];
uint32_t current_game_snes_ram_size;
int current_game_cgb;
static uint8_t image[0x150];
static unsigned position, messages;
static int short_header;
static void check(int condition, unsigned code) {
    if (!condition) {
        (*(volatile uint32_t *)0x03000000) = code;
        for (;;) {}
    }
}
FRESULT f_open(FIL *file, const TCHAR *path, BYTE mode) {
    (void)file; (void)path; (void)mode;
    position = 0;
    return FR_OK;
}
FRESULT f_close(FIL *file) {
    (void)file;
    return FR_OK;
}
FRESULT f_lseek(FIL *file, FSIZE_t offset) {
    (void)file;
    check(offset <= sizeof(image), 1);
    position = offset;
    return FR_OK;
}
FRESULT f_read(FIL *file, void *buffer, UINT length, UINT *read) {
    (void)file;
    if (short_header && position == 0x143 && length == 7)
        length--;
    check(position + length <= sizeof(image), 2);
    memcpy(buffer, image + position, length);
    position += length;
    *read = length;
    return FR_OK;
}
void message(const char *first, const char *second) {
    (void)first; (void)second;
    messages++;
}
void loading_status(const char *text) { (void)text; }
void progress_bar(int percent) { (void)percent; }

int main(void) {
    image[0x143] = 0xc0;
    image[0x147] = 0x19;
    check(load_nintendo8_rom("dual.gb", sizeof(image)) == 0, 3);
    check(current_game_cgb && !strcmp(current_game_name, "dual.gb") && !messages, 4);
    image[0x143] = 0;
    image[0x147] = 0;
    check(load_nintendo8_rom("mono.gbc", sizeof(image)) == 0 && !current_game_cgb, 5);
    image[0x143] = 0x80;
    image[0x147] = 1;
    check(load_nintendo8_rom("color.gb", sizeof(image)) == 0 && current_game_cgb, 6);
    image[0x147] = 0x22;
    check(load_nintendo8_rom("unsupported.gb", sizeof(image)) == -1 && messages == 1, 7);
    image[0x147] = 0;
    short_header = 1;
    check(load_nintendo8_rom("short.gb", sizeof(image)) == -1 && messages == 2, 8);
    short_header = 0;
    image[0] = 'N'; image[1] = 'E'; image[2] = 'S'; image[3] = 0x1a;
    check(load_nintendo8_rom("game.nes", sizeof(image)) == 0 && !current_game_cgb, 9);
    (*(volatile uint32_t *)0x03000000) = 0;
    for (;;) {}
}
