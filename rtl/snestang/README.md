# SNESTang Sources

Source: https://github.com/nand2mario/snestang

Revision: `5f0ef193145f67bded7f73f2c477ac8da4d85f7e`.
The upstream license is preserved in `LICENSE`; source notices are retained.

Only the SNES core, memory controller, controller adapter and video/audio
dependencies are enabled by the `snes` build profile. The upstream board top
and BL616 IOSys are not instantiated. The PCE project's PicoRV32 firmware,
SD browser, OSD, save services and flash core switching are shared.

The normal profile enables `UPSTREAM_RAM_LAYOUT`: WRAM and SRAM use the
original ROM-side channel at 0x3E0000 and 0x3C0000. Firmware RAM remains at
0x400000 and ARAM at 0x5A0000; the firmware's save window is redirected to SRAM.
The CPU response selector is captured at transaction acceptance.
The board wrapper enables `SPLIT_WRAM`: ROM and WRAM requests have independent
payloads and acknowledgements, so a simultaneous DMA read/write cannot replace
the ROM request while marking its source address as already fetched.
Audio requests retain priority on the shared RAM channel: the APU does not
receive a wait/ready handshake. An alternating WRAM/audio experiment caused
a hardware black-screen/no-audio regression and was removed.
Request acknowledgements are reset explicitly.
VRAM request toggles and payloads are held until acknowledgement; each port
retains a pending write if it arrives behind a read. The real-wrapper stream
bench covers read/write transitions and successive PPU reads at 4:1 clocks.
The HDMI PLL now produces
126 MHz (25.2 MHz pixel clock); rtl/tang/snes_video_640.sv replaces the upstream
720p converter with 640x480 integer/stretch/bilinear scaling and a banked
24-line buffer. The OSD character plane uses distributed RAM to leave room
for the larger buffer. Bilinear interpolation uses weights 0, 1/2 and 1 on
each axis to fit the FPGA without reducing the buffer depth.

The in-game menu requests a full-frame pause through game-control bit 2
(together with pause bit 0). Readback bit 8 acknowledges that capture and
prefill have completed; firmware waits for this before saving SRAM. Ordinary
pause requests still halt immediately, including save restoration at ROM load.
The snapshot occupies 112 KiB at physical SDRAM 0x600000..0x61BFFF, below the
optional video-bank WRAM at 0x620000 and VRAM at 0x7F0000. Its low-priority
port uses spare VRAM-channel slots and yields to refresh. During capture the
PPU waits for each pixel write; after capture it stops in VBlank. On playback,
two rows are prefetched and subsequent rows refill the existing 24-line buffer
two lines ahead of scanout. Zoom changes latch during HDMI VBlank so refill
order stays intact. No additional BSRAM is needed. Capture temporarily blanks
the game background but leaves the OSD and HDMI timing active.
The integrated `tb_snes_pause_frame` bench checks the full SDRAM image and
displayed pixels in all three zoom modes, cancellation, resume, reset and
SDRAM refresh during capture. Hardware validation is still required.

The SDRAM scheduler realigns its 2-mclk slot ring on each `dot_clk_ce`
(clkref) edge, and that pulse only advances while ENABLE is high. An odd-length
stall therefore moved the edge by half a slot and corrupted in-flight SDRAM
accesses: per-pixel capture stalls crashed the 65816 while the SPC700 kept
playing. The top now extends every ENABLE stall to an even number of mclk
cycles, and the pause bench uses the hardware clkref phase and fails on any
mid-slot realignment.

The pause capture made the profile exceed placement capacity. The SNES top
therefore sets `UART_ENABLE=0` in IOSys (UART writes complete without output;
`RV_DIAGNOSTIC` still forces the UART) and `TONE_ENABLE=0` in `audio_tone`
(master volume only); the firmware hides Bass/Treble for this profile.
Gowin 1.9.11.03 result: Logic 20379/20736, CLS 10343/10368, registers 7209,
BSRAM 46/46; fclk 86.5/86.4 MHz, mclk 22.1/21.6 MHz, hclk 40.5/25.2 MHz (TNS 0).

The ROM header heuristics in `firmware/rom.c` are adapted from the upstream
PicoRV32 firmware at tag `v0.7` (GPLv3).

Current limits: NTSC, one SNES pad, LoROM/HiROM up to 3.75 MiB (3,932,160 bytes),
128 KiB SRAM maximum. ExHiROM, Super FX, SA-1, CX4, S-DD1, SPC7110 and ST01x
are rejected. Audio worked in the previous profile; graphics fixes and VGA
output require hardware retesting.

`-SnesSdramPhase180` builds a separate hardware-only timing diagnostic, changing
the SDRAM PLL phase from `1010` (225 degrees) to `1000` (180 degrees).
The normal default and combined flash images are unchanged. A full internal-VRAM
diagnostic was attempted but exceeded BSRAM capacity; that option was removed
without changing CPU microcode or removing the audio processor.

The PPU pixel divider now holds while ENABLE is low, matching the CPU dot-clock
reference used by the SDRAM scheduler. Previously a pause could shift their
relative phase and make a background fetch consume the preceding VRAM result.
A focused wrapper test models both dividers and checks sampling after odd/even
pause durations. VRAM_READ_CE is also exposed through PPU/SNES/main as a passive
timing observation for the optional UART diagnostic.

The upstream RAM layout was confirmed on hardware with Super Mario World
(USA). The new video buffer and simplified filter still need hardware testing.
The live-stream test reproduced old-line overwrite at
VGA line 347 with the previous 16-line buffer and passes with 24 lines.
It also covers alternating PPU fields and the visible-line counter holding
during vertical blanking; buffer addressing ignores the FIELD bit in Y_OUT.
The SNES flash source slot is 0x300000; its internal profile ID remains 4.