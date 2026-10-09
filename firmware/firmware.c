//
// Firmware for the PicoRV32 IO subsystem of the Tang Nano 20K PC Engine port.
//
// It mounts the microSD card with FatFs, shows a file browser on the OSD and
// streams the .PCE or .SGX image the user selects into the HuCard ROM area of the
// SDRAM.  Structure and the SD / FatFs plumbing follow nand2mario's SNESTang
// firmware (tag v0.7, GPLv3); the menu, the ROM loader and the controls are
// specific to this project.
//
// Source layout
//   firmware.c   entry point, SD mount and the in-game main loop
//   browser.c    SD card file browser
//   rom.c        HuCard (.PCE/.SGX) loading
//   cd.c         CD-ROM emulation (CUE, System Card, SCSI, CD-DA)
//   menu.c       pause menu, video/audio sub-menus, zoom/scanline shortcuts
//   settings.c   video/audio/pad settings persisted under /config
//   saves.c      backup RAM / Populous SRAM persisted under /saves
//   osd.c        OSD helpers (title, status line, message box)
//   util.c       string / number helpers
//
// Build with firmware/build.ps1 (or build.bat) and burn firmware.bin to SPI
// flash offset 0x500000 - see README.md.
//
// Controls (SNES pad)
//   Up / Down     move the selection
//   Left / Right  previous / next page
//   A             open a directory or load the highlighted .PCE/.SGX file
//   B             go back to the parent directory
//   Select        open the options menu (video, audio, debug UART)
//   Select+Start  bring the menu back over a running game
//   Select+Up/Down    cycle the display zoom (2x / stretch) over a running game
//   Select+Left/Right cycle the scanline strength (0/25/50/100%) over a running game
//

#include "common.h"
#include "osd.h"
#include "settings.h"
#include "browser.h"
#include "menu.h"
#include "cd.h"

static FATFS fs;

uint8_t io_buf[2048];

char current_game_name[NAME_MAX] = "";
int current_game_populous = 0;

// ---------------------------------------------------------------------------
// Mounting
// ---------------------------------------------------------------------------
static int mount_card(void) {
    clear();
    title();
    status("Mounting SD card...");

    for (int attempt = 0; attempt < 3; attempt++) {
        if (sd_init() == 0 && f_mount(&fs, "", 1) == FR_OK)
            return 0;
        delay(300);
    }
    return -1;
}

// ---------------------------------------------------------------------------
int main(void) {
    // 43.2 MHz / 375 = 115200 baud
    uart_init(375);

    uint32_t sp_val;
    __asm__ volatile ("mv %0, sp" : "=r"(sp_val));
    uart_printf("sp=%x io_buf=%x fs=%x\n", sp_val, (uint32_t)io_buf, (uint32_t)&fs);
    
    uart_print("\nPCEtang iosys firmware\n");

    overlay(1);
    clear();
    title();
    status("Starting...");
    delay(200);

    for (;;) {
        if (mount_card() != 0) {
            message("No SD card, or it is not",
                    "FAT16/FAT32/exFAT formatted");
            continue;
        }
        break;
    }

    // Restore the last system, video and audio settings saved on the SD card.
    system_config_load();
    video_config_load();
    audio_config_load();

    uart_print("main: entering browser\n");
    browse();
    uart_print("main: browser returned\n");

    // The console is running now.  Stay alive so the user can bring the menu
    // back with Select+Start and pick another game without a power cycle,
    // Select+Up/Down cycles the display zoom mode and Select+Left/Right
    // cycles the scanline strength.
    // Select must be held for at least 500 ms before it can be used
    // as a modifier for the zoom/scanline shortcuts.
    int select_armed = 0;
    int select_held = 0;
    uint32_t select_start = 0;

    uint32_t last_hb = time_millis();
    uint32_t last_raw = 0xffffffff;
    uint32_t cd_min_usedw = 0xffffffffu;
    uint32_t cd_empty_polls = 0;

    int cd_needs_resume = cd_active;
    if (cd_needs_resume)
        uart_print("main: CD service ready\n");

    for (;;) {
        uint32_t raw = joy_raw();
        uint32_t e = joy_edge();
        static uint32_t loops = 0;

        if (cd_audio_playing) {
            uint32_t used = reg_cd_usedw;
            if (used < cd_min_usedw)
                cd_min_usedw = used;
            if (used == 0)
                cd_empty_polls++;
        }
        cd_service();

        loops++;
        if (time_millis() - last_hb >= 1000) {
            last_hb += 1000;
            if (cd_audio_playing) {
                uart_printf("cd: m=%d e=%d u=%d b=%d r=%d f=%d l=%d\n",
                            cd_min_usedw == 0xffffffffu ? -1 : (int)cd_min_usedw,
                            (int)cd_empty_polls, (int)reg_cd_usedw,
                            (int)cd_audio_bytes_fed, (int)cd_audio_read_ms,
                            (int)cd_audio_feed_ms, (int)loops);
            } else {
                uart_printf("alive loops=%d reg=%x dcc=%d hds=%d hds_px=%d hdw=%d hdw_px=%d cd_ev=%x cd_active=%d cd_phase=%x cdda=%d cd_play=%d adpcm=%x rfsh_due=%d\n",
                            (int)loops, reg_joystick, reg_vid_dcc_dbg(),
                            reg_vid_hds_dbg(), reg_vid_hds_dbg() * 8,
                            reg_vid_hdw_dbg(), reg_vid_hdw_dbg() * 8,
                            (unsigned)reg_cd_events, cd_active, (unsigned)reg_cd_phase,
                            (unsigned)reg_cd_usedw, cd_audio_playing,
                            (unsigned)(reg_cd_adpcm & 0xff),
                            (int)reg_refresh_debt());
            }
            loops = 0;
            cd_audio_bytes_fed = 0;
            cd_audio_read_ms = 0;
            cd_audio_feed_ms = 0;
            cd_min_usedw = 0xffffffffu;
            cd_empty_polls = 0;
        }

        if (raw != last_raw) {
            if (!cd_audio_playing && !cd_active) {
                if (raw & JOY_START)
                    uart_print("joy: RUN pressed\n");
                else
                    uart_print("joy: state changed\n");
            }
            last_raw = raw;
        }

        static uint32_t last_reg = 0xffffffff;
        uint32_t r = reg_joystick;
        if (r != last_reg) {
            last_reg = r;
        }

        if (!(raw & JOY_SELECT)) {
            // Select released: require another 500 ms hold next time.
            select_armed = 0;
            select_held = 0;
        } else if (!select_held) {
            select_start = time_millis();
            select_held = 1;
        } else if (!select_armed) {
            if (time_millis() - select_start >= 500)
                select_armed = 1;
        }

        if ((raw & JOY_MENU) == JOY_MENU) {
            delay(300);                     // let the buttons be released
            overlay(1);
            if (pause_menu()) {
                if (mount_card() != 0) {
                    message("No SD card, or it is not",
                            "FAT16/FAT32/exFAT formatted");
                    overlay(0);
                    continue;
                }
                browse();
            }
        } else if (select_armed &&
                   (raw & JOY_SELECT) &&
                   (e & (JOY_UP | JOY_DOWN))) {
            zoom_cycle();
        } else if (select_armed &&
                   (raw & JOY_SELECT) &&
                   (e & (JOY_LEFT | JOY_RIGHT))) {
            scanline_cycle((e & JOY_RIGHT) ? 1 : -1);
        }
        if (!cd_audio_playing)
            delay(20);
        else if (reg_cd_usedw >= 6144)
            delay(2);

        if (cd_needs_resume) {
            cd_needs_resume = 0;
            pce_pause(0);
        }
    }

    return 0;
}
