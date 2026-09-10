# PC Engine / TurboGrafx-16 for the Sipeed Tang Nano 20K

A HuCard-only port of the [mist-devel/TurboGrafx16_FPGA](https://github.com/mist-devel/TurboGrafx16_FPGA)
PC Engine core to the **Sipeed Tang Nano 20K** (Gowin `GW2AR-LV18QN88C8/I7`).

ROM images are pushed into the on-package SDRAM over the board's USB serial
port, video goes out of the HDMI connector and sound out of the on-board
headphone amplifier.

```
        USB-C ──► BL616 ──► UART ──► ROM loader ──► SDRAM (HuCard ROM)
                                                       │
   SNES pad ──► pad reader ──► JOY ──►  pce_top (HuC6280/6270/6260)
                                          │             │
                                          │             └──► PSG ─► I2S ─► headphone jack
                                          └──► line doubler ─► DVI/TMDS ─► HDMI
```

---

## 1. What works, what does not

| Feature | Status |
| --- | --- |
| HuCard games up to 4 MiB (incl. the SF2 mapper) | yes |
| HuC6280 CPU, HuC6270 VDC, HuC6260 VCE, PSG | yes |
| 8 KiB work RAM, 64 KiB VRAM, palette RAM | yes; VRAM in SDRAM, the rest in block RAM |
| Video output | 640x480-class DVI over HDMI, genlocked line doubler |
| Audio | stereo PSG, I2S to the on-board amplifier / headphone jack |
| Controller | one SNES-style pad on the GPIO header; S1 resets the console |
| ROM loading | UART, see section 4 |
| CD-ROM², Super CD, Arcade Card | **not built** (`CD_SUPPORT = 0`, `AC_SUPPORT = 0`) |
| SuperGrafx (second VDC / VPC) | yes (`SGX_SUPPORT = 1`) |
| Game Genie / cheat engine | **not built** (`CHEAT_SUPPORT = 0`) |
| Backup RAM (BRAM), Populous SRAM | not implemented, saves are lost on power-off |
| Multitap, 6-button pads, mouse, MB128 | not implemented |
| OSD / menu | none, this is a standalone build |

The console runs at **43.2 MHz** instead of the nominal 42.954 MHz, i.e. **0.57 %
fast**. 42.954 MHz cannot be synthesised from the board's 27 MHz crystal: the
exact ratio is 35/22 and an input divider of 22 would put the PLL phase
detector at 1.2 MHz, far below its 3 MHz minimum. The audible/visible effect of
0.57 % is nil.

---

## 2. Building

Requires the **Gowin EDA IDE** (Education or Standard edition, V1.9.9 or newer)
with GowinSynthesis.

1. `File → Open Project…` and select `PCE_GT_TangNano.gprj`.
2. Check that the device is `GW2AR-18C` / `GW2AR-LV18QN88C8/I7`.
3. `Process → Synthesize`, then `Process → Place & Route`.
4. Program with the Gowin Programmer or `openFPGALoader`:

   ```
   openFPGALoader -b tangnano20k impl/pnr/PCE_GT_TangNano.fs          # volatile
   openFPGALoader -b tangnano20k -f impl/pnr/PCE_GT_TangNano.fs       # to flash
   ```

Project settings that matter (already stored in
`impl/PCE_GT_TangNano_process_config.json`):

* Top module: `top_tang_nano20k`
* VHDL standard: **VHDL-93**
* Verilog standard: Verilog-2001

The **SDRAM pins are not in the `.cst` on purpose**: on the GW2AR the 64 Mbit
SDRAM sits inside the package and the tools place the reserved
`O_sdram_*` / `IO_sdram_dq` ports automatically. Do not add IO_LOC constraints
for them.

### Regenerating the memory initialisation tables

`rtl/mem_init_pkg.vhd` is generated from the two Altera `.mif` files, because
GowinSynthesis has no equivalent of `altsyncram`'s `init_file`:

```
python tools/mif2vhd.py
```

---

## 3. Connections

| Signal | Pin | Note |
| --- | --- | --- |
| 27 MHz clock | 4 | |
| `s1` (button) | 88 | **reset** the console |
| `uart_rx` | 70 | from the on-board BL616 USB-serial bridge |
| `uart_tx` | 69 | idle, nothing is sent back |
| `led[1:0]` | 16,15 | status, active low |
| HDMI TMDS clk ± | 33 / 34 | |
| HDMI TMDS d0/d1/d2 ± | 35/36, 37/38, 39/40 | |
| `pa_en`, `hp_din`, `hp_ws`, `hp_bck` | 51, 54, 55, 56 | on-board I2S amplifier |
| `pad_clk` | 27 | SNES pad CLOCK |
| `pad_latch` | 28 | SNES pad LATCH |
| `pad_data` | 25 | SNES pad DATA (pulled up on chip) |

### LEDs

| LED | Meaning |
| --- | --- |
| 0 | PLLs locked and SDRAM initialised |
| 1 | a ROM is loaded and the console is running |

### Game pad

A **SNES controller** is wired to three GPIO pins (3.3 V only — do not feed the
pad 5 V and then drive DATA back into the FPGA):

```
   pad VCC   ->  3V3
   pad GND   ->  GND
   pad CLOCK ->  pin 27
   pad LATCH ->  pin 28
   pad DATA  ->  pin 25
```

Mapping:

| SNES | PC Engine |
| --- | --- |
| D-pad | D-pad |
| A or X | button I |
| B or Y | button II |
| Select | SELECT |
| Start | RUN |

Board button **S1** resets the console (the loaded ROM stays in SDRAM).

If no pad is connected, DATA idles high and no button is reported; the console
can still be reset with S1.

---

## 4. Loading a ROM

The core has no file system; a HuCard image is streamed into SDRAM over the
board's USB serial port.

```
pip install pyserial
python tools/pce_send.py COM7 game.pce
```

(`/dev/ttyUSB0`, `/dev/ttyACM0`, … on Linux/macOS.)

The console is held in reset while the transfer runs and starts automatically
when it finishes. Sending another image at any time replaces the current one.

### Wire protocol

| offset | size | content |
| --- | --- | --- |
| 0 | 4 | magic `0x50 0x43 0x45 0x01` — `"PCE"` + protocol version 1 |
| 4 | 4 | image size in bytes, **little endian**, 1 … 4 MiB |
| 8 | N | the raw `.pce` / `.bin` image, byte for byte |

* 8 data bits, no parity, 1 stop bit, no flow control.
* Default baud rate: **115200** (`43 200 000 / 115200 = 375`, exact).
* The loader resynchronises on the magic at any time, so a failed transfer can
  simply be repeated. If more than a second passes between two payload bytes
  the transfer is aborted.
* Faster rates with an exact divider are **432000** (divider 100) and **864000**
  (divider 50). Change `BAUD_RATE` in `rtl/top_tang_nano20k.v`, rebuild, and
  pass `--baud` to `tools/pce_send.py`.  Avoid 921600: the divider would be
  46.875 and the sampling error too large.

### ROM / header requirements

* Send the file **unmodified**. The classic 512 byte `.pce` header does not
  have to be stripped: after the transfer the loader checks
  `size & 0x3FF == 0x200` and, if so, makes the core read the image from byte
  512 onwards. This is exactly what the MiST/MiSTer version of this core does.
* `ROM_SZ` is derived as `size >> 16`, which is what `pce_top` uses to pick the
  HuCard address-mangling scheme (128K, 256K, 384K, 512K, 768K, SF2 2560K,
  otherwise linear).
* Interleaved/"swapped" dumps are not supported.
* SuperGrafx (`.sgx`) images will load but will run as plain HuCard software
  because the second VDC is not built.

---

## 5. Video output

The HuC6260 produces 2730 system clocks per scan line and 262 or 263 lines per
frame. The system clock (43.2 MHz) and the HDMI pixel clock (25.92 MHz) are in
an exact **5:3** ratio, so

```
one PCE line = 2730 * 3/5 = 1638 pixel clocks = exactly 2 HDMI lines of 819
```

`rtl/tang/video_scandoubler.v` uses that: the horizontal counter is realigned on
every incoming HSYNC and the vertical counter on every VSYNC, so the output is
genlocked to the core — no frame buffer, no tearing, no dropped frames, just two
line buffers.

Output timing is `819 x 524/526 @ 25.92 MHz` = **31.65 kHz / 60.2 Hz** with 640
active pixels and 480 active lines, i.e. within ~0.6 % of VGA 640x480@60. The
PCE's 270 / 360 / 540 dots per line (depending on the VCE dot clock) are scaled
to the full 640 pixels with a nearest-neighbour DDA whose step is exact
(108 / 144 / 216 in 1/256 units), so the picture always fills the screen with
the correct 4:3 aspect ratio.

Signalling is **DVI** (no HDMI data islands), which every HDMI sink accepts.
There is therefore **no HDMI audio**; sound comes out of the headphone jack.

### Clocks

| Clock | Frequency | Source |
| --- | --- | --- |
| `sys_clk` | 27 MHz | board crystal |
| `clk_mem` | 86.4 MHz | rPLL #1 `CLKOUT`, 27 × 16/5 |
| `clk_sys` | 43.2 MHz | rPLL #1 `CLKOUTD` /2 |
| `clk_sdram` | 86.4 MHz, 180° | rPLL #1 `CLKOUTP` |
| `clk_pix5` | 129.6 MHz | rPLL #2 `CLKOUT`, 27 × 24/5 |
| `clk_pix` | 25.92 MHz | `CLKDIV` /5 of `clk_pix5` |

---

## 6. Memory map

The HuCard ROM, PicoRV32 RAM and both VDC VRAMs share the external SDRAM
through three fixed interleaved channels. VDC1 shares the bank-2 channel with
PicoRV32 and takes priority while SuperGrafx video fetches are active.

| What | Where | Size |
| --- | --- | --- |
| HuCard ROM | SDRAM, byte address 0 (+512 if the image has a header) | ≤ 4 MiB |
| Work RAM | block RAM inside `pce_top` (`USE_INTERNAL_RAM = 1`) | 8 KiB |
| PicoRV32 RAM | SDRAM bank 2, byte address `0x400000` | 1984 KiB |
| VDC0 VRAM | SDRAM bank 3, byte address `0x7F0000` | 32K × 16 |
| VDC1 VRAM | SDRAM bank 2, byte address `0x5F0000` | 32K × 16 |
| Palette RAM, sprite/attribute buffers, PSG table | block RAM inside the core | small |
| Line buffers for the scan doubler | block RAM | 2 × 1024 × 9 |

`rtl/tang/pce_sdram_ctrl_3ch.v` runs the SDRAM at 86.4 MHz and assigns fixed
slots to (1) HuCard ROM/loader, (2) PicoRV32 or VDC1 and (3) VDC0. Its
eight-cycle schedule returns both VRAM data words within one fastest PCE pixel
period. Refresh commands are issued in alternating slots during vertical
blanking and while the console is held in reset.

---

## 7. Source layout

```
rtl/
  top_tang_nano20k.v          board top level
  pce_top_extram.vhd          console (upstream, + CD_SUPPORT/AC_SUPPORT generics)
  huc6202/6260/6270.vhd       VPC / VCE / VDC (upstream)
  HUC6280/                    CPU + PSG (upstream)
  dpram.vhd                   portable block RAM (replaces the altsyncram version)
  mem_init_pkg.vhd            generated memory initialisation tables
  cd/                         CD-ROM² unit - kept for reference, NOT in the project
  shared/                     MiST wrapper - kept for reference, NOT in the project
  tang/
    pce_core.vhd              HuCard-only wrapper + external VRAM interface
    pll_clocks.v              rPLL / CLKDIV instances
    sdram.v                   SDRAM controller (nand2mario, GPLv3)
    pce_sdram_ctrl_3ch.v      interleaved ROM / PicoRV32 / VRAM controller
    uart_rx.v, rom_loader.v   UART ROM loader
    video_scandoubler.v       genlocked line doubler + HDMI timing
    tmds_encoder.v, dvi_tx.v  DVI encoder, OSER10 serialisers, ELVDS buffers
    i2s_tx.v                  I2S transmitter
    snes_gamepad.v, pce_pad.v pad reader and PC Engine pad multiplexer
constraints/
  tang_nano20k.cst            pin assignments
  tang_nano20k.sdc            clock constraints
tools/
  pce_send.py                 host side ROM sender
  mif2vhd.py                  .mif -> VHDL constant tables
```

`rtl/cd/`, `rtl/shared/`, `rtl/arcade.sv`, `rtl/cheatcodes.sv`, `rtl/mb128.sv`,
`rtl/color_mix.sv`, `rtl/CEGen.vhd` and `rtl/pce_top.vhd` are **not referenced**
by `PCE_GT_TangNano.gprj`. They are left in the tree so that the port stays
close to upstream and so that the CD build can be revived later.

---

## 8. Changes made to the upstream core

Kept deliberately small:

* `rtl/dpram.vhd` — rewritten with inferred, vendor independent VHDL. The entity
  names, generics, ports and defaults are unchanged, and the behaviour of the
  original `altsyncram` configuration is reproduced (synchronous unregistered
  read, `NEW_DATA` read-during-write on the same port, `cs_x` masking).
  `mem_init_file` now selects one of the tables in `work.mem_init_pkg`.
* `rtl/pce_top_extram.vhd` — added the `CD_SUPPORT` and `AC_SUPPORT` generics
  (both default to `1`, so existing top levels are unaffected). With them at `0`
  the CD-ROM unit and the Arcade Card are not instantiated and all their
  interface signals are tied to their inactive state. The CD unit is now a
  component instantiation instead of a direct entity instantiation, so
  `rtl/cd/*` does not have to be part of the project. `VOLTAB_FILE` was
  corrected from the non-existent `../voltab/voltab_small.mif` to
  `voltab_small.mif`. The unused `VRAM1_*` outputs are driven when
  `SGX_SUPPORT = 0`
  branch.
* `rtl/huc6270.vhd` — one-character fix in the `SPR_CACHE` reset aggregate,
  where the 4-bit `PAL` record element was initialised with a 2-bit literal.
* `rtl/huc6260.vhd` — power-up values for the free running video counters
  (`H_CNT`, `V_CNT`, `CLKEN_CNT`, `CLKEN_FS_CNT`) so that they match the FPGA
  power-up state and can be simulated.
* `rtl/HUC6280/voltab_small.mif` — added from upstream (`voltab/voltab_small.mif`);
  the file the core referenced was missing from this tree.

---

## 9. Credits and licences

* PC Engine core: **mist-devel/TurboGrafx16_FPGA** (Gregory Estrade, Alexey
  Melnikov / Sorgelig, Alastair M. Robinson and contributors) — GPL. All
  original headers are preserved.
* `rtl/tang/sdram.v`: **nand2mario**, taken from
  [sipeed/TangNano-20K-example](https://github.com/sipeed/TangNano-20K-example)
  (`nestang/src/sdram.v`), GPLv3.
* rPLL / CLKDIV / `OSER10` / `ELVDS_OBUF` usage follows the Sipeed Tang Nano 20K
  examples and NESTang (GPLv3).
* The TMDS encoder implements the encoding algorithm published in the DVI 1.0
  specification.
* Everything else under `rtl/tang/`, `constraints/` and `tools/` was written for
  this port and is released under the same terms as the core it is part of.
