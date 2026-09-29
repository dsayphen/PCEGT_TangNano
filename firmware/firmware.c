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

// End of .text, see firmware/baremetal.ld.
extern char _end[];

// Mirror of the executable image, taken once at boot, far above .bss/heap and
// well below the stack top (0x1A0000). Comparing against it every loop says
// whether the SDRAM still holds the code the softcore is running.
static uint32_t *const text_mirror = (uint32_t *)0x00100000;
static uint32_t text_words;

#define VID_LOG 16
static uint32_t vid_log[VID_LOG];
static int vid_n, vid_shown;

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

    browse();

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

    // Diagnostic: the softcore fetches every instruction from the SDRAM, so a
    // corrupted word is a garbage instruction. Mirror the code now, while it
    // still runs, and compare every loop.
    text_words = ((uint32_t)_end + 3) / 4;
    for (uint32_t i = 0; i < text_words; i++)
        text_mirror[i] = ((const uint32_t *)0)[i];
    uart_printf("text mirror: %d words\n", (int)text_words);
    uint32_t last_vid = 0xffffffff;

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
        // 100 ms, not 1 s: the softcore dies within the first second on the
        // games under investigation, so the readings have to be close enough
        // together to show the state just before it stops.
        if (time_millis() - last_hb >= 100) {
            last_hb += 100;
            if (cd_audio_playing) {
                uart_printf("cd: m=%d e=%d u=%d b=%d r=%d f=%d l=%d\n",
                            cd_min_usedw == 0xffffffffu ? -1 : (int)cd_min_usedw,
                            (int)cd_empty_polls, (int)reg_cd_usedw,
                            (int)cd_audio_bytes_fed, (int)cd_audio_read_ms,
                            (int)cd_audio_feed_ms, (int)loops);
            } else {
                uart_printf("alive loops=%d starve=%d rfsh_due=%d dcc=%d hds=%d hdw=%d hde=%d\n",
                            (int)loops, (int)reg_rv_starve(),
                            (int)reg_refresh_debt(), reg_vid_dcc_dbg(),
                            reg_vid_hds_dbg(), reg_vid_hdw_dbg(),
                            (int)reg_vid_hde_dbg());
            }
            loops = 0;
            cd_audio_bytes_fed = 0;
            cd_audio_read_ms = 0;
            cd_audio_feed_ms = 0;
            cd_min_usedw = 0xffffffffu;
            cd_empty_polls = 0;

            while (vid_shown < vid_n) {
                uint32_t v = vid_log[vid_shown++];
                uart_printf("vid dcc=%d hsw=%d hds=%d hdw=%d hde=%d px=%d\n",
                            (int)((v >> 26) & 3), (int)((v >> 21) & 0x1f),
                            (int)((v >> 14) & 0x7f), (int)((v >> 7) & 0x7f),
                            (int)(v & 0x7f), (int)(((v >> 7) & 0x7f) + 1) * 8);
            }
        }

        if (raw != last_raw) {
            if (!cd_audio_playing)
                uart_printf("joy %x dcc=%d hds=%d hds_px=%d hdw=%d hdw_px=%d\n",
                            raw, reg_vid_dcc_dbg(), reg_vid_hds_dbg(),
                            reg_vid_hds_dbg() * 8, reg_vid_hdw_dbg(),
                            reg_vid_hdw_dbg() * 8);
            last_raw = raw;
        }

        static uint32_t last_reg = 0xffffffff;
        uint32_t r = reg_joystick;
        if (r != last_reg) {
            if (!cd_audio_playing)
                uart_printf("reg %x\n", r);
            last_reg = r;
        }

        // Video modes are only recorded here and printed by the heartbeat
        // below: nothing must reach the UART at the instant the game
        // reprograms the VDC, so that a failure then cannot be blamed on the
        // printing itself.
        uint32_t vid = (reg_vid_dcc_dbg() << 26) | (reg_vid_hsw_dbg() << 21) |
                       (reg_vid_hds_dbg() << 14) | (reg_vid_hdw_dbg() << 7) |
                       reg_vid_hde_dbg();
        if (vid != last_vid) {
            if (vid_n < VID_LOG)
                vid_log[vid_n++] = vid;
            last_vid = vid;
        }

        for (uint32_t i = 0; i < text_words; i++) {
            uint32_t got = ((const volatile uint32_t *)0)[i];
            if (got != text_mirror[i]) {
                // A second read agreeing with the mirror means the memory is
                // fine and the first read was lost in the data path.
                uint32_t again = ((const volatile uint32_t *)0)[i];
                uart_printf("TEXT %x: got %x want %x reread %x\n",
                            (unsigned)(i * 4), (unsigned)got,
                            (unsigned)text_mirror[i], (unsigned)again);
            }
        }

        if (uart_div_clobbered) {
            uint32_t bad = uart_div_clobbered;
            uart_div_clobbered = 0;
            uart_printf("UARTDIV was %x\n", (unsigned)bad);
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
        else if (reg_cd_usedw >= 3072)
            delay(2);
    }

    return 0;
}
