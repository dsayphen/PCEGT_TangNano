//
// In-game menus: pause menu, video / audio sub-menus and the Select+D-pad
// zoom / scanline shortcuts.
//

#include "common.h"
#include "osd.h"
#include "settings.h"
#include "saves.h"
#include "cd.h"
#include "menu.h"

// Cycle the display zoom mode (2x -> stretch -> ...) and flash the new
// setting on the OSD for a moment.  Kept in sync with rtl/tang/iosys/iosys.v
// (reg_video_zoom) and rtl/tang/video_scandoubler.v.
void zoom_cycle(void) {
    static const char *names[3] = {
        "Zoom: Integer", "Zoom: Stretch", "Zoom: Bilinear"
    };

    video_zoom = (video_zoom + 1) % 3;
    reg_video_zoom = video_zoom;
    video_config_save();

    clear();
    print_field(1, 10, names[video_zoom], OSD_COLS - 2);
    overlay(1);
    delay(600);
    overlay(0);
}

// Cycle the scanline strength (0/25/50/100%) and flash the new setting on
// the OSD for a moment.  `dir` is +1 to increase, -1 to decrease; the value
// wraps around in both directions.  Kept in sync with
// rtl/tang/iosys/iosys.v (reg_scanline) and rtl/tang/video_scandoubler.v.
void scanline_cycle(int dir) {
    static const char *names[4] = {
        "Scanlines: off", "Scanlines: 25%", "Scanlines: 50%", "Scanlines: 100%"
    };

    video_scanline = (video_scanline + dir + 4) % 4;
    reg_scanline = video_scanline;
    video_config_save();

    clear();
    print_field(1, 10, names[video_scanline], OSD_COLS - 2);
    overlay(1);
    delay(600);
    overlay(0);
}

static const char *zoom_names[3] = { "Integer", "Stretch", "Bilinear" };
static const char *scan_names[4] = { "Off", "25%", "50%", "100%" };
static const char *color_names[2] = { "RAW RGB", "Composite" };

static void print_game_name(void) {
    char label[OSD_COLS - 4];
    const char *end = current_game_name;
    const char *extension = 0;
    int i = 0;

    while (*end) {
        if (*end == '.' && end != current_game_name)
            extension = end;
        end++;
    }
    if (extension)
        end = extension;

    while (current_game_name + i < end && i < OSD_COLS - 5) {
        label[i] = current_game_name[i];
        i++;
    }
    label[i] = '\0';
    print_field(5, 6, label, OSD_COLS - 5);
}

static void make_menu_label(char *buf, int type) {
    const char *prefix;
    const char *value;
    int i = 0;

    if (type == 3) {
        prefix = "Gamepad: ";
        value = game_pad_mode ? "6 buttons" : "2 buttons";
    } else if (type == 4) {
        prefix = "Color: ";
        value = color_names[video_color];
    } else if (type == 5) {
        prefix = "Zoom: ";
        value = zoom_names[video_zoom];
    } else {
        prefix = "Scanlines: ";
        value = scan_names[video_scanline];
    }

    while (*prefix)
        buf[i++] = *prefix++;

    while (*value)
        buf[i++] = *value++;

    buf[i] = '\0';
}

// Color/Zoom/Scanlines sub-menu, reached from "Video Settings >" in
// pause_menu.  Gamepad mode lives directly in pause_menu, not here.
static void video_menu(void) {
    static const char *back_label = "Back";
    int active = 0;
    const int n_items = 4;

    clear();
    print_field(5, 5, "Video Settings", OSD_COLS - 2);
    print_game_name();

    for (;;) {
        for (int i = 0; i < n_items; i++) {
            cursor(4, 8 + i);
            putchar(i == active ? '>' : ' ');

            char label[24];

            if (i == 3) {
                print_field(6, 8 + i, back_label, 20);
                continue;
            }

            make_menu_label(label, i + 4);
            print_field(6, 8 + i, label, 20);
        }
        selection_row(8 + active);

        uint32_t e = joy_edge();
        if (e & JOY_UP) {
            active = active ? active - 1 : n_items - 1;
        } else if (e & JOY_DOWN) {
            active = active < n_items - 1 ? active + 1 : 0;
        } else if ((e & JOY_B) || ((e & JOY_A) && active == 3)) {
            return;
        } else if ((e & JOY_A) && active == 0) {
            video_color = !video_color;
            reg_color_mode = video_color;
            video_config_save();
        } else if ((e & JOY_A) && active == 1) {
            video_zoom = (video_zoom + 1) % 3;
            reg_video_zoom = video_zoom;
            video_config_save();
        } else if ((e & JOY_A) && active == 2) {
            video_scanline = (video_scanline + 1) % 4;
            reg_scanline = video_scanline;
            video_config_save();
        }
        delay(20);
    }
}

// Volume/Bass/Treble sub-menu, reached from "Audio Settings >" in pause_menu.
static void audio_menu(void) {
    static const char *labels[4] = { "Volume", "Bass", "Treble", "Back" };
    int active = 0;
    const int n_items = 4;

    clear();
    print_field(5, 5, "Audio Settings", OSD_COLS - 2);
    print_game_name();

    for (;;) {
        for (int i = 0; i < n_items; i++) {
            cursor(4, 8 + i);
            putchar(i == active ? '>' : ' ');

            char label[24];
            int j = 0;
            const char *prefix = labels[i];
            while (*prefix)
                label[j++] = *prefix++;

            if (i < 3) {
                int val = (i == 0) ? audio_volume : (i == 1) ? audio_bass : audio_treble;
                char num[4];
                int len;

                label[j++] = ':';
                label[j++] = ' ';
                if (i > 0 && val > 0) {
                    label[j++] = '+';
                } else if (i > 0 && val < 0) {
                    label[j++] = '-';
                    val = -val;
                }
                len = u8_to_str(num, (uint8_t)val);
                for (int k = 0; k < len; k++)
                    label[j++] = num[k];
            }
            label[j] = '\0';

            print_field(6, 8 + i, label, 20);
        }
        selection_row(8 + active);

        uint32_t e = joy_edge();
        if (e & JOY_UP) {
            active = active ? active - 1 : n_items - 1;
        } else if (e & JOY_DOWN) {
            active = active < n_items - 1 ? active + 1 : 0;
        } else if (e & JOY_LEFT) {
            if (active == 0 && audio_volume > 0) {
                audio_volume--;
                audio_apply();
                audio_config_save();
            } else if (active == 1 && audio_bass > -5) {
                audio_bass--;
                audio_apply();
                audio_config_save();
            } else if (active == 2 && audio_treble > -5) {
                audio_treble--;
                audio_apply();
                audio_config_save();
            }
        } else if (e & JOY_RIGHT) {
            if (active == 0 && audio_volume < 10) {
                audio_volume++;
                audio_apply();
                audio_config_save();
            } else if (active == 1 && audio_bass < 5) {
                audio_bass++;
                audio_apply();
                audio_config_save();
            } else if (active == 2 && audio_treble < 5) {
                audio_treble++;
                audio_apply();
                audio_config_save();
            }
        } else if ((e & JOY_B) || ((e & JOY_A) && active == 3)) {
            return;
        }
        delay(20);
    }
}

// Returns non-zero when the player chooses to return to the ROM browser.
int pause_menu(void) {
    static const char *items[3] = {
        "Resume Game", "Reset Game", "Return to browser"
    };
    int active = 0;
    const int n_items = 6;

    audio_paused = 1;
    audio_apply();
    pce_pause(1);
    save_game_saves(0);
    clear();
    print_field(5, 5, "Game paused", OSD_COLS - 2);
    print_game_name();

    for (;;) {
        for (int i = 0; i < n_items; i++) {
            cursor(4, 8 + i);
            putchar(i == active ? '>' : ' ');

            char label[24];

            if (i < 3) {
                print_field(6, 8 + i, items[i], 20);
                continue;
            }

            if (i == 4) {
                print_field(6, 8 + i, "Video Settings >", 20);
                continue;
            }

            if (i == 5) {
                print_field(6, 8 + i, "Audio Settings >", 20);
                continue;
            }

            make_menu_label(label, 3);
            print_field(6, 8 + i, label, 20);
        }
        selection_row(8 + active);

        uint32_t e = joy_edge();
        if (e & JOY_UP) {
            active = active ? active - 1 : n_items - 1;
        } else if (e & JOY_DOWN) {
            active = active < n_items - 1 ? active + 1 : 0;
        } else if ((e & JOY_B) || (e & JOY_MENU) ||
                   ((e & JOY_A) && active == 0)) {
            pce_pause(0);
            audio_paused = 0;
            audio_apply();
            overlay(0);
            return 0;
        } else if ((e & JOY_A) && active == 1) {
            if (cd_active)
                cd_audio_reset();
            pce_reset();
            delay(20);
            pce_pause(0);
            audio_paused = 0;
            audio_apply();
            overlay(0);
            return 0;
        } else if ((e & JOY_A) && active == 2) {
            pce_stop();
            audio_paused = 0;
            audio_apply();
            return 1;
        } else if ((e & JOY_A) && active == 3) {
            game_pad_mode = !game_pad_mode;
            reg_pad_mode = game_pad_mode;
            game_pad_mode_save(current_game_name); // <--- Sauvegarde dans /config/[nomdujeu].cfg
        } else if ((e & JOY_A) && active == 4) {
            video_menu();
            clear();
            print_field(5, 5, "Game paused", OSD_COLS - 2);
            print_game_name();
        } else if ((e & JOY_A) && active == 5) {
            audio_menu();
            clear();
            print_field(5, 5, "Game paused", OSD_COLS - 2);
            print_game_name();
        }
        delay(20);
    }
}
