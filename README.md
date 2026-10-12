# PC Engine / TurboGrafx-16 for the Sipeed Tang Nano 20K

A PC Engine / SuperGrafx port of the
[mist-devel/TurboGrafx16_FPGA](https://github.com/mist-devel/TurboGrafx16_FPGA)
core to the **Sipeed Tang Nano 20K** (Gowin `GW2AR-LV18QN88C8/I7`). CD-ROM
support is experimental.

The PicoRV32 firmware boots from SPI flash, browses a FAT-formatted microSD
card on the OSD and loads HuCard or System Card images into SDRAM. The USB-UART
loader is also available as a fallback. Video uses the HDMI connector (DVI
signalling); audio uses the board's I2S amplifier/headphone output, not HDMI.

```
microSD -> PicoRV32 + OSD -> SDRAM (HuCard / System Card, CD/ADPCM RAM)
USB-UART -----------------> SDRAM (fallback HuCard loader)
SNES pad -> HuC6280 / VDC / VCE -> line doubler -> DVI over HDMI
           PSG + CDDA + ADPCM -> I2S -> board audio output
```

---

## 1. What works, what does not

| Feature | Status |
| --- | --- |
| HuCard games up to 4 MiB (incl. the SF2 mapper) | yes |
| HuC6280 CPU, HuC6270 VDC, HuC6260 VCE, PSG | yes |
| 8 KiB work RAM, dual 64 KiB VRAMs, palette RAM | yes; VRAMs in SDRAM, work/palette RAM in block RAM |
| Video output | 640x480-class HDMI/DVI, genlocked line doubler |
| Audio | PSG/CDDA/ADPCM mixed; onboard I2S speaker or HDMI stereo LPCM (HDMI hardware test pending) |
| Controller | one SNES-style pad, 2/6-button modes; S1 resets the console |
| ROM loading | microSD browser; USB-UART fallback, see section 4 |
| CD-ROM² / Super CD | experimental CUE/BIN, System Card, CDDA, SCSI data and ADPCM |
| Arcade Card | enabled in CD mode; 2 MiB SDRAM tested in simulation, game compatibility not yet tested on hardware |
| SuperGrafx (second VDC / VPC) | yes (`SGX_SUPPORT = 1`) |
| Game Genie / cheat engine | user `.cht` files; up to 4 active address patches on every profile |
| Backup RAM (BRAM), Populous SRAM | saved per game on microSD at firmware-menu entry (not on power loss) |
| Multitap, mouse, MB128 | not implemented |
| OSD / menu | microSD browser, in-game pause, audio and video settings |

The console runs at **43.2 MHz** instead of the nominal 42.954 MHz, i.e. **0.57 %
fast**. 42.954 MHz cannot be synthesised from the board's 27 MHz crystal: the
exact ratio is 35/22 and an input divider of 22 would put the PLL phase
detector at 1.2 MHz, far below its 3 MHz minimum. The audible/visible effect of
0.57 % is nil.

---

## 2. Building

The tested FPGA tool is **Gowin V1.9.11.03 Education**, targeting
`GW2AR-LV18QN88C8/I7`. The PicoRV32 firmware additionally needs an RV32I
bare-metal GCC toolchain; `firmware/build.ps1` finds xPack RISC-V GCC under
`%USERPROFILE%\opt` or via `RISCV_PREFIX`.

From the repository root, build **both** components:

```powershell
& .\firmware\build.ps1
& "G:\Gowin\Gowin_V1.9.11.03_Education_x64\IDE\bin\gw_sh.exe" tools/build.tcl
```

To build the three profile variants from the same RTL sources, run:

```powershell
& .\tools\build_profiles.ps1 -Profile all
```

The script creates temporary Gowin project/config copies and stores each
profile's bitstream, binary and reports under `impl/profiles/{sgx,cd,superset}/`.
The `all` build selects `sgx` (HuCard, including ordinary PCE games), `cd`
(CD-Rom), and `superset`; PCE is not offered by the core selection menu.
Each current `.bin` is about 887 KiB and fits a 1 MiB flash slot. Core selection
copies a stored slot to address zero and requires a power cycle; it does not
use MSPI_JUMP, Multi-Boot address switching, or partial reconfiguration.

The SGX profiles currently test VDC1 VRAM in SDRAM bank 1
(`0x3F0000..0x3FFFFF`), separate from the RV's bank 2. VDC0 remains in bank 3;
other profiles keep VDC1 in bank 2. Do not load ROMs extending into the
reserved bank-1 window in this SGX test build. The RV/VDC1 scheduler channel
and VDC1 priority are unchanged. Use `-Profile sgx_rv_diag` for UART diagnostics.

At 115200 baud, the SGX diagnostic emits paired `RVT n` and `RVL n` records
for the last four completed CPU transfers around a stall. Each `RVL` payload
contains four 32-bit hexadecimal fields: physical address of the last SDRAM
RV read, data captured at that read, RV bridge output, and CPU transfer data
(the same field as in `RVT`).
Use the matching `RVT` address and flags to identify RAM reads before comparing
the three data fields. For MMIO accesses and writes, the SDRAM capture refers
to an earlier read. The `RVP` probe rereads the physical address captured for
the first suspect RAM read four times after an invalid CPU access stalls.

The current bus diagnostic freezes the first instruction read with low bits
other than `11` (RV32I, no compressed ISA). The legacy checks expecting
`0x000187B7` at code addresses `0x24C4` and `0x7194` are disabled by default
because rebuilding the firmware changes those instructions. They can only be
restored with `CHECK_LEGACY_OPCODES=1` after verifying those exact addresses
and opcodes.
For data reads, the patterns `0x03C003C0`, `0x33CCCC33`, `0xCC3333CC` trigger
only in the observed stack page `0x19F000..0x19FFFF`, not ordinary ROM buffers.
Stack-pattern triggers remain heuristic and do not cover every possible
corruption. Ordinary zero data and MMIO reads do not trigger it. The known
opcodes must be rechecked if the firmware is rebuilt.
`RVS` now contains CPU address, SDRAM captured data, bridge data and CPU data,
not stack counters. `RVB` contains metadata followed by DQ sampled two
`clk_mem` edges before capture, one edge before capture, and at capture.
Metadata bits [15:0] contain four registered command codes (oldest first);
bits [23:16] contain their bank numbers; bits [26:24] are the phase counter,
[28:27] the capture-delay counter and [29] the controller DQ output-disable.
This observes controller-side registered commands, not independent pin probes.
After 100 ms of an invalid-access stall and a recorded suspect read, `RVP`
rereads that event's physical address four times and takes report priority.
The event stays frozen until system reset, including during later transfers.
This build disables the per-transaction `RVL` reports to reduce placement
pressure; four `RVT` records remain, and the suspect event's three data stages
are retained in `RVS`.
CAS 2 and the 180-degree SDRAM clock phase are unchanged.
The SGX, CD and superset schedulers defer an RV-channel read when a VDC0 write is
already pending for the same slot, avoiding a bank-3 WRITE one clock after
the RV READ. The same guard also protects reads from CD/ADPCM requesters on
this shared channel. `RV_READ_WRITE_GUARD` is independent of the SGX fixed
capture mode; CD keeps its previous capture timing and VDC1 bank placement.
`+write_turnaround` tests command spacing and VDC0 writes. Hardware tests
reported no remaining RV freezes with the SGX guard; CD still needs testing
on the board. Normal `-Profile sgx` and `-Profile cd` builds leave the RTL
UART diagnostics disabled and keep CAS 2 and the 180-degree clock phase.
Superset also enables the guard while retaining its original capture timing
and VDC1 in bank 2; build it with `-Profile superset`.
The profile script selects `Route_Option=1` for superset only; the default
routing missed setup timing with this guard. Other profiles keep their
existing build settings.
The `+vm01` variant
of `tb_sprite_stream` exercises alternating NOP/read VDC0 slots with zero
address on NOP; it is not a complete HuC6270 VM timing model.

The resulting FPGA bitstream is `impl/pnr/PCE_GT_TangNano.fs`. Program it
with the Gowin Programmer or `openFPGALoader`:

```sh
openFPGALoader -b tangnano20k impl/pnr/PCE_GT_TangNano.fs     # volatile
openFPGALoader -b tangnano20k -f impl/pnr/PCE_GT_TangNano.fs  # FPGA flash
```

Flash `firmware/firmware.bin` **separately** into the board SPI flash at
**offset `0x500000`**. The FPGA bitstream alone does not update the firmware.
Do not write the firmware binary at offset zero. On Windows, the Gowin
Programmer can write the binary at this address.

Project settings that matter (already stored in
`impl/PCE_GT_TangNano_process_config.json`):

* Top module: `top_tang_nano20k`
* VHDL standard: **VHDL-93**
* Verilog standard: Verilog-2001

### Core selection from the browser

Browser Options (Select) provides **Choose core > HuCard / CD-Rom / Superset**.
Selecting a different core asks for confirmation, checks the source slot's
profile, size and CRC32, then erases/programs/verifies the first 1 MiB of flash.
The three source slots and the firmware at `0x500000` are not modified.
When `Core ready` appears, switch power off and on. S1 only resets the console
and does not load the newly installed FPGA configuration.

Prepare the initial flash contents after rebuilding all three cores:

```powershell
& .\firmware\build.ps1
& .\tools\build_profiles.ps1 -Profile all
& .\tools\prepare_core_slots.ps1
```

| SPI flash address | Raw data to program |
| --- | --- |
| `0x000000` | Initial rebuilt FPGA configuration, programmed using the normal Gowin/openFPGALoader flow |
| `0x100000` | `impl/core-slots/sgx_slot.bin` (HuCard) |
| `0x200000` | `impl/core-slots/cd_slot.bin` (CD-Rom) |
| `0x300000` | `impl/core-slots/superset_slot.bin` |
| `0x500000` | `firmware/firmware.bin` |

Program the three slot images as raw SPI flash data at the specified offsets,
not as FPGA configuration downloads. They contain the existing Gowin `.bin`
unchanged at the start, `0xFF` padding, and metadata in the final 32 bytes.
The metadata is five little-endian 32-bit words: magic `0x50434543`, version
`1`, profile ID (`1/2/3`), bitstream byte length, CRC32/ISO-HDLC of the bitstream.
The remaining 12 bytes are `0xFF`. Do not program only the original `.bin` into
a source slot: the firmware requires this metadata before erasing address zero.
Use range/sector erase, never whole-chip erase when installing or updating
slots, and verify the programmer's readback. All three stored cores and the
initial core must include the new flash PIO interface; changing only the menu
firmware cannot add this interface to old bitstreams.

Launching a HuCard game from CD-Rom offers a switch to HuCard. Launching a CUE
or a `(CD)` directory from HuCard offers a switch to CD-Rom. Accepting writes
the exact game and directory to `/config/core_autorun.dat` on the SD card.
After the successful copy and power cycle, the matching core consumes and
deletes that request **before** loading the game; subsequent boots return to
the browser. Superset launches either kind directly. Manual core selection
does not create an autorun request. Cancelling a confirmation does not write
flash or create an autorun request. Invalid requests, a wrong active profile,
or a failed game load return to the browser instead of retrying indefinitely.

**Hardware validation is still required before relying on this feature.**
The latest builds generate all three images, but HuCard has a negative SETUP
slack of `-0.515 ns` in the SDRAM address path; CD-Rom and Superset have positive
minimum SETUP slacks (`+0.092 ns` and `+0.030 ns`). The dedicated NOR transaction
test and 15 RISC-V autorun cases pass. The full simulation suite is not green
(iosys timeout and OSD/SDRAM failures).
NOR erase/program timing, board flash protection, startup from the copied raw
Gowin `.bin`, and end-to-end SD autorun must be verified on the Tang Nano.
Do not interrupt a copy. A failed or interrupted write can invalidate address
zero; the preserved source slots do not provide automatic recovery. Restore
the boot configuration using an external programmer in that situation.

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
| `uart_tx` | 69 | firmware status and CD diagnostics at 115200 baud |
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

In the firmware browser, Up/Down select a file, Left/Right change pages, A
opens a directory or loads a `.pce`, `.sgx` or `.cue`, and B goes to the parent
directory. A folder ending in `(CD)` automatically opens its first CUE file.
The SuperGrafx profile can also load standard `.pce` HuCard games.
During a game, Select+Start opens the firmware pause menu (Resume, Reset,
Return to browser, gamepad mode and video/audio settings). Hold Select for
500 ms before using Select+Up/Down for zoom or Select+Left/Right for scanlines.
The game's own RUN/Start button does not pause CD music on its own.

---

## 4. Loading a ROM

Insert a FAT16/FAT32/exFAT microSD card with `.pce` HuCard images, `.sgx`
SuperGrafx images or `.cue` files and their referenced BIN tracks. The
firmware mounts the card, presents the OSD browser and streams the selected
HuCard into SDRAM. Selecting a CUE loads the System Card and enables the CD
unit; selecting a folder ending in `(CD)` looks for its first CUE file.

CD boot requires a System Card image at `/config/syscard.pce` (also accepted:
`systemcard.pce` or `system_card.pce`). The CD reader supports quoted filenames
and MODE1/2048, MODE1/2352 and MODE2/2352 data tracks; CDDA uses raw 2352-byte
audio sectors. The implementation is experimental; CHD images are not
supported. Arcade Card registers and RAM are enabled for CD games, but Arcade
CD game compatibility still needs an on-board test.

The board's USB serial port remains a fallback for HuCards, even without a
microSD card. This path uses `tools/pce_send.py` and does not provide the OSD
browser's per-game save handling:

```
pip install pyserial
python tools/pce_send.py COM7 game.pce
```

(`/dev/ttyUSB0`, `/dev/ttyACM0`, … on Linux/macOS.)

The console is held in reset while the transfer runs and starts automatically
when it finishes. Sending another image at any time replaces the current one.

When using the microSD browser, the 2 KiB backup RAM is stored in
`/saves/<game>.brm`. Populous's 32 KiB SRAM uses `/saves/<game>.pop`. The game
image extension is omitted: for `game.cue`, for example, the BRAM file is
`game.brm`. Existing saves that include the image extension are still restored
as a fallback. Saves are written when the **firmware pause menu** opens. In-game
pause and power-off do not trigger a save. Keep the SD card inserted and open
the firmware menu before switching power off.

Global video and audio settings live in `/config/video.cfg` and
`/config/audio.cfg`; its `output` value selects the onboard speaker (`0`, default)
or HDMI (`1`). The current game's 2/6-button mode lives in
`/config/<game>.cfg`, without the image extension; the previous name remains a
read fallback.

Browser **Options** also provides a sprite limit of 16 or 32 per scanline,
saved in `/config/system.cfg`; it is intentionally not exposed in the in-game
pause menu. The Tang Nano wrapper keeps the VDC `SP64` fetch mode disabled.

### User cheat files

Place a cheat file beside the SD card's hidden `cheats` directory, using the
loaded image type and the image basename without its final extension:

| Image | Cheat file |
| --- | --- |
| HuCard `.pce` | `/cheats/pce/<game>.cht` |
| SuperGrafx `.sgx` | `/cheats/sgx/<game>.cht` |
| CD `.cue` | `/cheats/cd/<game>.cht` |

Only the following `.cht` form is supported: a decimal `cheats` count,
zero-based `cheatN_desc`, `cheatN_code` and `cheatN_enable` entries. Descriptions
must be double-quoted. Codes contain one or more hexadecimal `address:value`
pairs separated by `+`, for example:

```ini
cheats = 2
cheat0_desc = "Infinite Time"
cheat0_code = "1f0dbc:99"
cheat0_enable = false
cheat1_desc = "P1 Infinite Health"
cheat1_code = "1f1410:b0+1f1424:b0"
cheat1_enable = false
```

Addresses must fit 21 bits (`0x000000`–`0x1fffff`) and replacement values 8
bits (`0x00`–`0xff`). This syntax has no compare byte; other cheat formats or
encodings are not claimed to work. Blank lines and `#` comments are ignored.
Missing required fields or invalid code values make the file invalid; invalid
or out-of-range saved indices are ignored with a UART diagnostic. Up to 64
groups can be listed, but the total patches in enabled groups must not exceed
the hardware limit of 4 on every profile. A selection above that limit is
rejected as a whole.

The pause menu's `Cheats (x/y)` entry opens a scrollable list; A toggles a group
and B returns. `.cht` `cheatN_enable` values seed the state unless
`cheats_activated=[0,2]` exists in `/config/<game>.cfg`. Toggling writes that
list while preserving `pad_mode`. Existing `/config/<game>.<rom-extension>.cfg`
files are read if the extensionless config is absent; writes use only the
extensionless path and leave legacy files untouched.

Codes are loaded while the new game is held in reset. The Tang MMIO sequence
disables and resets the engine, writes each 21-bit address and 8-bit value,
pulses the add strobe, then enables application. The hardware compares CPU
read addresses and replaces matching read data; codes are not general RAM
writes, and address/bank mapping compatibility is game-dependent. Switching
games and returning to the browser clears hardware codes; a warm reset of the
same game keeps them.

The standard Tang synthesis report (Gowin V1.9.11.03) reports `14,170` LUT,
`2,939` ALU, `438` SSRAM cells and `43/46` BSRAM blocks. Resource occupancy
and the main consumers are summarized in section 6. The protocol simulation
`sim/tb_cheat_protocol.sv` covers clear, two patch transfers, matching-address
replacement and enable polarity. SD-card parsing and game/address compatibility
still require on-board validation; no claim is made that arbitrary codes work
with every ROM mapping.

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
* SuperGrafx (`.sgx`) images load and run with the second VDC (`SGX_SUPPORT = 1`,
  see the feature table above): both VDC1 and the VPC mixer are built and
  `sgx_mode` (set from the `.sgx` extension by the loader) enables the
  SuperGrafx address decoding and VRAM1 access at runtime.

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

With the browser open, choose **Options > Audio Settings > Output** to switch
between the onboard speaker and HDMI. Speaker is the default. Speaker mode uses
the existing I2S amplifier; HDMI mode sends 16-bit stereo LPCM at 48 kHz in
HDMI data islands and disables the onboard amplifier. The video timing is
unchanged, and HDMI playback still needs verification on a physical display.

The HuC6280 PSG, CDDA and decoded ADPCM are mixed before the board's 16-bit
stereo I2S output (about 48.2 kHz); the CDDA sample clock is approximately
44.35 kHz rather than exactly 44.1 kHz. The CDDA FIFO is 12 KiB (about 70 ms,
8 BSRAM blocks); firmware services it from the SD card through a 32-bit audio
feed port and stops feeding once it is half full. The SCSI CD-data FIFO is
4 KiB (two sectors), implemented in BSRAM; its synchronous read uses a prefetch
state before asserting SCSI REQ. The CD unit supports
track selection, repeat, pause, GET SUBQ and register-controlled CDDA/ADPCM
fade. The ADPCM nibble RAM is in SDRAM, not block RAM. CDDA and data playback
have been exercised on hardware; the newly connected ADPCM memory path passed
focused SDRAM simulation and Gowin place-and-route but still needs an audible
on-board test. The CD profile now uses 41 of the 46 available BSRAM blocks,
including two blocks for the 4 KiB SCSI data FIFO, eight for the CDDA FIFO and
six for the CD RAM cache (see section 6).

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

## 6. Occupation

The following figures come from the compatibility-superset Gowin V1.9.11.03
synthesis report for the GW2AR-18. The device has a shared pool of `20,736`
logic resources; this build reports `18,225` used (`87.9%`), leaving `2,511`
(`12.1%`). LUT and ALU counts are shown separately, but the report does not
give independent device limits or remaining counts for either resource.

| Resource | Used | Capacity reported | Utilization / share | Remaining | Main consumers in the hierarchy report |
| --- | ---: | ---: | ---: | ---: | --- |
| LUT | 13,926 | Shared logic pool: 20,736 | 67.1% of pool | Not reported separately | Superset profile |
| ALU | 3,279 | Shared logic pool: 20,736 | 15.8% of pool | Not reported separately | Superset profile |
| Logic resources, total | 18,225 | 20,736 | 87.9% | 2,511 (12.1%) | Shared device logic pool |
| BSRAM | 46 blocks | 46 blocks | 100% | 0 | Superset profile |
| SSRAM | 170 cells | Not reported | Not reported | Not reported | Superset profile; SCSI data FIFO is in BSRAM |

The profile builds produced these additional synthesis results:

| Profile | LUT | ALU | Total logic | BSRAM | BSRAM remaining |
| --- | ---: | ---: | ---: | ---: | ---: |
| PCE | 13,250 | 1,788 | 16,016 / 20,736 (78%) | 46 / 46 | 0 |
| SuperGrafx | 10,297 | 2,110 | 13,379 / 20,736 (65%) | 43 / 46 | 3 |
| CD, VDC1 active / VPC off | 12,058 | 2,064 | 15,100 / 20,736 (73%) | 41 / 46 | 5 |
| Superset | 13,653 | 2,627 | 17,300 / 20,736 (84%) | 46 / 46 | 0 |

The LUT column counts LUT cells only; inverter cells are reported separately
(the exact inverter counts vary with synthesis optimization). Current worst
setup slack is `+0.486 ns` for PCE, `+0.490 ns` for SGX, `+0.117 ns` for CD
(with `Place_Option` 1; the default placement left the clk_sys to clk_mem
VDC1 request path at `-1.268 ns`),
and `+0.003 ns` for Superset. CD keeps VDC1's SDRAM activity, which was needed
for reliable CD startup, while SGX CPU address decoding and the VPC remain off.
The CD Game Genie table is limited to four address/value patches; PCE is limited
to eight, and the firmware refuses activations that exceed the profile limit.
All four profiles meet setup timing, although Superset has virtually no margin.
The PCE BSRAM profile uses every BSRAM block
and has no memory-block headroom. Generated profile binaries are `907,418`
bytes each. These are build measurements, not hardware validation of automatic
Multi-Boot switching.

The LUT figure above counts LUT cells only. The report also lists 97 `INV`
cells; its logic summary displays 14,267 LUT-related cells including those
inverters. Hierarchy totals include child modules and must not be added to their
parent totals. SSRAM is reported as cells (`RAM16S4` / `RAM16SDP4`), not as a
capacity in bits.

The on-package SDRAM has a physical capacity of 8 MiB. The table below describes
the compatibility-superset profile's address-space allocation; the ROM and
Arcade Card share the first 4 MiB window, so they are alternatives rather than
additive allocations. In the normal PCE BSRAM profile, VDC0 VRAM is local BSRAM
and does not use the final 64 KiB of this SDRAM map.

| SDRAM allocation | Address / size | Share of 8 MiB | Notes |
| --- | --- | ---: | --- |
| HuCard ROM / Arcade Card window | `0x000000..0x3FFFFF`, 4 MiB | 50% | HuCard uses banks 0-1; Arcade Card uses bank 1 in CD mode |
| PicoRV32 firmware/data | `0x400000..0x59FFFF`, 1,664 KiB | 20.3% | Bank 2 |
| ADPCM nibble RAM | `0x5A0000..0x5AFFFF`, 64 KiB | 0.8% | Bank 2 |
| CD scratch RAM | `0x5B0000..0x5EFFFF`, 256 KiB | 3.1% | Includes Populous SRAM backing; bank 2 |
| VDC1 VRAM | `0x5F0000..0x5FFFFF`, 64 KiB | 0.8% | Bank 2 |
| VDC0 VRAM | `0x7F0000..0x7FFFFF`, 64 KiB | 0.8% | Bank 3 |
| Unassigned address space | `0x600000..0x7EFFFF`, 1,984 KiB | 24.2% | Not assigned by the current map |

The four bank-2 allocations total 2 MiB (25%). The SDRAM runs at 86.4 MHz;
`rtl/tang/pce_sdram_ctrl_3ch.v` assigns fixed slots to (1) HuCard ROM/loader,
(2) PicoRV32/CD/Arcade/ADPCM or VDC1 and (3) VDC0. Its eight-cycle schedule
returns VRAM data within one fastest PCE pixel period. Refresh is distributed
across idle slots and is also allowed while the console is held in reset.

Host accesses and VDC/RV accesses must not open different rows in the same
bank concurrently. In particular, loader clears in bank 2 could previously
issue host ACT at phase 7, then RV/VDC1 ACT at phase 1, followed by host WRITE
at phase 2 using the replaced row. The scheduler now guards these shared-bank
activations until the host access completes; bank-3 loader writes similarly
exclude VDC0 activation. This is required for memory correctness independently
of requester priority.

The focused simulation uses `tb_sprite_stream` with `READ_HOLD_CYCLES=1` and
`LOADER_BASE=23'h5e0000`, plus `+capture_test +transition_test +loader_test`.
It exercises disjoint addresses in bank 2 with RV reads/writes, VRAM and ROM
traffic during VCE transitions. The former scheduler fails loader verification;
the guarded scheduler verifies all 1024 loader bytes. The one-cycle read window
is an opt-in check, not a complete SDRAM electrical timing model.

CD scratch RAM and Arcade Card RAM share the PicoRV32 SDRAM channel, so CPU
accesses go through a direct-mapped, write-through cache of 32-bit SDRAM words
(`CDRAM_CACHE_IDX`). Profiles with the CD logic and no extra SGX get 2,048
lines (8 KiB, 6 BSRAM blocks); the others keep 16 lines in distributed RAM.
Hits never stall the CPU; misses and every write wait for the SDRAM round trip.
Firmware writes into the CD RAM window invalidate the matching line, and a ROM
load clears the whole cache.

### RV hardware UART diagnostics

Build `powershell -File tools/build_profiles.ps1 -Profile sgx_rv_diag` for a
separate SGX diagnostic bitstream. It retains the existing SGX arbitration,
video and audio configuration. No firmware update is required. Open the UART
at the firmware baud rate (normally 115200, 8N1) before starting the game.

The independent RTL monitor starts after firmware loading, reports every
second, and also snapshots a bus wait or lack of completed transactions after
10 ms, or a rising PicoRV32 `trap`. It shares the existing UART transmitter,
waiting for the current character to finish and pausing firmware UART writes
while its report is sent. Illegal-instruction detection remains unchanged.

Each line is `RVD r aaaaaaaaddddddddccccccccssssssss` (hexadecimal):

- `r`: event mask, bit 0 = bus wait, bit 1 = no completed transactions,
  bit 2 = trap; zero means a periodic report without a recorded event.
- `aaaaaaaa`: current RV bus address; `dddddddd`: loader/host debug state.
- `cccccccc`: completed CPU bus transaction count since firmware startup.
- `ssssssss`: status sampled when the report was triggered.

Loader word bits: 31 = host active; 30 = host latched write; 29 = host CAS
issued; 28 = host request (memory domain); 27 = host ACK (memory domain);
26 = VDC0 request pending; 25:24 = host kind (0 none, 1 loader, 2 ROM);
23 = host busy; 22 = queued loader byte; 21 = host write; 20 = host request
(system domain); 19 = synchronized ACK; 18 = aggregate loading;
17 = aggregate loader write; 16 = aggregate loader idle; 15:13 reserved;
12 = UART owns loader; 11:9 = firmware loader byte count; 8 = clearing;
7 = finishing; 6 = firmware loading; 5 = firmware image valid;
4 = firmware loader busy; 3 = loader idle; 2 = firmware loader write;
1 = loader data ready; 0 = clear phase. The last CPU read remains available
in the `RVT` transaction history.

Status bits: 31:28 = current refresh debt; 27:25 = SDRAM phase;
24:22 = active channels; 21:20 = channel-1 owner (0 none, 1 RV, 2 VDC1);
19 = memory RV request toggle; 18 = its ACK toggle; 17 = refresh block;
16 = SDRAM initialized; 15:11 reserved; 10:9 = VCE dot-clock selection;
8 = firmware loaded; 7 = SDRAM RV valid; 6 = SDRAM RV ready;
5 = CPU RAM decode; 4 = trap; 3 = instruction fetch; 2 = CPU bus ready;
1 = CPU bus valid; 0 = CPU write.

The scheduler status crosses clock domains as a two-register debug sample,
not an atomic transaction trace. A stopped counter with request != ACK suggests
a memory wait; an unmapped CPU address suggests a bad access. An advancing
counter without firmware `alive` output suggests continued execution, not
necessarily correct execution. Save several reports before and after a stall.

After a timeout or trap with recorded CPU activity, the monitor also sends
eight or fewer lines `RVT i aaaaaaaaddddddddccccccccffffffff`, oldest first.
These are the last completed CPU transactions before the event. `i` is the
chronological index, `aaaaaaaa` the transaction address, `dddddddd` the read
result or write data, and `cccccccc` the zero-based transaction number.
In `ffffffff`, bit 4 indicates an instruction fetch and bits 3:0 are the byte
write strobes (zero for a read). The ring is frozen during transmission;
it rearms after the dump if CPU transactions resume without a trap. Thus a
temporary loader wait does not permanently hide a subsequent fault. A CPU
that remains stalled keeps its trace frozen. Capture all `RVT` lines as well
as the `RVD` reports; the blocked transaction itself is shown by `RVD`, not
by the completed-transaction history.

Each `RVD` report is followed by `RVX 0 ppppppppoooooooovvvvvvvvaaaaaaaa`,
capturing the last actual CPU register write to x22: instruction PC, opcode,
new register value, and last completed non-instruction read address. The read
address is useful for an LW restoration but is not meaningful as a source for
LUI/ALU writes. RVX is frozen with its corresponding RVD snapshot. It observes
the writeback bus, not an independent readback of the register RAM; corruption
without a writeback is therefore not directly measured. RVT records are still
sent after RVX on a stall. No CPU execution settings are changed.

When a CPU transaction stalls for 10 ms at an address outside RAM and the
MMIO page (or above offset 0x100 within that page), a read-only hardware probe
requests four rereads of the first suspect RAM read's captured physical address.
Without a recorded suspect read the probe does not start. CPU responses are
not forged; the invalid CPU access remains stalled. After all four replies,
`RVP 0 vvvvvvvvwwwwwwwwxxxxxxxxyyyyyyyy` replaces RVX in subsequent reports,
showing the four results oldest first. Compare them with the captured data
in RVS. The probe runs once per system
reset and uses the same SDRAM scheduler as the CPU, not a second physical
memory interface. A repeated value different from the saved stack word could
be stored corruption or a repeatable controller error.

Each report also includes `RVS 0 aaaaaaaassssssssbbbbbbbbcccccccc`:
CPU address, SDRAM captured data, bridge output and CPU read data for the
first suspect RAM read. An all-zero record means no event was captured.
Probe transactions do not update this record. RVS is frozen with its RVD snapshot and
remains present when RVP replaces RVX after the rereads.

---

## 7. Source layout

```
rtl/
  top_tang_nano20k.v          board top level
  pce_top_extram.vhd          console (upstream, + CD_SUPPORT/AC_SUPPORT generics)
  huc6202.vhd, huc6260.vhd,
  huc6270.vhd                 VPC / VCE / VDC (upstream)
  HUC6280/                    CPU + PSG (upstream)
  dpram.vhd                   portable block RAM (replaces the altsyncram version)
  mem_init_pkg.vhd            generated memory initialisation tables
  cd/                         CD-ROM unit, SCSI, CDDA FIFO, ADPCM decoder (built)
  shared/                     MiST wrapper - kept for reference, NOT in the project
  tang/
    pce_core.vhd              console wrapper: ROM, both VRAMs, CD and ADPCM
    iosys/                    PicoRV32, SPI microSD, OSD, UART and CD bridge
    audio_tone.v              global volume / bass / treble
    pll_clocks.v              rPLL / CLKDIV instances
    pce_sdram_ctrl_3ch.v      interleaved ROM / firmware / CD / VRAM controller
    uart_rx.v, rom_loader.v   UART ROM loader
    video_scandoubler.v       genlocked line doubler + HDMI timing
    tmds_encoder.v, dvi_tx.v  HDMI/DVI TMDS encoder, data islands, OSER10 serializers
    audio_sampler_48k.sv      HDMI 48 kHz stereo sample clock
    hdmi_audio_packetizer.sv  LPCM, ACR, InfoFrame and BCH packet generation
    i2s_tx.v                  onboard-speaker I2S transmitter
    snes_gamepad.v, pce_pad.v pad reader and PC Engine pad multiplexer
constraints/
  tang_nano20k.cst            pin assignments
  tang_nano20k.sdc            clock constraints
tools/
  pce_send.py                 host side ROM sender
  build.tcl                   Gowin batch build
  build_profiles.ps1          isolated PCE / SGX / CD profile builds
  mif2vhd.py                  .mif -> VHDL constant tables
firmware/
  build.ps1                   RV32I firmware build
  firmware.c                  entry point, SD mount, in-game main loop
  browser.c                   microSD file browser
  rom.c                       HuCard (.PCE/.SGX) loading
  cd.c                        CD-ROM emulation (CUE, System Card, CD-DA)
  menu.c                      pause menu, video/audio sub-menus
  settings.c                  video/audio/pad settings (/config)
  saves.c                     backup RAM / Populous SRAM saves (/saves)
  osd.c, util.c               OSD and string helpers
sim/
  run.ps1                     Icarus simulation runner
```

`rtl/shared/`, `rtl/mb128.sv`, `rtl/pce_top.vhd` and the older
`rtl/tang/sdram.v` / `rtl/tang/pce_sdram_ctrl.v` are retained for reference,
but are not part of `PCE_GT_TangNano.gprj`. The project **does** include
`rtl/arcade.sv`, `rtl/cd/`, `rtl/CEGen.vhd`, `rtl/cheatcodes.sv` and
`rtl/color_mix.sv`.

---

## 8. Changes made to the upstream core

The original core is adapted to Gowin and the board interfaces:

* `rtl/dpram.vhd` — rewritten with inferred, vendor independent VHDL. The entity
  names, generics, ports and defaults are unchanged, and the behaviour of the
  original `altsyncram` configuration is reproduced (synchronous unregistered
  read, `NEW_DATA` read-during-write on the same port, `cs_x` masking).
  `mem_init_file` now selects one of the tables in `work.mem_init_pkg`.
* `rtl/pce_top_extram.vhd` — exposes external VRAM, CD scratch RAM, ADPCM RAM
  and debug ports. The Tang build enables CD, Arcade Card and SuperGrafx but
  not Game Genie; the CD unit and its FIFOs are included in the project.
  `VOLTAB_FILE` uses `voltab_small.mif`.
* `rtl/tang/iosys/` and `firmware/` — PicoRV32 firmware, microSD/FatFs browser,
  CD SCSI command handling, audio streaming and per-game save persistence.
* `rtl/tang/pce_sdram_ctrl_3ch.v` — SDRAM arbitration, HuCard/VRAM bridges,
  direct-mapped CD/Arcade RAM cache (8 KiB in BSRAM on the CD profiles) and
  the nibble-oriented ADPCM bridge.
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
* HDMI audio packet scheduling follows HDMI 1.4a packet organization and was
  informed by NESTang's GPLv3 HDMI2 transmitter by Sameer Puri.
* The TMDS encoder implements the encoding algorithm published in the DVI 1.0
  specification.
* Everything else under `rtl/tang/`, `constraints/` and `tools/` was written for
  this port and is released under the same terms as the core it is part of.

## 10. Support

* Tips are welcome : https://ko-fi.com/tawyy
