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
#include "core.h"

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
#define MENU_FRAME_WIDTH 26

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

static void print_game_name(int frame_width) {
    char label[OSD_COLS - 4];
    const char *end = current_game_name;
    const char *extension = 0;
    int max_len = frame_width - 2;
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

    while (current_game_name + i < end && i < max_len) {
        label[i] = current_game_name[i];
        i++;
    }
    label[i] = '\0';
    cursor((OSD_COLS - i) / 2, 6);
    print(label);
}

static void menu_frame(int width) {
    int left = (OSD_COLS - width) / 2;
    int right = left + width - 1;

    cursor(left, 4);
    putchar('`');
    for (int column = left + 1; column < right; column++)
        putchar('~');
    putchar('^');

    for (int row = 5; row < 18; row++) {
        cursor(left, row);
        putchar('|');
        cursor(right, row);
        putchar('|');
    }

    cursor(left, 7);
    putchar('\\');
    for (int column = left + 1; column < right; column++)
        putchar('~');
    putchar(0x7f);

    cursor(left, 18);
    putchar('{');
    for (int column = left + 1; column < right; column++)
        putchar('~');
    putchar('}');
}

static void menu_header(const char *heading, int in_game, int frame_width) {
    clear();
    if (in_game)
        menu_frame(frame_width);
    if (in_game) {
        int inner_width = frame_width - 2;
        int heading_len = (int)strlen(heading);
        int x = (OSD_COLS - frame_width) / 2 + 1;
        if (heading_len < inner_width)
            x += (inner_width - heading_len) / 2;
        print_field(x, 5, heading, heading_len < inner_width ? heading_len : inner_width);
    } else {
        print_field(5, 5, heading, OSD_COLS - 6);
    }
    if (in_game)
        print_game_name(frame_width);
}

static int cheats_frame_width(void) {
    int width = MENU_FRAME_WIDTH;
    int maximum = OSD_COLS - 4;

    for (int index = 0; index < cheats_count(); index++) {
        int required = (int)strlen(cheats_description(index)) + 6;
        if (required > width)
            width = required;
    }
    return width > maximum ? maximum : width;
}

static void make_menu_label(char *buf, int type) {
    const char *prefix;
    const char *value;
    int i = 0;

    if (type == 3) {
        prefix = "Gamepad: ";
        value = game_pad_mode == 2 ? "Street Fighter" :
                game_pad_mode == 1 ? "6 buttons" : "2 buttons";
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
    int redraw = 1;
    int frame_width = cheats_frame_width();
    int frame_left = (OSD_COLS - frame_width) / 2;
    int item_width = frame_width - 4;
    menu_header("Cheats", 1, frame_width);

    for (;;) {
        int count = cheats_count();
        int first_row = count > 8 ? 8 : 9;
        int visible_rows = count > 8 ? 10 : 8;
        int status = 0;
        if (redraw) {
            for (int row = 8; row < 18; row++)
                print_field(frame_left + 1, row, "", frame_width - 2);
        }
        if (redraw && count > 0) {
            if (active >= count)
                active = count - 1;
            if (active < first)
                first = active;
            if (active >= first + visible_rows)
                first = active - visible_rows + 1;
            for (int row = 0; row < visible_rows; row++) {
                int index = first + row;
                cursor(frame_left + 1, first_row + row);
                putchar(index < count && index == active ? '>' : ' ');
                if (index < count) {
                    char label[25];
                    const char *description = cheats_description(index);
                    int pos = 0;
                    const char *enabled = cheats_is_active(index) ? "x " : "o ";
                    while (*enabled)
                        label[pos++] = *enabled++;
                    while (*description && pos < (int)sizeof(label) - 1)
                        label[pos++] = *description++;
                    label[pos] = '\0';
                    print_field(frame_left + 3, first_row + row, label, item_width);
                } else {
                    print_field(frame_left + 3, first_row + row, "", item_width);
                }
            }
            selection_row(first_row + active - first);
            status = *cheats_status() != '\0';
            print_field(1, 19, status ? cheats_status() : "A=Toggle  B=Back",
                        OSD_COLS - 2);
        } else if (redraw) {
            const char *message = *cheats_status() ? cheats_status() : "No cheats found";
            int inner_width = frame_width - 2;
            int message_len = (int)strlen(message);
            int x = frame_left + 1;
            if (message_len < inner_width)
                x += (inner_width - message_len) / 2;
            print_field(x, 10, message, message_len < inner_width ? message_len : inner_width);
            print_field(1, 19, "B=Back", OSD_COLS - 2);
        }
        redraw = 0;

        uint32_t e = joy_edge();
        if ((e & JOY_B) || (e & JOY_MENU))
            return;
        if (count > 0 && (e & JOY_UP)) {
            active = active ? active - 1 : count - 1;
            redraw = 1;
        } else if (count > 0 && (e & JOY_DOWN)) {
            active = active < count - 1 ? active + 1 : 0;
            redraw = 1;
        } else if (count > 0 && (e & JOY_A)) {
            cheats_toggle(active);
            redraw = 1;
        }
        delay(20);
    }
}

// Color/Zoom/Scanlines sub-menu, reached from "Video Settings >" in
// pause_menu.  Gamepad mode lives directly in pause_menu, not here.
static void video_menu(int in_game) {
    static const char *back_label = "Back";
    int active = 0;
    const int n_items = 4;
    const int first_row = in_game ? 9 : 8;

    menu_header("Video Settings", in_game, MENU_FRAME_WIDTH);

    for (;;) {
        for (int i = 0; i < n_items; i++) {
            cursor(4, first_row + i);
            putchar(i == active ? '>' : ' ');

            char label[24];

            if (i == 3) {
                print_field(6, first_row + i, back_label, 20);
                continue;
            }

            make_menu_label(label, i + 4);
            print_field(6, first_row + i, label, 20);
        }
        selection_row(first_row + active);

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

// Global audio options are available in the browser; in-game keeps only live mix controls.
static void audio_menu(int in_game) {
    static const char *labels[7] = {
        "Volume", "Bass", "Treble", "Output", "CD-DA", "ADPCM audio", "Back"
    };
    int active = 0;
    const int n_items = in_game ? 4 : 7;
    const int first_row = in_game ? 9 : 8;

    menu_header("Audio Settings", in_game, MENU_FRAME_WIDTH);

    for (;;) {
        for (int i = 0; i < n_items; i++) {
            cursor(4, first_row + i);
            putchar(i == active ? '>' : ' ');

            char label[24];
            int j = 0;
            const char *prefix = (in_game && i == 3) ? "Back" : labels[i];
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
            } else if (!in_game && i == 3) {
                const char *value = audio_output_hdmi ? "HDMI" : "Speaker";
                label[j++] = ':';
                label[j++] = ' ';
                while (*value)
                    label[j++] = *value++;
            } else if (!in_game && (i == 4 || i == 5)) {
                const char *value = (i == 4 ? audio_cdda_enabled : audio_adpcm_enabled)
                    ? "On" : "Off";
                label[j++] = ':';
                label[j++] = ' ';
                while (*value)
                    label[j++] = *value++;
            }
            label[j] = '\0';

            print_field(6, first_row + i, label, 20);
        }
        selection_row(first_row + active);

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
            } else if (!in_game && active == 3) {
                audio_output_hdmi = !audio_output_hdmi;
                audio_apply();
                audio_config_save();
            } else if (!in_game && (active == 4 || active == 5)) {
                if (active == 4)
                    audio_cdda_enabled = !audio_cdda_enabled;
                else
                    audio_adpcm_enabled = !audio_adpcm_enabled;
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
            } else if (!in_game && active == 3) {
                audio_output_hdmi = !audio_output_hdmi;
                audio_apply();
                audio_config_save();
            } else if (!in_game && (active == 4 || active == 5)) {
                if (active == 4)
                    audio_cdda_enabled = !audio_cdda_enabled;
                else
                    audio_adpcm_enabled = !audio_adpcm_enabled;
                audio_apply();
                audio_config_save();
            }
        } else if ((e & JOY_B) || ((e & JOY_A) && active == n_items - 1)) {
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
    const int first_row = 9;
    const int has_cheats = CORE_PROFILE_ID == CORE_PROFILE_PCE ||
                           CORE_PROFILE_ID == CORE_PROFILE_SGX ||
                           CORE_PROFILE_ID == CORE_PROFILE_CD ||
                           CORE_PROFILE_ID == CORE_PROFILE_SUPERSET;

    vdc_timing_dump();
    audio_paused = 1;
    audio_apply();
    pce_pause(1);
    save_game_saves(0);
    menu_header("Game paused", 1, MENU_FRAME_WIDTH);

    for (;;) {
        for (int i = 0; i < n_items; i++) {
            cursor(4, first_row + i);
            putchar(i == active ? '>' : ' ');

            char label[24];

            if (i == 0) {
                print_field(6, first_row + i, items[0], 20);
                continue;
            }

            if (i == 2) {
                print_field(6, first_row + i, "Video Settings >", 20);
                continue;
            }

            if (i == 3) {
                print_field(6, first_row + i, "Audio Settings >", 20);
                continue;
            }

            if (i == 4) {
                if (has_cheats) {
                    make_cheats_label(label);
                    print_field(6, first_row + i, label, 20);
                } else {
                    print_field(6, first_row + i, "Cheats unavailable", 20);
                }
                continue;
            }

            if (i == 1) {
                make_menu_label(label, 3);
                print_field(6, first_row + i, label, 20);
                continue;
            }

            print_field(6, first_row + i, items[i - 4], 20);
        }
        selection_row(first_row + active);

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
            overlay(0);
            clear();
            selection_row(31);
            pce_stop();
            audio_paused = 0;
            audio_apply();
            return 1;
        } else if ((e & JOY_A) && active == 1) {
            game_pad_mode = (game_pad_mode + 1) % 3;
            reg_pad_mode = game_pad_mode;
            game_pad_mode_save(current_game_name); // <--- Sauvegarde dans /config/[nomdujeu].cfg
        } else if ((e & JOY_A) && active == 2) {
            video_menu(1);
            menu_header("Game paused", 1, MENU_FRAME_WIDTH);
        } else if ((e & JOY_A) && active == 3) {
            audio_menu(1);
            menu_header("Game paused", 1, MENU_FRAME_WIDTH);
        } else if ((e & JOY_A) && active == 4) {
            if (has_cheats) {
                cheats_menu();
                menu_header("Game paused", 1, MENU_FRAME_WIDTH);
            } else {
                message("Cheats unavailable", "Not in this core");
                menu_header("Game paused", 1, MENU_FRAME_WIDTH);
            }
        }
        delay(20);
    }
}

// Global options reached with Select from the ROM browser.
void options_menu(void) {
    static const char *items[7] = {
        "Video Settings >", "Audio Settings >", "Debug UART: ",
        "Cheats: ", "Sprites: ", "Choose core >", "Back"
    };
    const int n_items = 7;
    int active = 0;

    menu_header("Options", 0, MENU_FRAME_WIDTH);

    for (;;) {
        for (int i = 0; i < n_items; i++) {
            cursor(4, 8 + i);
            putchar(i == active ? '>' : ' ');

            if (i >= 2 && i <= 4) {
                char label[32];
                const char *value = i == 2
                    ? (debug_uart ? "On" : "Off")
                    : i == 3 ? (cheats_enabled ? "On" : "Off")
                    : vdc_sprites_double ? "32" : "16";
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
        } else if ((e & (JOY_B | JOY_SELECT)) || ((e & JOY_A) && active == 6)) {
            return;
        } else if ((e & JOY_A) && active == 0) {
            video_menu(0);
            menu_header("Options", 0, MENU_FRAME_WIDTH);
        } else if ((e & JOY_A) && active == 1) {
            audio_menu(0);
            menu_header("Options", 0, MENU_FRAME_WIDTH);
        } else if ((e & JOY_A) && active == 2) {
            debug_uart = !debug_uart;
            system_config_save();
        } else if ((e & JOY_A) && active == 3) {
            cheats_enabled = !cheats_enabled;
            system_config_save();
        } else if ((e & JOY_A) && active == 4) {
            vdc_sprites_double = !vdc_sprites_double;
            vdc_options_apply();
            system_config_save();
        } else if ((e & JOY_A) && active == 5) {
            core_menu();
            menu_header("Options", 0, MENU_FRAME_WIDTH);
        }
        delay(20);
    }
}
