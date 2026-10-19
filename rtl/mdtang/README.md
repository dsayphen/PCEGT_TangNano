
# MDTang - MegaDrive/Genesis for Sipeed Tang FPGA boards

<img src='doc/mdtang-0.1.jpg' width="300" />

This is a port of the [Genesis-MiSTer](https://github.com/MiSTer-devel/Genesis_MiSTer) core to Sipeed FPGA boards including Tang Mega 60K, 138K and 138K Pro.

This is a mostly verbatim port. The board integration adds selectable
NTSC US / NTSC Japan regional I/O flags from the browser's **Options > Region**
setting (PAL is not offered). Audio filters and persistent cartridge saves are not available.

MDTang is part of [TangCore](https://github.com/nand2mario/tangcore), along with  [NESTang](https://github.com/nand2mario/nestang), [SNESTang](https://github.com/nand2mario/snestang), [GBATang](https://github.com/nand2mario/gbatang) and [SMSTang](https://github.com/nand2mario/smstang).

## Instructions

To install MDTang, follow the [TangCore](https://github.com/nand2mario/tangcore) installation instructions**.

## Documentation

* [Blast Processing on the Tang FPGA boards](https://nand2mario.github.io/posts/2024/mdtang/)

## Acknowledgements
* [Genesis-MiSTer core](https://github.com/MiSTer-devel/Genesis_MiSTer)

## Nano 20K synthesis probe

This directory vendors the console RTL and its memory initialization files
from upstream commit `903d30cbd92cf03bc31cd55f925d8985e3225f1e`.
Board wrappers, HDMI, loaders and upstream build projects are not imported.
The original source headers and licenses are retained.

From the repository root, run:

```powershell
& .\tools\build_megadrive_probe.ps1
```

The probe targets `GW2AR-LV18QN88C8/I7` and synthesizes the console with
68000, Z80, VDP, PSG and FM audio enabled, NTSC/export region, no audio
low-pass filtering, no multitap, mouse, lightgun or optional cartridge quirks.
CPU, memory, joypad, video and audio signals cross the probe boundary to
prevent synthesis from removing the console as unused logic.

This is a resource measurement, **not a playable Nano 20K port**. Its ports
are not physical board pins. ROM, 68000 work RAM and cartridge RAM remain
behind the upstream external-memory request/acknowledge interface. The
SDRAM controller, ROM loader, PicoRV32 firmware, browser, OSD, clock PLLs,
video scaling, HDMI and I2S are not included in the measurement. Existing
profiles and the flash layout are unchanged. No bitstream is generated.

Results go to `impl/profile-build/megadrive-probe/impl/gwsynthesis/`.
Synthesis alone does not establish place-and-route feasibility, timing
closure, correct memory initialization or game compatibility.

### Local changes and measured limits

* `fx68k.sv`: request BSRAM for the microcode and nanocode ROMs.
* `fx68k.sv` and `fx68k/fx68k_regfile.sv`: registers 0-15 of each 16-bit
  half live in Gowin LUT RAM (one asynchronous copy per read port), and
  registers 16-17 stay in flip-flops. The two write destinations are
  serialized: X is written on `enT3` and Y one MCLK later, which keeps the
  per-byte Y-over-X priority. fx68k only samples the register outputs on
  `enT1`, which is at least two MCLKs after `enT3` (including reset and turbo
  enables), so the CPU cannot observe the extra clock. Reads remain
  asynchronous; simulation-only zero initialization and hardware power-up
  semantics are preserved. No instruction or emulated clock phase is removed.
* `system.sv`: align `MEM_REQ` to `MEM_ACK` and clear `MEM_WE` during
  console reset, preventing an uninitialized or abandoned toggle from
  becoming a phantom request when the local SDRAM adapter is enabled.
* `common/dpram.v`: explicitly map large RAMs to BSRAM and small RAMs
  to distributed memory.
* `common/dpram_block.v`: implement tables with up to 64 entries using
  distributed RAM instead of dedicating a whole BSRAM to each one. Zero power-up
  contents, synchronous read latency and output hold during writes match
  the original Gowin DPB's defaults.
* `common/md_sdp_ram.sv` and `vdp/vdp.v`: use single-writer distributed RAM
  for the four 512x8 line/color tables and the 128x32 sprite cache. Preserve
  synchronous read latency, zero power-up contents and the cache's four
  byte enables; the unused writer-side read outputs are not implemented.
* `jt12/jt12_sh.v` and `jt12/jt12_sh_rst.v`: explicitly keep shift storage
  in registers using `syn_srlstyle`. The existing initialization and
  clock-enable behavior are unchanged.
* `jt12/jt12_logsin.v` and `jt12/jt12_exprom.v`: explicitly map lookup ROMs
  to two BSRAM blocks. The earlier BSRAM-only experiment used logic ROMs;
  menu integration needs the logic savings more than those two free blocks.

With Gowin V1.9.11.03 Education, targeting the actual Nano 20K device,
the synthesis probes use:

| Resource | Initial passing probe | Current console | Console + SDRAM | Console + SDRAM + IOSys | Available |
| --- | ---: | ---: | ---: | ---: | ---: |
| Logic (LUT/ALU/distributed RAM total) | 17,317 | 16,459 | 16,897 | 19,222 | 20,736 |
| Registers | 10,082 | 8,785 | 8,996 | 10,142 | 15,750 |
| BSRAM | 46 | 43 | 43 | 45 | 46 |

The earlier BSRAM-only optimization measured 18,313 logic units and 41 BSRAM;
the subsequent SDRAM probe measured 18,554 logic units and 41 BSRAM.
Those are historical results, not the current source configuration.
The current console uses 11,845 LUTs, 1,908 ALUs and 451 RAM16 units;
console + SDRAM uses 12,273 LUTs, 1,918 ALUs and 451 RAM16 units;
the menu probe uses 14,126 LUTs, 2,198 ALUs and 483 RAM16 units.
The VDP line tables and cache no longer use BSRAM. The remaining
43 console blocks comprise 32 for full 64 KiB VRAM, four for Z80 work RAM, four
under the 68000 hierarchy (including its microcode/nanocode), and one under
the Z80 CPU hierarchy, plus two FM lookup ROMs. IOSys adds two blocks
for the character plane and font.

The unadapted source hit inference/resource errors. Explicit memory mapping
allowed synthesis to complete without removing the CPUs, VDP or audio.
**The menu probe leaves one BSRAM block and 1,514 logic units unused.**
This is about 7% logic headroom, not proof that the remaining video/audio
pipeline will fit or meet timing. No console feature has deliberately
been removed to obtain this result. The SDC specifies approximately 53.693 MHz
and half that rate for Z80; it does not implement or validate the board's
PLL, generated-clock relationships or physical timing.

Run the focused memory regression with:

```powershell
& .\sim\run_megadrive_probe.ps1
```

It requires Icarus Verilog and Gowin's installed GW2A simulation library
(not copied into this repository). Six address/data-width combinations,
including both sides of the 64-entry mapping boundary, are compared
against the vendor DPB model for power-up contents, synchronous reads,
both write ports and output hold during writes. A second bench compares
the single-writer 512x8 tables in both writer-port orientations and the
128x32 cache against the original wrappers and an independent scoreboard,
with shared and independent clocks. It covers every address at power-up,
all 16 cache byte masks, full writes, randomized writes/stalls and a final
full readback. It also sweeps both FM lookup tables and tests lookup/shift
latency and clock enables. The upstream `jt12_sh_rst` ignores runtime reset;
the test preserves that behavior rather than adding reset functionality.
Same-address simultaneous
access is excluded because its collision behavior is not guaranteed.
This is not a simulation of the entire console.

## Nano 20K SDRAM adaptation

Run the additional console + SDRAM synthesis with:

```powershell
& .\tools\build_megadrive_probe.ps1 -WithSdram
& .\sim\run_megadrive_probe.ps1
```

[The adapter](../tang/megadrive_sdram.sv) reuses the repository's
[x32 Nano SDRAM engine](../tang/sdram.v), rather than the upstream x16
board controller. [The integrated probe](../tang/megadrive_sdram_probe.sv)
connects the console's real `MEM_*` bus to it. Output files are isolated in
`impl/profile-build/megadrive-sdram-probe/impl/gwsynthesis/`.
No existing profile or flash slot changes.

### Address layout and byte order

All addresses in this table are **byte addresses**, not the core's
`[24:1]` word addresses.

| Console external bus | Physical SDRAM | Purpose |
| --- | --- | --- |
| `000000-5FFFFF` | `000000-5FFFFF` | Up to 6 MiB ROM / writable cartridge space |
| `800000-80FFFF` | `600000-60FFFF` | 64 KiB 68000 work RAM |
| `820000-83FFFF` | `620000-63FFFF` | 128 KiB cartridge RAM |
| No console mapping | `610000-61FFFF`, `640000-7FFFFF` | Reserved for future host use |

The console's CPU-side work RAM mirrors are already decoded by upstream
`system.sv` before reaching this bus. The adapter preserves the upstream
cartridge-RAM address width. Unsupported external addresses complete with
`FFFF` on reads, discard writes and set the sticky `address_fault` output,
cleared only by SDRAM reset. They never alias ROM or reserved host memory.
The integrated probe additionally reports ROM sizes above 6 MiB through
`address_fault` and holds the console in reset. `rom_size` retains the
upstream word-count convention (6 MiB = `24'h300000`).

The host port uses physical, aligned 32-bit words (`host_addr[22:2]`) with
little-endian byte lanes and four active-high byte enables. Raw ROM bytes
`12 34 56 78` must be packed as `host_wdata = 32'h78563412` at address zero.
The console then reads `1234` at byte address zero and `5678` at address two.
The adapter swaps both data bytes and enables for the big-endian console;
`mem_be[1]` controls the byte at the lower byte address. No byte swap is
applied to host accesses.

### Clocks, requests and reset

* The console memory bus, host port and controller all run synchronously on
  `mclk` (53.693175 MHz nominal NTSC). There is **no CDC bridge**. Future
  firmware on a different clock must use a proper handshake bridge.
* `clk_sdram` must be the same frequency, shifted 180 degrees. The engine's
  existing CAS2 timing is used below its documented 66.7 MHz maximum.
  The probe does not generate PLL clocks or validate SDRAM I/O timing.
* Each client holds address, write data, enables and write direction stable,
  toggles its request, then waits for acknowledgement to match the request.
  Only one outstanding request per client is supported. Acknowledgement
  follows completion, and read data remains registered until a later read.
* Arbitration alternates between pending console and host transactions.
  Refresh takes priority at the next idle slot, nominally every 7.14 us,
  independently of video blanking and whether either client is active.
* The 200 us power-up sequence runs before `init_done`. The integrated
  probe holds the console in reset during initialization and `loading`.
  Disabling console requests does not abort a transaction already accepted.
* Controller reset is a board/power reset, not the game-loading reset.
  On controller reset the host must also reset its request toggle to zero.
  On game reload, leave the controller running and drain pending host
  transactions before releasing `loading`.
* SDRAM contents are not initialized by this adapter. The future loader
  must initialize work/cartridge RAM and finish ROM writes before releasing
  the console; cartridge persistence and file loading are not implemented.

### Validation and remaining limits

[The SDRAM regression](../../sim/tb_megadrive_sdram.sv) uses the existing
8 MiB memory model with a one-cycle read-data window. It monitors command
pins for power-up delay, precharge/refresh/mode initialization, CAS2/burst-1
mode, activate/column/recovery timing and refresh intervals below 7.8125 us.
It tests queued power-up requests, both halfwords, every console/host byte
mask, all physical banks, retained data across rows, mapping boundaries,
fault/no-alias behavior, disabled console requests, concurrent clients,
idle/contended refresh and reset during an outstanding read. The measured
maximum console request latency in that test is 20 master clocks
(about 373 ns), including host contention and refresh; this is not a
whole-console throughput or game-compatibility guarantee.

Console + SDRAM synthesis leaves **3,839 logic units and three BSRAM blocks**
free, without a new BSRAM cache. The actual ROM loader, PicoRV32/browser/OSD,
clock PLLs, video scaling, HDMI and I2S remain excluded. There is no
place-and-route result, full-console simulation, board test or flashable
bitstream yet.

## IOSys / loader integration resource probe

```powershell
& .\tools\build_megadrive_probe.ps1 -WithMenu
& .\sim\run_megadrive_probe.ps1
```

`-WithMenu` already includes SDRAM and cannot be combined with `-WithSdram`.
It synthesizes [the menu boundary](../tang/megadrive_menu_probe.sv), including
the real IOSys/PicoRV32, OSD, SPI SD and flash hardware and
[the host bridge](../tang/megadrive_host_bridge.sv). It does **not** run
the firmware or provide a playable board build. The output directory is
`impl/profile-build/megadrive-menu-probe/impl/gwsynthesis/`.

### Integration layout and handshake

The original standalone SDRAM probe retains its original layout above.
The menu probe relocates console RAM through `WORK_RAM_BASE` and
`CART_RAM_BASE` parameters so the existing 1664 KiB firmware linker window
can remain unchanged:

| Physical SDRAM | Menu-probe owner |
| --- | --- |
| `000000-5FFFFF` | ROM loader / console ROM |
| `600000-79FFFF` | IOSys firmware/data/stack (`RV_BASE=600000`) |
| `7A0000-7AFFFF` | Console work RAM (`800000-80FFFF` on the external console bus) |
| `7B0000-7BFFFF` | Reserved |
| `7C0000-7DFFFF` | Cartridge RAM (`820000-83FFFF` on the external console bus) |
| `7E0000-7FFFFF` | Reserved |

The host bridge accepts IOSys's level-based x32 firmware requests and
byte-stream loader pulses, then holds the selected transaction stable
until the SDRAM toggle acknowledgement arrives. Firmware requests are not
issued twice when `rv_valid` stays high. Loader writes use one pending byte
with `ld_busy` backpressure; `ld_idle` does not assert before queued writes
and RAM initialization have drained. Firmware and loader/clear accesses
alternate when both need service.

On each rising `loading`, the bridge clears all 64 KiB of work RAM to zero
and initializes all 128 KiB of cartridge RAM to `FF`, without touching
firmware, reserved space or ROM. It accepts one early loader pulse on
that same edge, stalls later loader bytes, and continues servicing firmware
while initialization runs. A pending-byte overflow, a load restart during
an active clear/loader transaction, or a ROM write at/above 6 MiB sets a
sticky `protocol_fault` and holds the console in reset. Normal game reset
resets the console separately, not the SDRAM or loader state, and does not
assert the VRAM-clearing `LOADING` input.

The menu probe maps SNES pad input to Mega Drive order: Y/B/A become A/B/C,
X/L/R become X/Y/Z, Select becomes Mode, and Start/directions are preserved.
The OSD masks game inputs while active. The RTL/firmware core id is 6.
ROM length
is inferred from sequential loader addresses (including the loader's final
word padding). Firmware validates raw ROM headers and supports menu/profile
selection. Cartridge quirks and save-file persistence remain unimplemented.

### Optimization and validation

The first menu probe exceeded the target at 21,198 logic units. Mapping
the FM lookup tables to BSRAM reduced that to 20,587. Explicit 68000 register
write decoding then reduced an otherwise equivalent probe to 19,565;
an attempted one-hot read mux was larger (19,676) and was not retained.
The final pad masking/reset wiring measures **19,222 logic, 10,142 registers
and 45 BSRAM** on the exact Nano 20K part. These are synthesis-only results.

The regression runner now executes ten cases (nine benches, including both
one- and four-sample HDMI packet configurations). In addition to the
earlier RAM/FM/SDRAM checks:

* [The host regression](../../sim/tb_megadrive_host.sv) checks firmware read/write
  masks, held-valid requests, loader byte order, all 49,152 initialized RAM
  words, an early loader pulse, firmware access during clearing, reload
  after dirty RAM, bounded firmware progress during clearing, out-of-range
  loader faults without firmware aliasing, fault reset and pending-byte
  overflow reporting.
* [The register-file regression](../../sim/tb_fx68k_regfile.sv) compares the
  new storage against original-style indexed writes for every register
  pair and all byte-mask pairs (5,184 cases), out-of-range destinations,
  then 20,000 randomized writes. Each write is followed by one idle clock
  with randomized inputs, as on the CPU. It checks all 18 registers and both
  LUT-RAM copies, same-register Y priority, partial-byte preservation and
  asynchronous reads, and fails if a write arrives on the clock right after
  a Y write.

The register-file test is component-level equivalence, **not** an instruction
suite or full-console/game simulation. The menu probe excludes board
interfaces; use the separate experimental board build below.

### Experimental Nano 20K board build

```powershell
& .\tools\build_profiles.ps1 -Profile megadrive
& .\sim\run_megadrive_probe.ps1
```

The board top is [top_tang_nano20k_megadrive.sv](../top_tang_nano20k_megadrive.sv).
It reuses the Nano pin constraints and adds
[Mega Drive timing constraints](../../constraints/megadrive_nano20k.sdc).
The build uses an isolated project under `impl/profile-build/megadrive-board`,
with exports under `impl/profiles/megadrive/pnr`. It checks that both bitstream
formats exist, the binary fits its 1 MiB slot, and setup/hold violations are
zero before exporting. Nothing is flashed automatically.

The completed Gowin V1.9.11.03 Education route reports **19,593 / 20,736
logic units** (including 507 RAM16), **10,179 / 15,552 fabric flip-flops**,
**10,158 / 10,368 CLS**, **46 / 46 BSRAM**, **2.5 / 24 DSP** and both rPLLs.
Setup and hold violated endpoint counts are both zero; worst setup slack is
+0.136 ns, worst hold slack is +0.074 ns, and minimum serializer-reset
recovery slack is +0.445 ns. Master-clock Fmax is 54.136 MHz against the
53.740 MHz target. The generated raw binary is 907,418 bytes. These results
apply to the board build; the earlier resource-only measurements predate
its timing changes.

The serializer reset synchronizer is two-stage with asynchronous assertion
and synchronous release. Its recovery timing closes with a generated physical
constraint routing `clk_serial` through a BUFS clock spine. Gowin warns that
this clock uses generic routing and may have excessive delay/skew; serializer
and reset behavior therefore still need hardware validation.

Build shared firmware with `firmware/build.ps1` (`firmware.bin`,
flash offset `0x500000`). Package the MD raw binary with
`tools/prepare_core_slots.ps1 -MegaDriveOnly`; this generates a 1 MiB
`impl/core-slots/megadrive_slot.bin` with the firmware-compatible CRC32
manifest at slot offset `0xFFFE0`. Program that slot only at `0x600000`
on a flash device of at least 8 MiB. The script does not program anything,
does not include other cores, and deliberately cannot produce a combined
image crossing the firmware slot.

The video PLL makes a 155.25 MHz serializer clock (27 MHz x 23/4) and a
31.05 MHz pixel clock. A second PLL, fed by the serializer clock, multiplies
it by 9/26 for the 53.740 MHz console clock, the 225-degree-shifted SDRAM
clock and the 26.87 MHz Z80 interface clock. The console runs 0.09% faster
than nominal NTSC (53.693 MHz), and HDMI frames run at 59.975 Hz (real
hardware: 59.92 Hz). The scaler and HDMI transmitter are reset only by the
video PLL lock, so the output keeps a signal through console resets. External
SDRAM constraints budget 5.5 ns maximum clock-to-data and 2/1 ns setup/hold;
these assumptions must be checked against the fitted memory and hardware.
They do not substitute for signal-integrity or hardware validation.
The adapter captures SDRAM pins before its endian/halfword mux, keeping
the mux off the input timing path. The console-wide reset is registered
so the ROM size check is not on its high-fanout combinational path.
The board constraints allow two MCLK periods only between the JT12 channel/
operator-counter and LFO Q pins and phase-increment D pins (all share
`clk_en`, at least 14 MCLKs apart), and between the 68000 CCR feedback
registers (all capture on `enT3`, a subset of the seven-MCLK `enPhi1` cadence).
Matching one-cycle hold adjustments preserve the original hold requirement.
These are endpoint-specific enable contracts, not blanket CPU/audio timing
exceptions; revisit them if enabling turbo or changing clock enables.
MCLK logic never reads the T80 address or MREQ/RD/WR/BUSAK outputs
directly: `system.sv` copies them into MCLK shadow registers that skip the
MCLK edges following a Z80 clock-enable edge or a Z80 reset change. The T80
data output is not shadowed. It only changes on the clock-enable edge that
asserts WR (`T2Write=1`) and is held while WAIT stalls T2, so `MBUS_DO`/`ZBUS_DO`
only capture it after the shadowed write request is seen. Only `clk_z80` paths
into those shadows and data registers get two MCLK periods
(`tb_megadrive_z80_shadow` checks this rule). Z80 bus decoding therefore
sees the bus two or three MCLKs later than upstream, still well inside the
15-MCLK Z80 cycle.
The Mega Drive MBUS idle-data preload optimization is retained. Asynchronous
assertion into the serializer reset synchronizer is excluded, but its
synchronized output to OSER10 remains timed.

[megadrive_video.sv](../tang/megadrive_video.sv) uses one BSRAM for two
512x12-bit lines. A toggle synchronizer publishes a stable completed bank
and line metadata to the pixel domain. Each source line occupies two
fixed 988-pixel output lines: the pixel/console clock ratio is exactly
494/855, so one 3420-MCLK line lasts 1976 pixel clocks. The raster free-runs (also as the menu raster when
console video is absent); a console line normally arrives 12 pixels before
a pair starts and is applied at that boundary. Events outside a 24-pixel
window resynchronize the raster once. VBL is sampled at the horizontal line boundary, so
a mid-line frame transition cannot leave a partial first or last captured
row. First active lines realign the frame; measured 262/263 NTSC and 312/313
PAL source-line cadence selects a 524/526 or 624/626-line output frame. The
640x480 active window displays H40 at 2x, H32 centered at 2x or stretched,
and 224/240 lines at 2x. V28 content starts at output row 16, leaving exactly
16 black rows above and below; V30 starts at row 0 and fills 480 rows.
This changes raster phase rather than delaying an image in a frame buffer.
The OSD stays centered in the full output raster. A repeat counter generates
2x or 5:2 nearest-neighbor pixels without a fractional coordinate adder.
The OSD and
visible-pixel timing use matching pipelines. Scanline attenuation preserves
the VDP's four-bit RGB/shadow/highlight output.

Video is DVI-compatible when **Audio Settings > Output** selects **Speaker**.
Select **HDMI** in the browser's audio menu to enable stereo PCM and mute
the on-board amplifier. A shared volume-only DSP stage feeds both outputs.
I2S retains its 46.875 kHz clock; HDMI has its own exact 48 kHz sampler,
using 1119/1120 master clocks per sample at 53.740 MHz. The shared
sampler's default 43.2 MHz behavior is unchanged.

The HDMI transmitter uses the actual 988-pixel, zero-origin raster rather
than PCE's rebased 819-pixel timing. Audio islands occupy x=654..781,
and video preambles/guards x=978..987 precede the next active line,
including the last-frame-line to row-0 transition. One stereo sample per
audio packet (rather than four) reduces register/mux pressure without
lowering sample rate or bit depth; four packet slots per line provide
enough bandwidth at 48 kHz without adding BSRAM. A 15-bit cycle counter
covers the 31,050-pixel-clock ACR interval. Other profiles retain four-sample
packets and their original geometry.

Packet-bank ownership now lasts until the last transmitted pixel, avoiding
read-bank toggles selecting unwritten data or the producer overwriting an
in-flight sample. The first ACR measurement starts at the first sampled
audio edge, not reset, so it measures 48 complete sample intervals.
Firmware hides equalizer and bilinear controls for this profile.
The optional serializer
reset synchronization in the shared DVI transmitter defaults off for
existing profiles, and is enabled here.

Raw `.md`/`.gen`/`.bin` loading requires the `SEGA` signature at `0x100`
and at most 6 MiB; byte order is unchanged and the tail is padded with FF
to a four-byte boundary. `.smd` is rejected. Firmware uses `/megadrive`,
core ID 6 and optional flash slot `0x600000`; the firmware remains at
`0x500000`. Reconfiguration requires a valid installed-image manifest.

The 12 focused Mega Drive simulation runs pass, including RAM/DPB behavior,
SDRAM and loader handshakes, timing-enable contracts, video/HDMI behavior,
register-file and FM equivalence. The firmware/browser loader test also
passes for the current audio-output menu/register behavior. The video benches
check H40 width, H32 integer centering/stretch, exact
colored-pixel repeat patterns, overlay, reset and complete centered frames
in both V28/V30 and 262/263-line modes, with one startup resynchronization
and an exact 262 x 1976-pixel NTSC frame period. The HDMI regression runs both
one- and four-sample packets, checking 1,000 stereo samples for ordering/
loss, IEC block-start flags/sample parity, independent BCH parity, ACR
intervals, audio/AVI infoframes, video/island geometry, 48 kHz sample cadence,
the unchanged default sampler and DVI fallback.
A separate FM test checks 128,000 binary-valued combinations of
the factored channel-3 frequency selector against its original AND/OR
implementation; this shortens the channel-select path without adding
audio pipeline latency or changing the FM clock enables.
The user confirmed the centered HDMI-audio board build works. The latest
line-alignment and region-selector changes still need hardware/game/receiver
validation. The 59.975 Hz 988x524 output and the cascaded PLLs remain
unvalidated on hardware and receivers. Interlace, cartridge-specific
hardware, save persistence and a second
physical controller are outside this initial profile.
