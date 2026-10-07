//
// Minimal C runtime for the PicoRV32 IO subsystem of the Tang Nano 20K
// PC Engine port.
//
// Derived from nand2mario's SNESTang firmware/picorv32.h, tag v0.7
// (commit df5acd0104d0a6a2c8c22e8e4857baf61d456aaa), GPLv3.  The SNES
// specific entry points were dropped and the OSD geometry, the joypad helper
// and the ROM loading registers were reworked for this project.
//

#ifndef H_PICORV32
#define H_PICORV32

#include <stdint.h>
#include <stddef.h>

// ---------------------------------------------------------------------------
// Memory mapped registers, see rtl/tang/iosys/iosys.v
// ---------------------------------------------------------------------------
#define reg_textdisp       (*(volatile uint32_t*)0x02000000)
#define reg_uart_clkdiv    (*(volatile uint32_t*)0x02000010)
#define reg_uart_data      (*(volatile uint32_t*)0x02000014)
#define reg_spimaster_byte (*(volatile uint32_t*)0x02000020)
#define reg_spimaster_word (*(volatile uint32_t*)0x02000024)
#define reg_romload_ctrl   (*(volatile uint32_t*)0x02000030)
#define reg_romload_data   (*(volatile uint32_t*)0x02000034)
#define reg_romload_size   (*(volatile uint32_t*)0x02000038)
#define reg_romload_status (*(volatile uint32_t*)0x02000068)
#define reg_romload_debug  (*(volatile uint32_t*)0x0200006c)
#define reg_joystick       (*(volatile uint32_t*)0x02000040)
#define reg_video_zoom     (*(volatile uint32_t*)0x02000044)
#define reg_scanline       (*(volatile uint32_t*)0x02000048)
#define reg_game_ctrl      (*(volatile uint32_t*)0x0200004c)
#define reg_time           (*(volatile uint32_t*)0x02000050)
#define reg_pad_mode       (*(volatile uint32_t*)0x02000058)
#define reg_color_mode     (*(volatile uint32_t*)0x0200005c)
#define reg_core_id        (*(volatile uint32_t*)0x02000060)
#define reg_vdc_options    (*(volatile uint32_t*)0x020000d0)
#define CORE_PROFILE_PCE      0u
#define CORE_PROFILE_SGX      1u
#define CORE_PROFILE_CD       2u
#define CORE_PROFILE_SUPERSET 3u
#define CORE_PROFILE_ID       (reg_core_id & 0xffffu)
#define reg_audio          (*(volatile uint32_t*)0x02000064)
#define reg_cd_events      (*(volatile uint32_t*)0x02000070)
#define reg_cd_stat        (*(volatile uint32_t*)0x02000074)
#define reg_cd_cmd0        (*(volatile uint32_t*)0x02000078)
#define reg_cd_cmd1        (*(volatile uint32_t*)0x0200007c)
#define reg_cd_cmd2        (*(volatile uint32_t*)0x02000080)
#define reg_cd_data0       (*(volatile uint32_t*)0x02000084)
#define reg_cd_data1       (*(volatile uint32_t*)0x02000088)
#define reg_cd_data2       (*(volatile uint32_t*)0x0200008c)
#define reg_cd_feed        (*(volatile uint32_t*)0x02000090)
#define reg_cd_ack         (*(volatile uint32_t*)0x02000094)
#define reg_cd_phase       (*(volatile uint32_t*)0x02000098)
#define reg_cd_usedw       (*(volatile uint32_t*)0x0200009c)
#define reg_cd_adpcm       (*(volatile uint32_t*)0x020000a0)
// Largest pending SDRAM refresh debt since reset. Values >= 12 trigger
// emergency preemption of a VDC slot.
#define reg_refresh_debt() ((reg_cd_adpcm >> 8) & 0xff)
#define reg_rom_pop        (*(volatile uint32_t*)0x020000a4)
#define reg_brm_addr       (*(volatile uint32_t*)0x020000a8)
#define reg_brm_data       (*(volatile uint32_t*)0x020000ac)
#define reg_brm_access     (*(volatile uint32_t*)0x020000b0)
#define reg_cd_audio_hold  (*(volatile uint32_t*)0x020000b4)
#define reg_cd_audio_word  (*(volatile uint32_t*)0x020000b8)
#define reg_cheat_ctrl     (*(volatile uint32_t*)0x020000c0)
#define reg_cheat_addr     (*(volatile uint32_t*)0x020000c4)
#define reg_cheat_value    (*(volatile uint32_t*)0x020000c8)
#define reg_cheat_push     (*(volatile uint32_t*)0x020000cc)

// VCE dot clock select (VIDEO_DCC), debug only: piggybacked onto reg_core_id
// bits 17:16 (see iosys.v) instead of its own address decode.
#define reg_vid_dcc_dbg()  ((reg_core_id >> 16) & 0x3)

// VDC0 active display width in 8-pixel characters (HuC6270 HDW), debug only:
// piggybacked onto reg_core_id bits 24:18. Multiply by 8 for pixels.
#define reg_vid_hdw_dbg()  ((reg_core_id >> 18) & 0x7f)
#define reg_vid_hds_dbg()  ((reg_core_id >> 25) & 0x7f)

// Remaining HuC6270 timing registers, the HuC6260 control register and the
// pixel count the scandoubler really latched on the last core scan line.
// Read-only, piggybacked onto the unused upper bits of write-only registers
// (see iosys.v) rather than onto new addresses, which would lengthen the
// softcore's mem_rdata mux past timing closure.
#define reg_vid_hsw_dbg()  ((reg_color_mode >> 1)  & 0x1f)
#define reg_vid_hde_dbg()  ((reg_color_mode >> 6)  & 0x7f)
#define reg_vid_vsw_dbg()  ((reg_color_mode >> 13) & 0x1f)
#define reg_vid_vds_dbg()  ((reg_color_mode >> 18) & 0xff)
#define reg_vid_vdw_dbg()  ((reg_pad_mode >> 1)    & 0x1ff)
#define reg_vid_vcr_dbg()  ((reg_pad_mode >> 10)   & 0xff)
// Raw HuC6260 control register ($0400); bits 1:0 are the dot clock select.
#define reg_vce_cr_dbg()   ((reg_pad_mode >> 18)   & 0xff)
// Highest line buffer write address, so the written pixel count is this + 1.
#define reg_vid_px_dbg()   ((reg_rom_pop >> 1)     & 0x3ff)
// Last VCE register written by the CPU, number of writes to $0400, and the
// last value written there.  Tells whether the game programs the dot clock.
#define reg_vce_last_a()   ((reg_rom_pop >> 11)    & 0x7)
#define reg_vce_cr_wr()    ((reg_rom_pop >> 14)    & 0x1f)
#define reg_vce_cr_last()  ((reg_rom_pop >> 19)    & 0xff)


// ---------------------------------------------------------------------------
// OSD geometry, must match textdisp.v
// ---------------------------------------------------------------------------
#define OSD_COLS 32
#define OSD_ROWS 20

// ---------------------------------------------------------------------------
// SNES pad bits, as delivered by rtl/tang/snes_gamepad.v
// ---------------------------------------------------------------------------
#define JOY_B      0x001
#define JOY_Y      0x002
#define JOY_SELECT 0x004
#define JOY_START  0x008
#define JOY_UP     0x010
#define JOY_DOWN   0x020
#define JOY_LEFT   0x040
#define JOY_RIGHT  0x080
#define JOY_A      0x100
#define JOY_X      0x200
#define JOY_L      0x400
#define JOY_R      0x800

// the combination that brings the menu back over a running game
#define JOY_MENU   (JOY_SELECT | JOY_START)

#define DEBUG(...) uart_printf(__VA_ARGS__)

// ---- OSD output -----------------------------------------------------------
void cursor(int x, int y);
int  putchar(int c);
int  print(const char *s);
int  printf(const char *fmt, ...);      // %s %d %x %c %b %w
void print_hex(uint32_t v);
void print_hex_digits(uint32_t v, int n);
void print_dec(int v);
void clear(void);
void clear_line(int y);
void overlay(int on);
int  overlay_status(void);
void selection_row(int y);

// ---- debug UART -----------------------------------------------------------
extern int debug_uart;
void uart_init(int clkdiv);
int  uart_putchar(int c);
int  uart_print(const char *s);
int  uart_printf(const char *fmt, ...);
void uart_print_hex(uint32_t v);
void uart_print_hex_digits(uint32_t v, int n);
void uart_print_dec(int v);

// ---- time -----------------------------------------------------------------
void delay(int ms);

static inline uint32_t time_millis(void) {
    return reg_time;
}

// ---- joypad ---------------------------------------------------------------
uint32_t joy_raw(void);
// Debounced / auto-repeating edge reader.  Returns the bits that have just
// become active since the previous call, including auto-repeat for the d-pad.
uint32_t joy_edge(void);

// ---- SD card (spi_sd.c) ---------------------------------------------------
int     sd_init(void);
uint8_t sd_send_command(uint8_t cmd, uint32_t arg);
int     sd_readsector(uint32_t sector, uint8_t *buffer, uint32_t sector_count);
// int 	sd_writesector(uint32_t start_block, uint8_t *buffer, uint32_t sector_count);

// ---- ROM streaming to the PC Engine --------------------------------------
static inline void pce_load_start(uint32_t size_bytes, int sgx) {
    reg_romload_ctrl = 1 | (sgx ? 2 : 0);
    reg_romload_size = size_bytes;
}
static inline void pce_load_word(uint32_t w) {
    reg_romload_data = w;
}
static inline int pce_load_end(void) {
    reg_romload_ctrl = 0;
    uint32_t started = time_millis();
    while (reg_romload_status & 1u) {
        if ((uint32_t)(time_millis() - started) >= 2000u) {
            uart_printf("load drain timeout status=%x debug=%x\n",
                        reg_romload_status, reg_romload_debug);
            return -1;
        }
    }
    return 0;
}

static inline void pce_pause(int pause) {
    reg_game_ctrl = pause ? 1 : 0;
}

static inline void pce_reset(void) {
    reg_game_ctrl = 2;
}

static inline void pce_stop(void) {
    reg_game_ctrl = 8;
}
static inline void pce_cd_start(void) {
    reg_game_ctrl = 17;
}

// ---- tiny libc ------------------------------------------------------------
void  *memcpy(void *dst, const void *src, size_t len);
void  *memset(void *s, int c, size_t n);
int    memcmp(const void *s1, const void *s2, size_t n);
size_t strlen(const char *s);
int    strcmp(const char *s1, const char *s2);
int    strcasecmp(const char *s1, const char *s2);
char  *strcpy(char *dst, const char *src);
char  *strncpy(char *dst, const char *src, size_t n);
char  *strcat(char *dst, const char *src);
char  *strncat(char *dst, const char *src, size_t n);
char  *strchr(const char *s, int c);
char  *strrchr(const char *s, int c);
char  *strstr(const char *haystack, const char *needle);
char  *strcasestr(const char *haystack, const char *needle);

static inline int tolower(int c) {
    return (c >= 'A' && c <= 'Z') ? c + ('a' - 'A') : c;
}

static inline int imax(int x, int y) { return x > y ? x : y; }
static inline int imin(int x, int y) { return x < y ? x : y; }

#endif
