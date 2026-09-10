//
// Test program for sim/tb_iosys.v.  It is compiled with the same RISC-V
// toolchain as the real firmware, loaded into the SPI flash model and
// executed by the PicoRV32 out of the simulated SDRAM.
//
// Progress is reported through the OSD character register, which the
// testbench snoops.
//
#include <stdint.h>

#define reg_textdisp     (*(volatile uint32_t*)0x02000000)
#define reg_romload_ctrl (*(volatile uint32_t*)0x02000030)
#define reg_romload_data (*(volatile uint32_t*)0x02000034)
#define reg_romload_size (*(volatile uint32_t*)0x02000038)
#define reg_joystick     (*(volatile uint32_t*)0x02000040)
#define reg_time         (*(volatile uint32_t*)0x02000050)
#define reg_core_id      (*(volatile uint32_t*)0x02000060)

static volatile uint32_t scratch[4];

static void mark(int code) {
    reg_textdisp = (uint32_t)code & 0xff;
}

int main(void) {
    int i;

    // 1. word and byte accesses to the SDRAM backed RAM window
    scratch[0] = 0x12345678u;
    scratch[1] = 0xdeadbeefu;
    {
        volatile uint8_t *b = (volatile uint8_t *)&scratch[2];
        b[0] = 0x11; b[1] = 0x22; b[2] = 0x33; b[3] = 0x44;
    }
    mark((scratch[0] == 0x12345678u && scratch[1] == 0xdeadbeefu &&
          scratch[2] == 0x44332211u) ? 'A' : 'E');

    // 2. core id register
    mark(reg_core_id == 3 ? 'B' : 'E');

    // 3. joypad register
    mark((reg_joystick & 0xfff) == 0x0a5 ? 'C' : 'E');

    // 4. millisecond counter runs
    {
        uint32_t t0 = reg_time;
        for (i = 0; i < 20000; i++)
            scratch[3] = (uint32_t)i;
        mark(reg_time != t0 ? 'T' : 'E');
    }

    // 5. first ROM load: 256 bytes of 0x00..0xFF, announced as a headered
    //    0x10200 byte image (rom_sz 1, rom_offset 512)
    reg_romload_ctrl = 1;
    reg_romload_size = 0x10200;
    for (i = 0; i < 64; i++)
        reg_romload_data = 0x03020100u + (uint32_t)i * 0x04040404u;
    reg_romload_ctrl = 0;
    mark('D');

    // 6. second load: the write pointer must restart at 0 and the new size
    //    must give rom_sz 4 / rom_offset 0
    reg_romload_ctrl = 1;
    reg_romload_size = 0x040000;
    for (i = 0; i < 8; i++)
        reg_romload_data = 0xA0A0A0A0u + (uint32_t)i;
    reg_romload_ctrl = 0;
    mark('F');

    for (;;) { }
    return 0;
}
