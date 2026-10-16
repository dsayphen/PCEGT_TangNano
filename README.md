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
| Audio | PSG/CDDA/ADPCM; onboard speaker or HDMI audio |
| Controller | one SNES-style pad, 2/6-button modes; S1 resets the console |
| ROM loading | microSD browser; USB-UART fallback, see section 4 |
| CD-ROM² / Super CD | experimental CUE/BIN, System Card, CDDA, SCSI data and ADPCM |
| Arcade Card | available in CD mode |
| SuperGrafx (second VDC / VPC) | yes (`SGX_SUPPORT = 1`) |
| Cheats | per-game `.cht` files |
| Backup RAM (BRAM), Populous SRAM | saved per game on microSD at firmware-menu entry (not on power loss) |
| Multitap, mouse, MB128 | not implemented |
| OSD / menu | microSD browser, in-game pause, audio and video settings |

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

To build the three profile variants, run:

```powershell
& .\tools\build_profiles.ps1 -Profile all
```

The script creates temporary Gowin project/config copies and stores each
profile's bitstream and binary under `impl/profiles/{sgx,cd,snes}/`.
The `all` build selects `sgx` (HuCard, including ordinary PCE games), `cd`
(CD-Rom), and experimental `snes`. SGX is the default boot profile;
Superset is no longer built or offered by the core selection menu.
Each core image is about 887 KiB and fits a 1 MiB flash slot. Core selection
copies the selected image to the boot address, then requests a reload through
the tested GPIO29 connection described below.

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

### Core selection from the browser

Browser Options (Select) provides **Choose core > HuCard / CD-Rom / SNES**.
Selecting a different core asks for confirmation, checks the source slot's
profile, size and CRC32, then erases/programs/verifies the first 1 MiB of flash.
The three source slots and the firmware at `0x500000` are not modified.
When `Core ready` appears, A requests an FPGA reload if the GPIO29/TP1
hardware is installed and the rebuilt core supports it. Otherwise use the
TP1 button or switch power off and on. S1 only resets the console and does
not load the newly installed FPGA configuration.

#### FPGA reload after core copy

On the Tang Nano 20K v3923, TP1 is the FPGA `RECONFIG_N` button point; TP2 is
ground. A tested setup connects TP1 to GPIO29 and pulls GPIO29 up to 3.3 V
through a 110 kOhm resistor. The firmware requests a three-second reload pulse
after a core copy has completed and been verified. At `Core ready`, press A to
reload; otherwise use TP1 or power-cycle the board. Never trigger reload or
power off during flash programming. Do not connect TP1 to GPIO26.

Build the firmware, cores and flash images with:

```powershell
& .\firmware\build.ps1
& .\tools\build_profiles.ps1 -Profile all
& .\tools\prepare_core_slots.ps1 -CombinedImage
```

This creates `impl/core-slots/cores_sgx_cd_snes.bin`, a 5 MiB image:
SGX boot at `0x000000`, SGX source at `0x100000`, CD-Rom at `0x200000`,
SNES at `0x300000`, and a reserved `FF`-filled slot at `0x400000`.
Update the firmware when moving SNES from its previous slot.
Program it as raw SPI flash data at `0x000000`, with erase/program/verify
limited to `0x000000..0x4FFFFF`. **Never use Bulk Erase.** The firmware is a
separate file at `0x500000`. Verify programmer readback and power-cycle after
programming.

Launching a HuCard game from CD-Rom offers a switch to HuCard. Launching a CUE
or a `(CD)` directory from HuCard offers a switch to CD-Rom. Accepting writes
the exact game and directory to `/config/core_autorun.dat` on the SD card.
After copying, the requested core starts and loads the selected game. **Do not
interrupt a core copy.** If power is lost during programming, restore the boot
image with an external programmer.

### Experimental SNES profile

The [SNESTang](https://github.com/nand2mario/snestang) core is available as a
separate profile and shares this project's firmware, browser, OSD, saves and
core selection. Build it with `tools/build_profiles.ps1 -Profile snes`.

The browser supports `.sfc` and `.smc` images, including copier headers, and
SNES saves use `/saves/<game>.srm`. Video output is 640x480 with Integer,
Stretch and Bilinear zoom modes; scanlines and zoom are available in Video Settings.
ExHiROM and enhancement-chip games such as Super FX and SA-1 are not supported.

The profile uses the upstream RAM layout, tested with Super Mario World
(USA, 512 KiB), and accepts ROMs up to 3.75 MiB. The new Bilinear mode still
needs hardware testing. CD and SNES support remain experimental.

See [SNES source and license information](rtl/snestang/README.md).

---

## 3. Connections

| Signal | Pin | Note |
| --- | --- | --- |
| 27 MHz clock | 4 | |
| `s1` (button) | 88 | **reset** the console |
| `uart_rx` | 70 | from the on-board BL616 USB-serial bridge |
| `uart_tx` | 69 | firmware messages at 115200 baud |
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
audio sectors. CHD images are not supported.

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
or HDMI (`1`). The current game's pad mode lives in `/config/<game>.cfg`,
without the image extension; the previous name remains a read fallback.
`pad_mode` values are `0` (2 buttons), `1` (standard 6 buttons), and `2`
(6-button SF2 layout). Recognized Street Fighter II/SF2 filenames default to
mode 2 when no `pad_mode` is saved. Standard six-button mode keeps the existing
mapping. In SF2 mode, SNES A/B/X/Y/L/R map to PCE II/III/V/IV/VI/I
respectively. A saved per-game setting still overrides the default; the
in-game Gamepad option cycles through all three modes.

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

Use numbered descriptions, codes, and enable flags. For example:

```ini
cheats = 2
cheat0_desc = "Infinite Time"
cheat0_code = "1f0dbc:99"
cheat0_enable = false
cheat1_desc = "P1 Infinite Health"
cheat1_code = "1f1410:b0+1f1424:b0"
cheat1_enable = false
```

The pause-menu Cheats entry opens the list; A toggles a group and B returns.
Enabled cheats are saved per game. Compatibility varies by game.

For USB-UART loading, send an unmodified `.pce` image:

```sh
pip install pyserial
python tools/pce_send.py COM7 game.pce
```

---

## 5. Video and audio

Video is output at 640x480-class resolution over HDMI/DVI. The browser and games
run close to 60 Hz; the exact refresh may vary slightly by game.

Choose **Options > Audio Settings > Output** to switch between the onboard
speaker and HDMI audio. Speaker is the default. The selected output is retained
when returning from a game to the browser.

CD games support CD audio and ADPCM. CD-ROM support remains experimental.

---

## 6. Development

Resource use in the latest successfully placed Gowin builds:

| Profile | Logic (Total) | LUT | Registers | BSRAM |
| --- | ---: | ---: | ---: | ---: |
| SGX | 13,649 / 20,736 (66%) | 10,516 | 7,100 / 15,915 (45%) | 43 / 46 (94%) |
| CD | 15,480 / 20,736 (75%) | 12,196 | 7,489 / 15,915 (48%) | 41 / 46 (90%) |
| SNES | 20,542 / 20,736 (100%) | 16,961 | 7,271 / 15,915 (46%) | 46 / 46 (100%) |

Run the available simulations from the repository root:

```powershell
& .\sim\run.ps1
```

---

## 7. Credits and licences

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

## 8. Support

* Tips are welcome : https://ko-fi.com/tawyy
