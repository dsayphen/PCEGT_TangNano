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
#include "cheats.h"

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

// Snapshot of the HuC6260/HuC6270 timing registers as the running game has
// programmed them, plus the number of pixels the scandoubler actually latched
// on the last core scan line.  Read-only, for diagnosing geometry problems.
void vdc_timing_dump(void) {
    int hsw = (int)reg_vid_hsw_dbg();
    int hds = (int)reg_vid_hds_dbg();
    // reg_vid_hdw_dbg() is HDISP_END - HDS_END, i.e. HDW + 1 = character count
    int hdw_chars = (int)reg_vid_hdw_dbg();
    int hde = (int)reg_vid_hde_dbg();
    int dcc = (int)reg_vid_dcc_dbg();
    static const int dcc_dots[4] = { 270, 360, 540, 540 };

    uart_printf("vdc raw %x %x %x\n",
                (unsigned)reg_color_mode, (unsigned)reg_pad_mode,
                (unsigned)reg_rom_pop);
    uart_printf("vce cr=%x dcc=%d dots_avail=%d px_per_line=%d\n",
                (unsigned)reg_vce_cr_dbg(), dcc, dcc_dots[dcc],
                (int)reg_vid_px_dbg() + 1);
    uart_printf("vce wr400=%d last400=%x lastreg=%d\n",
                (int)reg_vce_cr_wr(), (unsigned)reg_vce_cr_last(),
                (int)reg_vce_last_a());
    uart_printf("vdc hsw=%d hds=%d hdw=%d hde=%d chars=%d\n",
                hsw, hds, hdw_chars - 1, hde,
                (hsw + 1) + (hds + 1) + hdw_chars + (hde + 1));
    uart_printf("vdc hds_px=%d hdw_px=%d\n", (hds + 1) * 8, hdw_chars * 8);
    uart_printf("vdc vsw=%d vds=%d vdw=%d vcr=%d vlines=%d\n",
                (int)reg_vid_vsw_dbg(), (int)reg_vid_vds_dbg(),
                (int)reg_vid_vdw_dbg(), (int)reg_vid_vcr_dbg(),
                (int)reg_vid_vdw_dbg() + 1);
}

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

    for (const char *part = current_game_name; part < end; part++) {
        if (*part == '(' || (*part == '-' && end - current_game_name > OSD_COLS - 5)) {
            end = part;
            break;
        }
    }
    while (end > current_game_name && end[-1] == ' ')
        end--;

    while (current_game_name + i < end && i < OSD_COLS - 5) {
        label[i] = current_game_name[i];
        i++;
    }
    label[i] = '\0';
    print_field(5, 6, label, OSD_COLS - 5);
}

static void menu_header(const char *heading, int in_game) {
    clear();
    print_field(5, 5, heading, OSD_COLS - 2);
    if (in_game)
        print_game_name();
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

static void make_cheats_label(char *buf) {
    char number[4];
    int pos = 0;
    int len;
    const char *prefix = "Cheats (";
    while (*prefix)
        buf[pos++] = *prefix++;
    len = u8_to_str(number, (uint8_t)cheats_active_count());
    for (int i = 0; i < len; i++)
        buf[pos++] = number[i];
    buf[pos++] = '/';
    len = u8_to_str(number, (uint8_t)cheats_count());
    for (int i = 0; i < len; i++)
        buf[pos++] = number[i];
    buf[pos++] = ')';
    buf[pos] = '\0';
}

static void cheats_menu(void) {
    int active = 0;
    int first = 0;
    const int visible_rows = 10;
    clear();
    print_field(5, 5, "Cheats", OSD_COLS - 2);
    print_game_name();

    for (;;) {
        int count = cheats_count();
        int status = 0;
        if (count > 0) {
            if (active >= count)
                active = count - 1;
            if (active < first)
                first = active;
            if (active >= first + visible_rows)
                first = active - visible_rows + 1;
            for (int row = 0; row < visible_rows; row++) {
                int index = first + row;
                cursor(4, 8 + row);
                putchar(index < count && index == active ? '>' : ' ');
                if (index < count) {
                    char label[25];
                    const char *description = cheats_description(index);
                    int pos = 0;
                    const char *enabled = cheats_is_active(index) ? "[ON] " : "[OFF] ";
                    while (*enabled)
                        label[pos++] = *enabled++;
                    while (*description && pos < (int)sizeof(label) - 1)
                        label[pos++] = *description++;
                    label[pos] = '\0';
                    print_field(6, 8 + row, label, 25);
                } else {
                    print_field(6, 8 + row, "", 25);
                }
            }
            selection_row(8 + active - first);
            status = *cheats_status() != '\0';
            print_field(1, 19, status ? cheats_status() : "A=Toggle  B=Back",
                        OSD_COLS - 2);
        } else {
            for (int row = 0; row < visible_rows; row++)
                clear_line(8 + row);
            print_field(2, 10, *cheats_status() ? cheats_status() : "No cheats found",
                        OSD_COLS - 4);
            print_field(1, 19, "B=Back", OSD_COLS - 2);
        }

        uint32_t e = joy_edge();
        if ((e & JOY_B) || (e & JOY_MENU))
            return;
        if (count > 0 && (e & JOY_UP))
            active = active ? active - 1 : count - 1;
        else if (count > 0 && (e & JOY_DOWN))
            active = active < count - 1 ? active + 1 : 0;
        else if (count > 0 && (e & JOY_A))
            cheats_toggle(active);
        delay(20);
    }
}

// Color/Zoom/Scanlines sub-menu, reached from "Video Settings >" in
// pause_menu.  Gamepad mode lives directly in pause_menu, not here.
static void video_menu(int in_game) {
    static const char *back_label = "Back";
    int active = 0;
    const int n_items = 4;

    menu_header("Video Settings", in_game);

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
static void audio_menu(int in_game) {
    static const char *labels[5] = {
        "Volume", "Bass", "Treble", "Output", "Back"
    };
    int active = 0;
    const int n_items = 5;

    menu_header("Audio Settings", in_game);

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
            } else if (i == 3) {
                const char *value = audio_output_hdmi ? "HDMI" : "Speaker";
                label[j++] = ':';
                label[j++] = ' ';
                while (*value)
                    label[j++] = *value++;
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
            } else if (active == 3) {
                audio_output_hdmi = !audio_output_hdmi;
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
            } else if (active == 3) {
                audio_output_hdmi = !audio_output_hdmi;
                audio_apply();
                audio_config_save();
            }
        } else if ((e & JOY_B) || ((e & JOY_A) && active == 4)) {
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
    const int n_items = 7;
    const int has_cheats = CORE_PROFILE_ID == CORE_PROFILE_SGX ||
                           CORE_PROFILE_ID == CORE_PROFILE_SUPERSET;

    vdc_timing_dump();
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

            if (i == 0) {
                print_field(6, 8 + i, items[0], 20);
                continue;
            }

            if (i == 2) {
                print_field(6, 8 + i, "Video Settings >", 20);
                continue;
            }

            if (i == 3) {
                print_field(6, 8 + i, "Audio Settings >", 20);
                continue;
            }

            if (i == 4) {
                if (has_cheats) {
                    make_cheats_label(label);
                    print_field(6, 8 + i, label, 20);
                } else {
                    print_field(6, 8 + i, "Cheats unavailable", 20);
                }
                continue;
            }

            if (i == 1) {
                make_menu_label(label, 3);
                print_field(6, 8 + i, label, 20);
                continue;
            }

            print_field(6, 8 + i, items[i - 4], 20);
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
        } else if ((e & JOY_A) && active == 5) {
            if (cd_active)
                cd_audio_reset();
            pce_reset();
            delay(20);
            pce_pause(0);
            audio_paused = 0;
            audio_apply();
            overlay(0);
            return 0;
        } else if ((e & JOY_A) && active == 6) {
            cheats_clear();
            pce_stop();
            audio_paused = 0;
            audio_apply();
            return 1;
        } else if ((e & JOY_A) && active == 1) {
            game_pad_mode = !game_pad_mode;
            reg_pad_mode = game_pad_mode;
            game_pad_mode_save(current_game_name); // <--- Sauvegarde dans /config/[nomdujeu].cfg
        } else if ((e & JOY_A) && active == 2) {
            video_menu(1);
            clear();
            print_field(5, 5, "Game paused", OSD_COLS - 2);
            print_game_name();
        } else if ((e & JOY_A) && active == 3) {
            audio_menu(1);
            clear();
            print_field(5, 5, "Game paused", OSD_COLS - 2);
            print_game_name();
        } else if ((e & JOY_A) && active == 4) {
            if (has_cheats) {
                cheats_menu();
                clear();
                print_field(5, 5, "Game paused", OSD_COLS - 2);
                print_game_name();
            } else {
                message("Cheats unavailable", "Not in this core");
                clear();
                print_field(5, 5, "Game paused", OSD_COLS - 2);
                print_game_name();
            }
        }
        delay(20);
    }
}

// Global options reached with Select from the ROM browser.
void options_menu(void) {
    static const char *items[5] = {
        "Video Settings >", "Audio Settings >", "Debug UART: ",
        "Cheat CD (exp.): ", "Back"
    };
    const int n_items = 5;
    int active = 0;

    menu_header("Options", 0);

    for (;;) {
        for (int i = 0; i < n_items; i++) {
            cursor(4, 8 + i);
            putchar(i == active ? '>' : ' ');

            if (i == 2 || i == 3) {
                char label[32];
                const char *value = i == 2
                    ? (debug_uart ? "On" : "Off")
                    : (cheat_cd_enabled ? "On" : "Off");
                int j = 0;
                for (const char *s = items[i]; *s; s++)
                    label[j++] = *s;
                while (*value)
                    label[j++] = *value++;
                label[j] = '\0';
                print_field(6, 8 + i, label, 20);
            } else {
                print_field(6, 8 + i, items[i], 20);
            }
        }
        selection_row(8 + active);
        print_field(1, ROW_STATUS, "A=Select  B=Back", OSD_COLS - 2);

        uint32_t e = joy_edge();
        if (e & JOY_UP) {
            active = active ? active - 1 : n_items - 1;
        } else if (e & JOY_DOWN) {
            active = active < n_items - 1 ? active + 1 : 0;
        } else if ((e & (JOY_B | JOY_SELECT)) || ((e & JOY_A) && active == 4)) {
            return;
        } else if ((e & JOY_A) && active == 0) {
            video_menu(0);
            menu_header("Options", 0);
        } else if ((e & JOY_A) && active == 1) {
            audio_menu(0);
            menu_header("Options", 0);
        } else if ((e & JOY_A) && active == 2) {
            debug_uart = !debug_uart;
            system_config_save();
        } else if ((e & JOY_A) && active == 3) {
            cheat_cd_enabled = !cheat_cd_enabled;
            system_config_save();
        }
        delay(20);
    }
}
