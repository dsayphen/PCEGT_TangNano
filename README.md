# PC Engine / TurboGrafx-16 for the Sipeed Tang Nano 20K

A PC Engine / SuperGrafx port of the
[mist-devel/TurboGrafx16_FPGA](https://github.com/mist-devel/TurboGrafx16_FPGA)
core to the **Sipeed Tang Nano 20K** (Gowin `GW2AR-LV18QN88C8/I7`). CD-ROM
support is experimental. The board also has experimental SNES and combined
NES / Game Boy / Game Boy Color profiles.

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
| NES + Game Boy / Game Boy Color | experimental combined `nesgb` profile |
| Game Boy cartridges | ROM-only, MBC1, MBC3 without RTC, and MBC5; ROMs up to 0x3D8000 bytes |
| Game Boy Color | `.gb` and `.gbc`; CGB mode follows header byte 0x143; mid-frame palette changes are approximated |
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

To build the four profile variants, run:

```powershell
& .\tools\build_profiles.ps1 -Profile all
```

The script creates temporary Gowin project/config copies and stores each
profile's bitstream and binary under
`impl/profiles/{sgx,cd,snes,nesgb}/`.
The `all` build selects `sgx` (HuCard, including ordinary PCE games), `cd`
(CD-Rom), experimental `snes`, and experimental `nesgb` (Nintendo 8-bit).
SGX is the default boot profile; Superset is no longer built or offered by
the core selection menu. Each core image fits a 1 MiB flash slot. Core
selection copies the selected image to the boot address, then requests a
reload through the tested GPIO29 connection described below.

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

Browser Options (Select) provides
**Choose core > HuCard / CD-Rom / Nintendo / Nintendo 8-bit**.
Selecting a different core asks for confirmation, checks the source slot's
profile, size and CRC32, then erases/programs/verifies the first 1 MiB of flash.
The four source slots and the firmware at `0x500000` are not modified.
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

This creates `impl/core-slots/cores_sgx_cd_snes_nesgb.bin`, a 5 MiB image:
SGX boot at `0x000000`, SGX source at `0x100000`, CD-Rom at `0x200000`,
SNES at `0x300000`, and Nintendo 8-bit at `0x400000`.
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
The in-game pause menu stops the core without capturing a frame; the stopped
24-line buffer may repeat behind the OSD. Returning to the browser hides the
game background in black while leaving the OSD visible. This requires both
the updated SNES bitstream and firmware.
To fit the FPGA, the SNES profile has no bass/treble controls (master volume
remains) and no UART firmware messages.
ExHiROM and enhancement-chip games such as Super FX and SA-1 are not supported.

The profile uses the upstream RAM layout, tested with Super Mario World
(USA, 512 KiB), and accepts ROMs up to 3.75 MiB. The new Bilinear mode still
needs hardware testing. CD and SNES support remain experimental.

See [SNES source and license information](rtl/snestang/README.md).

### Experimental Nintendo 8-bit profile

Build the combined NES and Game Boy bitstream with
`tools/build_profiles.ps1 -Profile nesgb`. It uses the NES core from NESTang
without MMC5 and a Game Boy / Game Boy Color core ported from GBCandy Nano.
Cartridges support ROM-only, MBC1, MBC3 without RTC, and MBC5; RAM save
persistence is not implemented. Work RAM lives in SDRAM at 0x3D8000, so ROMs
are limited to 0x3D8000 bytes. CGB palettes are applied when the frame is
displayed, so mid-frame palette changes are approximated.

Video output is 640x480 at 60 Hz. The Video Settings menu provides:

| Setting | NES | GB / GBC |
| --- | --- | --- |
| Color | Original, Composite Direct (FBX), NES Classic (FBX), PC-10, PVM Style D93 (FBX), Smooth (FBX), Sony CXA, Wavebeam | GB: Off / DMG / Pocket / Light. GBC: Off / Accurate / Fast |
| Integer | 512x480 (2x), centered | 480x432 (3x), centered |
| Stretch | 640x480, nearest neighbor | **Wide Stretch**: 640x432 (4x horizontal, 3x vertical), centered |
| Bilinear | 640x480, horizontal interpolation, as on PCE | Not offered; an existing mode-2 setting maps to Wide Stretch |
| Scanlines / Grid | Darkens alternate output lines: Off / 25% / 50% / 100% | Dot grid: Off / 10% / 20% / 30%, aligned to source pixels in either zoom |

The GB grid is a lightweight FPGA interpretation of
[GBC-dot-matrix-shader](https://github.com/luigira/GBC-dot-matrix-shader):
pixel gaps blend towards white, leaving white backgrounds unchanged. It does
not implement the original shader's multi-pass shadows or other GPU effects.
GBC Accurate uses Pokefan531/hunterk's public-domain
[GBC color matrix](https://github.com/libretro/glsl-shaders/blob/master/handheld/shaders/color/gbc-color.glsl)
with Gambatte's default Accurate gamma settings (2.2 - 0.5 input, 2.2 output).
Fixed-point tables differ by at most 1/255 per channel from the floating-point
reference over all 32768 RGB555 colors.
Fast uses Gambatte's original integer correction, without gamma processing.
The DMG/Pocket/Light colors follow the
[Gambatte hardware palettes](https://github.com/libretro/gambatte-libretro/blob/master/libgambatte/libretro/gbcpalettes.h).
Off preserves the previous GB shades or the uncorrected GBC colors.
The ROM's CGB header flag selects the GB or GBC color menu, independently of
the `.gb` / `.gbc` filename extension.

NES palette selection, GB palette and GBC correction are saved separately as
`nes_palette`, `gb_palette` and `gbc_color` in `/config/video.cfg`;
the previous `gbc_accurate` key is still accepted. Existing PCE color settings are
preserved. Zoom/effect strength continue to use the shared video settings and
Select+D-pad shortcuts. Menu text is not affected by palettes, interpolation
or the grid. Update both the `nesgb` bitstream and `firmware/firmware.bin`.

In the in-game menus, A advances a setting. Settings with more than two choices
also accept Left (previous) and Right (next), wrapping at either end. This
includes palettes, NES/SNES/PCE zoom, scanlines/grid and gamepad mode.
Two-choice settings retain their existing controls; audio keeps its existing
Left/Right adjustment.

The seven additional NES `.pal` files were supplied by the user from the
November 2017 FBX/Nakedarthur palette collection: FBX palettes are by
FirebrandX, Wavebeam by Nakedarthur, PC-10 follows the PlayChoice-10 PPU,
and the supplied Sony CXA palette's original author is unknown.
The previous NESTang palette is retained as Original. Palette data and
generated tables are under `rtl/nestang/palettes/`; regenerate the hardware
tables with `tools/generate_nintendo_colors.ps1` after changing the `.pal`
files. The colors are compiled into the bitstream, not loaded from SD.

The SNES pad controls both cores: B or A maps to NES/GB A, and Y or X maps
to NES/GB B. The D-pad, Select and Start retain their functions. Game inputs
are masked while the menu is open. The NES interface supplies only the
standard controller's serial data; unused expansion inputs and the
unconnected second port report no buttons pressed.

See the source and license files under `rtl/nestang/`, `rtl/gbc/` and `rtl/gb/`.

### Mega Drive experimental board profile

The Nano 20K now has an experimental Mega Drive board top with resident
PicoRV32/SD browser/OSD, x32 SDRAM, video through the HDMI connector
(DVI-compatible when HDMI audio is disabled), and selectable stereo
HDMI/on-board I2S audio. It retains the 68000, Z80, VDP, PSG and FM engines.
The user has confirmed that the centered HDMI-audio build works on hardware.
The latest changes below correct a remaining first-line alignment issue and
add selectable console regions; these changes still need a board test.

The previously validated centered HDMI-audio build used **20,266 / 20,736 logic units**
(98%), **10,611 / 15,552 fabric flip-flops** and **46 / 46 BSRAM blocks**.
Gowin V1.9.11.03 Education reports zero setup/hold violations, +0.211 ns
worst setup slack, +0.555 ns minimum serializer-reset recovery slack and
54.623 MHz master-clock Fmax against the 54 MHz constraint. The serializer
clock uses a physical BUFS clock-routing constraint; Gowin warns that its
generic routing may have excessive delay/skew, so reset and HDMI operation
still require hardware validation. These STA results depend on the supplied
constraints and do not guarantee hardware compatibility.

The latest region/video RTL completes placement and routing, but the build
gate does not export it: timing analysis reports 11 setup violations on
Z80-to-MCLK paths (worst slack -0.906 ns), with no hold violations. Do not
flash the intermediate Mega Drive files from `impl/profile-build`; a new
Mega Drive image is not ready until those paths close.

```powershell
& .\tools\build_profiles.ps1 -Profile megadrive
& .\firmware\build.ps1
& .\sim\run_megadrive_probe.ps1
& .\tools\prepare_core_slots.ps1 -MegaDriveOnly
```

The isolated build exports `impl/profiles/megadrive/pnr/PCE_GT_TangNano_megadrive.fs`
and `.bin` only after Gowin reports zero setup/hold violated endpoints.
`all` intentionally does not include this experimental profile.
No build command programs the board.

Shared firmware recognizes core ID 6 and raw `.md`, `.gen`, `.bin` images
up to 6 MiB with a `SEGA` header at offset `0x100`. Put games in
`/megadrive` on the SD card. Interleaved `.smd` files are not supported.
The optional reconfiguration slot is `0x600000` (1 MiB), after the existing
firmware slot at `0x500000`; core switching requires a populated slot and
the corresponding flash manifest. Do not overwrite other slots.
`prepare_core_slots.ps1 -MegaDriveOnly` packages the experimental binary and
manifest into `impl/core-slots/megadrive_slot.bin`, without combining it
across the firmware slot or programming any hardware.

The console runs at 54 MHz (about 0.57% above nominal NTSC), with a
27 MHz pixel / 135 MHz serializer clock. A single-BSRAM line doubler
supports 320/256-pixel input and 224/240 active lines. Output is a
640x480 active raster with source-locked, nonstandard timing; monitor
compatibility must be tested. H32 can be centered at 2x or stretched;
224-line games are centered vertically with 16 black output rows above and
below the 448-row picture. 240-line games fill all 480 rows. Sampling VBL at
the horizontal line boundary prevents a mid-line VBL transition from making
the first captured picture row partial.
In **Options > Region**, choose **NTSC US**, **NTSC Japan**, or **PAL Europe**.
The choice is saved in `/config/system.cfg`. Mega Drive uses the matching
VDP PAL and I/O export flags. The current SNES scaler is fixed to NTSC timing;
its region menu displays **NTSC only** because PAL's 50 Hz source cadence is
incompatible with its fixed-60-Hz HDMI output and rolling line buffer. Full
SNES PAL support needs a matching video/frame-buffer design.
Changing the Mega Drive setting takes effect on the next game launch/reset.
The firmware detects whether a bitstream implements the extended settings
registers before writing them; older bitstreams remain usable, but the Mega
Drive region selector asks for an updated core until that support is present.
Select **Audio Settings > Output > HDMI / Speaker** from the browser
to change output. HDMI carries stereo PCM at 48 kHz; selecting it mutes
the on-board amplifier. Scanlines and volume are available, but bilinear
filtering and bass/treble are not.
Interlaced games, cartridge-specific hardware and persistent cartridge
saves are not validated/supported by this initial profile.

The SNES pad maps Y/B/A to Mega Drive A/B/C, X/L/R to X/Y/Z,
Select to Mode and Start/directions normally. `s1` resets the console;
`s2` supplies the menu's Select input. One physical pad is connected.

#### Resource probes

A console-only probe based on
[MDTang](https://github.com/nand2mario/mdtang), itself derived from
[Genesis-MiSTer](https://github.com/MiSTer-devel/Genesis_MiSTer), targets the
Nano 20K without changing the four existing profiles. The probe measurements
below predate the final board timing optimizations:

```powershell
& .\tools\build_megadrive_probe.ps1
& .\sim\run_megadrive_probe.ps1
```

The 68000, Z80, VDP, PSG and FM audio synthesize with Gowin V1.9.11.03
Education using **16,459 / 20,736 logic units, 8,785 / 15,750 registers
and 43 / 46 BSRAM blocks**. VDP line tables and the sprite cache use
distributed RAM; explicit 68000 register-write decoding reduces logic.
Two FM lookup ROMs use BSRAM to save logic for integration.
This is a synthesis result, not a placed build:
the SDRAM controller, ROM loading, PicoRV32/browser/OSD, clock PLLs,
video scaling, HDMI and I2S are excluded. The remaining 4,277 logic units and
3 BSRAM blocks do not establish that these interfaces will fit.
The probe's ports are not physical board pins; it generates
no flashable bitstream and is not offered in the core menu or flash slots.

The memory regression compares the adapted RAMs against Gowin's DPB model,
including byte masks and independent clocks, and checks FM lookup/shift timing.
It is not a game compatibility test. Source revision, local memory changes
and limitations are documented in [the MDTang source README](rtl/mdtang/README.md).

An additional console + Nano 20K SDRAM probe is available:

```powershell
& .\tools\build_megadrive_probe.ps1 -WithSdram
```

It uses **16,897 / 20,736 logic units, 8,996 / 15,750 registers and
43 / 46 BSRAM blocks**. The adapter reuses the local x32 SDRAM engine at
the NTSC master clock, provides big-endian 16-bit console accesses, a
masked x32 host port and autonomous refresh. The initial layout supports
ROMs up to **6 MiB**, 64 KiB work RAM and 128 KiB cartridge RAM. The
regression also checks SDRAM command sequencing, byte order/masks, address
isolation, arbitration, refresh and reset. This still excludes the actual
ROM loader, firmware/OSD, PLLs and video/audio board interfaces; it is not
a playable build or a timing-closure result.

The next integration probe includes IOSys (PicoRV32, SD/flash interfaces
and text OSD) and a tested firmware/ROM-loader bridge:

```powershell
& .\tools\build_megadrive_probe.ps1 -WithMenu
```

It uses **19,222 / 20,736 logic units, 10,142 / 15,750 registers and
45 / 46 BSRAM blocks**, leaving 1,514 logic units and one BSRAM block.
The bridge initializes console RAM on reload without overwriting firmware.
This probe remains a synthesis-only boundary, distinct from the board
build above. The focused regressions cover RAM/FM, SDRAM, loader
arbitration, 68000 register-file equivalence, FM frequency-mux equivalence
and the video line doubler. Whole-frame tests verify exact 16/16 or 0/0
vertical borders for 224/240 lines, including 262/263-line NTSC frames.
HDMI tests check stereo sample order, throughput, BCH/parity, audio clock
recovery, infoframes and both compact/default packet modes;
they are not full-console/game compatibility tests. All 12 focused
Mega Drive simulation runs pass, as does the firmware/browser loader test
for the current audio-output menu/register behavior.

---

## 3. Connections

| Signal | Pin | Note |
| --- | --- | --- |
| 27 MHz clock | 4 | |
| `s1` (button) | 88 | **reset** the console |
| `uart_rx` | 70 | from the on-board BL616 USB-serial bridge |
| `uart_tx` | 69 | firmware messages at 115200 baud (PCE profiles) |
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
At startup the browser opens the core's default folder when it exists:
`/pce` for HuCard, `/pcecd` for CD-ROM and `/snes` for Nintendo (SNES);
otherwise it starts at the card root. B still goes up to the root.
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

RTL sources are grouped by core: `rtl/pce/` contains the PC Engine /
SuperGrafx core, including `HUC6280/`, `cd/` and memory initialisation files;
`rtl/snestang/` contains the SNES core. Board integration remains in
`rtl/tang/`, with both `top_tang_nano20k*.v` wrappers directly under `rtl/`.
The main Gowin project references these paths; profile projects are generated
from it by `tools/build_profiles.ps1`.

Resource use in the latest successfully placed Gowin builds:

| Profile | Logic (Total) | LUT | Registers | BSRAM |
| --- | ---: | ---: | ---: | ---: |
| SGX | 13,649 / 20,736 (66%) | 10,516 | 7,100 / 15,915 (45%) | 43 / 46 (94%) |
| CD | 15,480 / 20,736 (75%) | 12,196 | 7,489 / 15,915 (48%) | 41 / 46 (90%) |
| SNES | 20,205 / 20,736 (98%) | 16,815 | 7,151 / 15,915 (45%) | 46 / 46 (100%) |
| Nintendo 8-bit (NES + GB/GBC) | 18,119 / 20,736 (88%) | 15,588 | 7,397 / 15,915 (47%) | 46 / 46 (100%) |

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
* NES core: selected sources from
  [nand2mario/nestang](https://github.com/nand2mario/nestang), GPLv3; the
  upstream license is preserved under `rtl/nestang/`.
* Mega Drive synthesis probe: console RTL from
  [nand2mario/mdtang](https://github.com/nand2mario/mdtang), derived from
  Genesis-MiSTer; original headers and licenses are preserved in `rtl/mdtang/`.
* Game Boy / Game Boy Color core: GBCandy Nano by kuangyl0212 (GPLv3, derived
  from VerilogBoy by Wenting Zhang), ported under `rtl/gbc/` with its license.
  The former DMG-only VerilogBoy sources remain under `rtl/gb/` (OHDL-1.0).
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
