#include "../firmware/common.h"

static uint32_t profile = CORE_PROFILE_NINTENDO8 | CORE_FEATURE_EXTENDED_SETTINGS;
static uint32_t zoom_register, scan_register, color_register, nintendo_register;
static uint32_t vdc_options_register, console_region_register;
#undef reg_core_id
#undef reg_video_zoom
#undef reg_scanline
#undef reg_color_mode
#undef reg_nintendo_color
#undef reg_vdc_options
#undef reg_console_region
#define reg_core_id profile
#define reg_video_zoom zoom_register
#define reg_scanline scan_register
#define reg_color_mode color_register
#define reg_nintendo_color nintendo_register
#define reg_vdc_options vdc_options_register
#define reg_console_region console_region_register
#include "../firmware/settings.c"
#include "../firmware/menu.c"

char current_game_name[NAME_MAX];
int current_game_cgb;
static char config[2048];
static unsigned config_size, config_pos;
static void check(int condition, unsigned code) {
    if (!condition) {
        (*(volatile uint32_t *)0x03000000) = code;
        for (;;) {}
    }
}
FRESULT f_open(FIL *file, const TCHAR *path, BYTE mode) {
    (void)file;
    check(!strcmp(path, "/config/video.cfg"), 1);
    config_pos = 0;
    if (mode & FA_WRITE) config_size = 0;
    return FR_OK;
}
FRESULT f_close(FIL *file) {
    (void)file;
    return FR_OK;
}
FRESULT f_mkdir(const TCHAR *path) {
    (void)path;
    return FR_OK;
}
FRESULT f_write(FIL *file, const void *buffer, UINT length, UINT *written) {
    (void)file;
    check(config_pos + length < sizeof(config), 2);
    memcpy(config + config_pos, buffer, length);
    config_pos += length;
    config_size = config_pos;
    config[config_size] = 0;
    *written = length;
    return FR_OK;
}
TCHAR *f_gets(TCHAR *buffer, int length, FIL *file) {
    int n = 0;
    (void)file;
    if (config_pos == config_size) return 0;
    while (config_pos < config_size && n < length-1) {
        buffer[n++] = config[config_pos++];
        if (buffer[n-1] == '\n') break;
    }
    buffer[n] = 0;
    return buffer;
}
int main(void) {
    char label[24];
    for (unsigned palette = 0; palette < 8; palette++) {
        nes_palette = palette;
        gbc_color = palette % 3;
        gb_palette = palette % 4;
        video_zoom = reg_video_zoom = palette % 3;
        video_scanline = reg_scanline = palette % 4;
        video_color = 1;
        video_config_save();
        nes_palette = gbc_color = gb_palette = video_color = 0;
        video_zoom = video_scanline = 0;
        nintendo_register = 0xffffffff;
        video_config_load();
        check(nes_palette == (int)palette && gbc_color == (int)(palette % 3) &&
              gb_palette == (int)(palette % 4), 3);
        check(nintendo_register == (palette | ((palette % 3) << 3) |
                                   ((palette % 4) << 5)), 4);
        check(video_zoom == (int)(palette % 3) && video_scanline == (int)(palette % 4), 5);
        check(zoom_register == palette % 3 && scan_register == palette % 4, 6);
        check(video_color == 1 && color_register == 1, 7);
    }
    strcpy(current_game_name, "test.GBC");
    check(video_is_gameboy() && video_zoom_count() == 2, 8);
    strcpy(current_game_name, "test.gb");
    check(video_is_gameboy() && video_zoom_count() == 2, 9);
    strcpy(current_game_name, "test.nes");
    check(!video_is_gameboy() && video_zoom_count() == 3, 10);
    profile = CORE_PROFILE_PCE;
    nintendo_register = 0xa5;
    nintendo_color_apply();
    check(nintendo_register == 0xa5 && video_zoom_count() == 3, 11);
    profile = CORE_PROFILE_NINTENDO8;
    nintendo_register = 0xa5;
    nintendo_color_apply();
    check(nintendo_register == 0xa5, 37);
    profile = CORE_PROFILE_NINTENDO8 | CORE_FEATURE_EXTENDED_SETTINGS;
    profile = CORE_PROFILE_SGX;
    vdc_options_register = 0xa5;
    console_region_register = 0x5a;
    vdc_sprites_double = 1;
    console_region = CONSOLE_REGION_PAL_EU;
    vdc_options_apply();
    console_region_apply();
    check(vdc_options_register == 1 && console_region_register == 0x5a, 38);
    profile = CORE_PROFILE_SGX | CORE_FEATURE_EXTENDED_SETTINGS;
    vdc_options_apply();
    console_region_apply();
    check(vdc_options_register == 1 &&
          console_region_register == CONSOLE_REGION_PAL_EU, 39);
    profile = CORE_PROFILE_NINTENDO8 | CORE_FEATURE_EXTENDED_SETTINGS;
    strcpy(current_game_name, "test.gbc");
    current_game_cgb = 1;
    video_zoom = 2;
    advance_zoom(1);
    check(video_zoom == 0 && zoom_register == 0, 12);
    advance_zoom(1);
    make_menu_label(label, 5);
    check(video_zoom == 1 && !strcmp(label, "Zoom: Wide Stretch"), 13);
    advance_zoom(1);
    check(video_zoom == 0, 14);
    gbc_color = 1;
    make_menu_label(label, 4);
    check(!strcmp(label, "Color: Accurate"), 15);
    video_scanline = 2;
    make_menu_label(label, 6);
    check(!strcmp(label, "Grid: 20%"), 16);
    strcpy(current_game_name, "test.nes");
    nes_palette = 7;
    make_menu_label(label, 4);
    check(!strcmp(label, "Color: Wavebeam"), 17);
    make_menu_label(label, 6);
    check(!strcmp(label, "Scanlines: 50%"), 18);
    advance_zoom(1);
    advance_zoom(1);
    make_menu_label(label, 5);
    check(video_zoom == 2 && !strcmp(label, "Zoom: Bilinear"), 19);
    check(selection_step(JOY_LEFT, 8) == -1 &&
          selection_step(JOY_RIGHT, 8) == 1 && selection_step(JOY_A, 8) == 1, 20);
    check(!selection_step(JOY_LEFT, 2) && !selection_step(JOY_RIGHT, 2) &&
          selection_step(JOY_A, 2) == 1 && !selection_step(JOY_B, 8), 21);
    nes_palette = 0;
    cycle_video_setting(0, -1);
    check(nes_palette == 7, 22);
    cycle_video_setting(0, 1);
    check(nes_palette == 0, 23);
    video_zoom = 0;
    cycle_video_setting(1, -1);
    check(video_zoom == 2 && zoom_register == 2, 24);
    video_scanline = 0;
    cycle_video_setting(2, -1);
    check(video_scanline == 3 && scan_register == 3, 25);
    strcpy(current_game_name, "color.gb"); // A CGB-capable ROM may have a .gb extension.
    current_game_cgb = 1;
    check(video_is_gbc() && video_color_count() == 3, 26);
    gbc_color = 0;
    cycle_video_setting(0, -1);
    make_menu_label(label, 4);
    check(gbc_color == 2 && !strcmp(label, "Color: Fast"), 27);
    cycle_video_setting(0, 1);
    make_menu_label(label, 4);
    check(gbc_color == 0 && !strcmp(label, "Color: Off"), 28);
    current_game_cgb = 0;
    gb_palette = 0;
    check(video_color_count() == 4, 29);
    cycle_video_setting(0, -1);
    make_menu_label(label, 4);
    check(gb_palette == 3 && !strcmp(label, "Color: Light") && gbc_color == 0, 30);
    cycle_video_setting(0, 1);
    check(gb_palette == 0, 31);
    cycle_video_setting(0, 1);
    make_menu_label(label, 4);
    check(!strcmp(label, "Color: DMG"), 32);
    cycle_video_setting(0, 1);
    make_menu_label(label, 4);
    check(!strcmp(label, "Color: Pocket"), 33);
    strcpy(config, "gbc_accurate=1\n");
    config_size = strlen(config);
    gbc_color = 0;
    video_config_load();
    check(gbc_color == 1, 34);
    strcpy(config, "gbc_color=2\ngbc_accurate=0\n");
    config_size = strlen(config);
    video_config_load();
    check(gbc_color == 2, 35);
    strcpy(config, "gbc_accurate=0\ngbc_color=2\n");
    config_size = strlen(config);
    video_config_load();
    check(gbc_color == 2, 36);
    (*(volatile uint32_t *)0x03000000) = 0;
    for (;;) {}
}
