# rtl/gbc — Game Boy / Game Boy Color core

## Origin
The RTL here comes from **GBCandy Nano** (https://github.com/kuangyl0212/gbcandy_open,
commit `a1e255d`, GPL-3.0, © Yulin Kuang), which is itself based on **VerilogBoy**
(© Wenting Zhang, GPL-3.0 or later). The original copyright headers are kept. See `LICENSE`.

Each module was renamed with a `gbc_` prefix, so it can live next to `rtl/gb/` (VerilogBoy):
- `gbc_cpu`, `gbc_control`, `gbc_alu`, `gbc_regfile`, `gbc_singlereg`, `gbc_common.vh`: the SM83 CPU.
- `gbc_ppu`: the CGB-capable PPU.
- `gbc_timer`: the timer.
- `gbc_apu*`: the APU.

## What was removed
The following parts of GBCandy's monolithic `gbc_top.v` were dropped:
- DS2 pad
- PicoRV32/IOSys
- SDRAM controller
- SDRAM framebuffer, prefetch and line buffers
- HDMI and the audio FIFO
- UART trace/status
- All `dbg_*` counters
- LEDs
- The OAM-corruption bug emulation

## What was changed
- **`gbc_core.v`** is a new top. Its glue logic was rewritten from `gbc_top.v` and covers:
  - CE generation
  - KEY1/double speed
  - SVBK/VBK
  - HDMA/GDMA
  - OAM DMA
  - CGRAM (FF68–FF6B)
  - IO registers, IE/IF, joypad and timer
  - A fake serial port
  - A homebrew 256-byte boot ROM with no Nintendo code
  - A memory interface unit (MIU) for the external memory
- **`gbc_cart_mapper.sv`** is a copy of `rtl/gb/gb_cart_mapper.sv` (ROM-only, MBC1, MBC3 without RTC, MBC5). It adds:
  - ROM bank masking using the header ROM size.
  - MBC5 RAM enable over the whole 0000-1FFF range.
  - An `ff` flag (open bus) for unsupported mappers and for disabled or absent cart RAM.
  - RAM presence taken from header byte 0x149 for MBC1/3/5.
- Patches to the copied files:
  - `gbc_control.v`: the STOP speed-switch latch was cleared one enable after being set, so KEY1 never switched speed. Fixed.
  - `gbc_ppu.v`: the `mmio_wr` strobe is no longer gated by CE, and `oam_dout` is a wire.
  - `gbc_timer.v`: register writes no longer depend on CE.
  - `gbc_apu.v`: outputs unsigned `{1'b0, mix[8:0], 6'b0}`, the same format as the VerilogBoy `sound.v` used today. `audio_ready` is tied to 1.

## Interface (`gbc_core`, parameter `MEM_LAT = 5`)
`clk` is 21.6 MHz and is the only clock; everything else uses clock enables. `reset` is synchronous and active high. The other ports:
- Inputs: `pause`, `cgb_enable` (latched while reset is high), `cart_type`, `rom_size`, `ram_size`, and `buttons` (1 = pressed: `{start, select, b, a, down, up, left, right}`).
- External memory: `mem_addr[21:0]`, `mem_rd`, `mem_wr`, `mem_wdata`, `mem_rdata`.
- Video: `pix_valid` (one pulse per pixel, 160×144 in raster order), `pix_index`, `hsync`, `vsync`, `cgb_mode`.
  - In CGB mode, `pix_index` is `{is_obj, pal[2:0], color[1:0]}`.
  - In DMG mode, `pix_index` is `{4'b0, shade}`, where shade is taken after BGP/OBP mapping.
- Palette: `pal_wr`, `pal_wr_addr[6:0]` = `{obj, byte_idx}`, `pal_wr_data`. One pulse per CGRAM byte write, including the 128 writes made by the boot ROM.
- Audio: `audio_l` and `audio_r` are 16-bit **unsigned** values.

### External memory map (byte addresses)
| Range | Content |
|---|---|
| 0x000000–0x3D7FFF | Cartridge ROM (file loaded linearly) |
| 0x3D8000–0x3DFFFF | WRAM: 8 × 4 KiB banks; DMG uses banks 0–1 |
| 0x3E0000–0x3FFFFF | Cartridge RAM (128 KiB max) |

The external port carries all CPU, OAM-DMA and HDMA accesses to 0000-7FFF, A000-BFFF and C000-FDFF (including echo). VRAM, OAM, HRAM, IO and CGRAM stay inside the core.

### Protocol and stall scheme
The external port is SDRAM port B of `sdram_nes.v`.
- **Single outstanding access.** The MIU handles one access at a time with priority **HDMA > OAM DMA > posted CPU write > CPU read**.
- **Request timing.** For each access the MIU registers `mem_addr`/`mem_wdata` and raises `mem_rd` or `mem_wr` for 2 clk. It captures read data `MEM_LAT + 1` clk after the rising edge, so an access cycle is 6 clk. The request is then low for at least 4 clk before the next one.
- **CPU writes** are posted to a 1-entry slot and do not stall unless the slot is still full at the next write.
- **CPU reads** issue at the start of the M-cycle. If the data is not back when the CPU samples it, the CPU clock enable is held (stall).
- **Paying back lost enables.** Enables lost to a stall are counted in a 2-bit "owe" counter and given back on the following clk. This keeps the average CPU speed exact: the testbench measures 0.3884 enables/clk in double speed and 0.1942 in normal speed.
- **OAM DMA** fetches 1 byte per M-cycle through the MIU. When the source is VRAM, it reads VRAM directly.
- **HDMA/GDMA** moves 2 bytes per M-cycle in double speed. It holds the CPU at an M-cycle boundary while it runs.

## Resources
These figures come from Gowin synthesis of `gbc_core` alone (GW2AR-18C, V1.9.11.03):

| Resource | Count |
|---|---|
| LUT | 3614 |
| ALU | 242 |
| Registers | 1589 |
| BSRAM | 11 (VRAM 2×8 KB = 8, OAM 2, HRAM 1) |
| SSRAM | 41 (CGRAM 2×64 B, PPU sprite lists, CPU regfile) |
| MULT9X9 | 2 (APU) |

## Verification
`sim/tb_gbc_core.sv` runs CGB and DMG cases against a protocol-checking SDRAM model with random and worst-case latency.

Build with `iverilog -g2012 -Irtl/gbc`. Defining `-DGBC_BREAK_LATENCY` samples read data one clk early; the testbench must then fail.

## Known limitations
- MBC3 RTC, MBC2, MMM01, HuC and other mappers are not supported.
- No OAM-corruption bug emulation.
- The serial port is fake: the internal clock completes after 4096 cycles with SB = FF and no link.
- DMA/HDMA timing and the CPU halt pattern are approximate, and the CPU is not blocked from the bus during OAM DMA.
- The STOP speed-switch delay is not emulated.
- In CGB mode, CPU VRAM reads during mode 3 are not blocked; they return data.
- Only the homebrew boot ROM is included, with no logo check. CGB games running on the CGB core in DMG-compatibility mode are not supported: `cgb_enable = 0` gives a plain DMG.
