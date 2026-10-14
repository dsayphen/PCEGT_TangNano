# SNESTang Sources

Source: https://github.com/nand2mario/snestang

Revision: `5f0ef193145f67bded7f73f2c477ac8da4d85f7e`.
The upstream license is preserved in `LICENSE`; source notices are retained.

Only the SNES core, memory controller, controller adapter and video/audio
dependencies are enabled by the `snes` build profile. The upstream board top
and BL616 IOSys are not instantiated. The PCE project's PicoRV32 firmware,
SD browser, OSD, save services and flash core switching are shared.

Local change in `src/sdram_nano.v`: optional `SHARED_IOSYS` addressing places
firmware RAM at 0x400000, ARAM at 0x5A0000 and the host SRAM window at 0x5E0000.
Request acknowledgements are reset explicitly.

The ROM header heuristics in `firmware/rom.c` are adapted from the upstream
PicoRV32 firmware at tag `v0.7` (GPLv3).

Current limits: NTSC 720p integer scaling, one SNES pad, LoROM/HiROM up to
3.75 MiB, 128 KiB SRAM maximum. ExHiROM, Super FX, SA-1, CX4, S-DD1,
SPC7110 and ST01x are rejected. Hardware gameplay and audio remain unverified.