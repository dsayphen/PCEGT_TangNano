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

static const char *zoom_names[3] = { "Integer", "Stretch", "Bilinear" };
static const char *scan_names[4] = { "Off", "25%", "50%", "100%" };
static const char *grid_names[4] = { "Off", "10%", "20%", "30%" };
static const char *color_names[2] = { "RAW RGB", "Composite" };
static const char *gb_color_names[4] = { "Off", "DMG", "Pocket", "Light" };
static const char *gbc_color_names[3] = { "Off", "Accurate", "Fast" };
static const char *nes_color_names[8] = {
    "Original", "Comp. Direct", "NES Classic", "PC-10",
    "PVM Style D93", "Smooth", "Sony CXA", "Wavebeam"
};

static const char *zoom_name(void) {
    return video_is_gameboy() ?
           (video_zoom ? "Wide Stretch" : "Integer") : zoom_names[video_zoom];
}

static int selection_step(uint32_t events, int choices) {
    if (events & JOY_A)
        return 1;
    if (choices > 2) {
        if (events & JOY_LEFT)
            return -1;
        if (events & JOY_RIGHT)
            return 1;
    }
    return 0;
}

static int video_color_count(void) {
    return CORE_PROFILE_ID != CORE_PROFILE_NINTENDO8 ? 2 :
           !video_is_gameboy() ? 8 : video_is_gbc() ? 3 : 4;
}

static void advance_zoom(int dir) {
    int current = video_is_gameboy() ? !!video_zoom : video_zoom;
    video_zoom = (current + dir + video_zoom_count()) % video_zoom_count();
    reg_video_zoom = video_zoom;
}

static void cycle_video_setting(int command, int dir) {
    if (command == 0) {
        if (CORE_PROFILE_ID == CORE_PROFILE_NINTENDO8) {
            if (video_is_gbc())
                gbc_color = (gbc_color + dir + 3) % 3;
            else if (video_is_gameboy())
                gb_palette = (gb_palette + dir + 4) % 4;
            else
                nes_palette = (nes_palette + dir + 8) % 8;
            nintendo_color_apply();
        } else {
            video_color = !video_color;
            reg_color_mode = video_color;
        }
    } else if (command == 1) {
        advance_zoom(dir);
    } else {
        video_scanline = (video_scanline + dir + 4) % 4;
        reg_scanline = video_scanline;
    }
    video_config_save();
}

// Cycle the display zoom mode (2x -> stretch -> ...) and flash the new
// setting on the OSD for a moment.  Kept in sync with rtl/tang/iosys/iosys.v
// (reg_video_zoom) and rtl/tang/video_scandoubler.v.
void zoom_cycle(void) {
    advance_zoom(1);
    video_config_save();

    clear();
    char label[24];
    strcpy(label, "Zoom: ");
    strcat(label, zoom_name());
    print_field(1, 10, label, OSD_COLS - 2);
    overlay(1);
    delay(600);
    overlay(0);
}

// Cycle scanlines (0/25/50/100%) or GB grid (0/10/20/30%) and flash the setting on
// the OSD for a moment.  `dir` is +1 to increase, -1 to decrease; the value
// wraps around in both directions.  Kept in sync with
// rtl/tang/iosys/iosys.v (reg_scanline) and rtl/tang/video_scandoubler.v.
void scanline_cycle(int dir) {
    video_scanline = (video_scanline + dir + 4) % 4;
    reg_scanline = video_scanline;
    video_config_save();

    clear();
    char label[24];
    strcpy(label, video_is_gameboy() ? "Grid: " : "Scanlines: ");
    strcat(label, (video_is_gameboy() ? grid_names : scan_names)[video_scanline]);
    print_field(1, 10, label, OSD_COLS - 2);
    overlay(1);
    delay(600);
    overlay(0);
}

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
        value = game_pad_mode == 2 ? "SF2" :
                game_pad_mode == 1 ? "6 buttons" : "2 buttons";
    } else if (type == 4) {
        prefix = "Color: ";
        value = CORE_PROFILE_ID != CORE_PROFILE_NINTENDO8 ? color_names[video_color] :
                video_is_gbc() ? gbc_color_names[gbc_color] :
                video_is_gameboy() ? gb_color_names[gb_palette] :
                nes_color_names[nes_palette];
    } else if (type == 5) {
        prefix = "Zoom: ";
        value = zoom_name();
    } else {
        prefix = video_is_gameboy() ? "Grid: " : "Scanlines: ";
        value = (video_is_gameboy() ? grid_names : scan_names)[video_scanline];
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
    const int simple_video = CORE_PROFILE_ID == CORE_PROFILE_SNES ||
                             CORE_PROFILE_ID == CORE_PROFILE_MEGADRIVE;
    const int n_items = simple_video ? 3 : 4;
    const int first_row = in_game ? 9 : 8;

    menu_header("Video Settings", in_game, MENU_FRAME_WIDTH);

    for (;;) {
        for (int i = 0; i < n_items; i++) {
            int item = simple_video ? i + 1 : i;
            cursor(4, first_row + i);
            putchar(i == active ? '>' : ' ');

            char label[24];

            if (item == 3) {
                print_field(6, first_row + i, back_label, 20);
                continue;
            }

            make_menu_label(label, item + 4);
            print_field(6, first_row + i, label, 20);
        }
        selection_row(first_row + active);

        uint32_t e = joy_edge();
        int command = simple_video ? active + 1 : active;
        int choices = command == 0 ? video_color_count() :
                      command == 1 ? video_zoom_count() : command == 2 ? 4 : 0;
        int dir = selection_step(e, choices);
        if (e & JOY_UP) {
            active = active ? active - 1 : n_items - 1;
        } else if (e & JOY_DOWN) {
            active = active < n_items - 1 ? active + 1 : 0;
        } else if ((e & JOY_B) || ((e & JOY_A) && command == 3)) {
            return;
        } else if (dir && command < 3) {
            cycle_video_setting(command, dir);
        }
        delay(20);
    }
}

// Global audio options are available in the browser; in-game keeps only live mix controls.
static void audio_menu(int in_game) {
    static const char *labels[7] = {
        "Volume", "Bass", "Treble", "Output", "CD-DA", "ADPCM audio", "Back"
    };
    // The SNES profile has master volume only: bass/treble do not fit in its FPGA build.
    static const uint8_t snes_game_items[] = { 0, 6 };
    static const uint8_t snes_browser_items[] = { 0, 3, 6 };
    static const uint8_t pce_game_items[] = { 0, 1, 2, 6 };
    static const uint8_t pce_browser_items[] = { 0, 1, 2, 3, 4, 5, 6 };
    int active = 0;
    const int snes_profile = CORE_PROFILE_ID == CORE_PROFILE_SNES;
    const int md_profile = CORE_PROFILE_ID == CORE_PROFILE_MEGADRIVE;
    const uint8_t *items = (md_profile || snes_profile) ? (in_game ? snes_game_items : snes_browser_items)
                                        : (in_game ? pce_game_items : pce_browser_items);
    const int n_items = (md_profile || snes_profile) ? (in_game ? 2 : 3) : (in_game ? 4 : 7);
    const int first_row = in_game ? 9 : 8;

    menu_header("Audio Settings", in_game, MENU_FRAME_WIDTH);

    for (;;) {
        for (int i = 0; i < n_items; i++) {
            const int item = items[i];
            cursor(4, first_row + i);
            putchar(i == active ? '>' : ' ');

            char label[24];
            int j = 0;
            const char *prefix = labels[item];
            while (*prefix)
                label[j++] = *prefix++;

            if (item < 3) {
                int val = (item == 0) ? audio_volume : (item == 1) ? audio_bass : audio_treble;
                char num[4];
                int len;

                label[j++] = ':';
                label[j++] = ' ';
                if (item > 0 && val > 0) {
                    label[j++] = '+';
                } else if (item > 0 && val < 0) {
                    label[j++] = '-';
                    val = -val;
                }
                len = u8_to_str(num, (uint8_t)val);
                for (int k = 0; k < len; k++)
                    label[j++] = num[k];
            } else if (item == 3) {
                const char *value = audio_output_hdmi ? "HDMI" : "Speaker";
                label[j++] = ':';
                label[j++] = ' ';
                while (*value)
                    label[j++] = *value++;
            } else if (item == 4 || item == 5) {
                const char *value = (item == 4 ? audio_cdda_enabled : audio_adpcm_enabled)
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
        } else if (e & (JOY_LEFT | JOY_RIGHT)) {
            const int step = (e & JOY_LEFT) ? -1 : 1;
            const int item = items[active];
            int changed = 1;
            if (item == 0 && audio_volume + step >= 0 && audio_volume + step <= 10)
                audio_volume += step;
            else if (item == 1 && audio_bass + step >= -5 && audio_bass + step <= 5)
                audio_bass += step;
            else if (item == 2 && audio_treble + step >= -5 && audio_treble + step <= 5)
                audio_treble += step;
            else if (item == 3)
                audio_output_hdmi = !audio_output_hdmi;
            else if (item == 4)
                audio_cdda_enabled = !audio_cdda_enabled;
            else if (item == 5)
                audio_adpcm_enabled = !audio_adpcm_enabled;
            else
                changed = 0;
            if (changed) {
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
    const int snes_profile = CORE_PROFILE_ID == CORE_PROFILE_SNES ||
                             CORE_PROFILE_ID == CORE_PROFILE_MEGADRIVE;
    const int snes_items[5] = {0, 2, 3, 5, 6};
    const int n_items = snes_profile ? 5 : 7;
    const int first_row = 9;
    const int has_cheats = CORE_PROFILE_ID == CORE_PROFILE_PCE ||
                           CORE_PROFILE_ID == CORE_PROFILE_SGX ||
                           CORE_PROFILE_ID == CORE_PROFILE_CD;

    if (!snes_profile)
        vdc_timing_dump();
    audio_paused = 1;
    audio_apply();
    pce_pause(1);
    save_game_saves(0);
    menu_header("Game paused", 1, MENU_FRAME_WIDTH);

    for (;;) {
        for (int i = 0; i < n_items; i++) {
            int item = snes_profile ? snes_items[i] : i;
            cursor(4, first_row + i);
            putchar(i == active ? '>' : ' ');

            char label[24];

            if (item == 0) {
                print_field(6, first_row + i, items[0], 20);
                continue;
            }

            if (item == 2) {
                print_field(6, first_row + i, "Video Settings >", 20);
                continue;
            }

            if (item == 3) {
                print_field(6, first_row + i, "Audio Settings >", 20);
                continue;
            }

            if (item == 4) {
                if (has_cheats) {
                    make_cheats_label(label);
                    print_field(6, first_row + i, label, 20);
                } else {
                    print_field(6, first_row + i, "Cheats unavailable", 20);
                }
                continue;
            }

            if (item == 1) {
                make_menu_label(label, 3);
                print_field(6, first_row + i, label, 20);
                continue;
            }

            print_field(6, first_row + i, items[item - 4], 20);
        }
        selection_row(first_row + active);

        uint32_t e = joy_edge();
        int command = snes_profile ? snes_items[active] : active;
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
        } else if ((e & JOY_A) && command == 5) {
            if (cd_active)
                cd_audio_reset();
            pce_reset();
            delay(20);
            pce_pause(0);
            audio_paused = 0;
            audio_apply();
            overlay(0);
            return 0;
        } else if ((e & JOY_A) && command == 6) {
            if (CORE_PROFILE_ID != CORE_PROFILE_MEGADRIVE)
                cheats_clear();
            overlay(0);
            clear();
            selection_row(31);
            pce_stop();
            audio_paused = 0;
            audio_apply();
            return 1;
        } else if (selection_step(e, 3) && command == 1) {
            game_pad_mode = (game_pad_mode + selection_step(e, 3) + 3) % 3;
            reg_pad_mode = game_pad_mode;
            game_pad_mode_save(current_game_name); // <--- Sauvegarde dans /config/[nomdujeu].cfg
        } else if ((e & JOY_A) && command == 2) {
            video_menu(1);
            menu_header("Game paused", 1, MENU_FRAME_WIDTH);
        } else if ((e & JOY_A) && command == 3) {
            audio_menu(1);
            menu_header("Game paused", 1, MENU_FRAME_WIDTH);
        } else if ((e & JOY_A) && command == 4) {
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
    static const char *items[8] = {
        "Video Settings >", "Audio Settings >", "Debug UART: ",
        "Cheats: ", "Sprites: ", "Choose core >", "Back", "Region: "
    };
    const int snes_items[6] = {0, 1, 2, 7, 5, 6};
    const int snes_profile = CORE_PROFILE_ID == CORE_PROFILE_SNES ||
                             CORE_PROFILE_ID == CORE_PROFILE_MEGADRIVE;
    const int region_supported =
        CORE_PROFILE_ID == CORE_PROFILE_MEGADRIVE &&
        CORE_EXTENDED_SETTINGS_SUPPORTED;
    const int n_items = snes_profile ? 6 : 7;
    int active = 0;

    menu_header("Options", 0, MENU_FRAME_WIDTH);

    for (;;) {
        for (int i = 0; i < n_items; i++) {
            int item = snes_profile ? snes_items[i] : i;
            cursor(4, 8 + i);
            putchar(i == active ? '>' : ' ');

            if (item == 7) {
                static const char *regions[] = {
                    "NTSC US", "NTSC Japan"
                };
                char label[32];
                int j = 0;
                for (const char *s = items[item]; *s; s++)
                    label[j++] = *s;
                const char *value = CORE_PROFILE_ID == CORE_PROFILE_SNES
                    ? "NTSC only"
                    : region_supported ? regions[console_region] : "Update core";
                while (*value)
                    label[j++] = *value++;
                label[j] = '\0';
                print_field(6, 8 + i, label, 20);
            } else if (item >= 2 && item <= 4) {
                char label[32];
                const char *value = item == 2
                    ? (debug_uart ? "On" : "Off")
                    : item == 3 ? (cheats_enabled ? "On" : "Off")
                    : vdc_sprites_double ? "32" : "16";
                int j = 0;
                for (const char *s = items[item]; *s; s++)
                    label[j++] = *s;
                while (*value)
                    label[j++] = *value++;
                label[j] = '\0';
                print_field(6, 8 + i, label, 20);
            } else {
                print_field(6, 8 + i, items[item], 20);
            }
        }
        int command = snes_profile ? snes_items[active] : active;
        selection_row(8 + active);
        print_field(1, ROW_STATUS,
                    command == 7 && !region_supported
                        ? CORE_PROFILE_ID == CORE_PROFILE_SNES
                            ? "SNES region: NTSC only"
                            : "Update core for region"
                        : "A=Select  B=Back",
                    OSD_COLS - 2);

        uint32_t e = joy_edge();
        if (e & JOY_UP) {
            active = active ? active - 1 : n_items - 1;
        } else if (e & JOY_DOWN) {
            active = active < n_items - 1 ? active + 1 : 0;
        } else if ((e & (JOY_B | JOY_SELECT)) || ((e & JOY_A) && command == 6)) {
            return;
        } else if ((e & (JOY_LEFT | JOY_RIGHT)) && command == 7 &&
                   region_supported) {
            int step = (e & JOY_LEFT) ? -1 : 1;
            console_region = (console_region + step + 2) % 2;
            console_region_apply();
            system_config_save();
        } else if ((e & JOY_A) && command == 0) {
            video_menu(0);
            menu_header("Options", 0, MENU_FRAME_WIDTH);
        } else if ((e & JOY_A) && command == 1) {
            audio_menu(0);
            menu_header("Options", 0, MENU_FRAME_WIDTH);
        } else if ((e & JOY_A) && command == 2) {
            debug_uart = !debug_uart;
            system_config_save();
        } else if ((e & JOY_A) && command == 3) {
            cheats_enabled = !cheats_enabled;
            system_config_save();
        } else if ((e & JOY_A) && command == 4) {
            vdc_sprites_double = !vdc_sprites_double;
            vdc_options_apply();
            system_config_save();
        } else if ((e & JOY_A) && command == 7 && region_supported) {
            console_region = (console_region + 1) % 2;
            console_region_apply();
            system_config_save();
        } else if ((e & JOY_A) && command == 5) {
            core_menu();
            menu_header("Options", 0, MENU_FRAME_WIDTH);
        }
        delay(20);
    }
}
