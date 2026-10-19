# Builds and runs the simulation test benches with Icarus Verilog.
#
#   pwsh sim/run.ps1
#
# Requires iverilog on PATH (or set $env:IVERILOG_BIN to its bin directory)
# and, for tb_iosys, the RISC-V toolchain used by firmware/build.ps1.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Find-Tool([string]$name, [string[]]$extra) {
    $c = Get-Command $name -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($d in $extra) {
        $p = Join-Path $d $name
        if (Test-Path $p) { return $p }
        if (Test-Path "$p.exe") { return "$p.exe" }
    }
    throw "$name not found"
}

$ivdirs = @($env:IVERILOG_BIN, 'C:\iverilog\bin', 'C:\Program Files\iverilog\bin') | Where-Object { $_ }
$iverilog = Find-Tool 'iverilog' $ivdirs
$vvp      = Find-Tool 'vvp' $ivdirs
Write-Host "iverilog: $iverilog"

function Find-RiscvPrefix {
    if ($env:RISCV_PREFIX) { return $env:RISCV_PREFIX }
    $cmd = Get-Command 'riscv-none-elf-gcc' -ErrorAction SilentlyContinue
    if ($cmd) { return 'riscv-none-elf-' }
    foreach ($r in @("$env:USERPROFILE\opt", 'C:\opt', 'D:\opt')) {
        if (-not (Test-Path $r)) { continue }
        $hit = Get-ChildItem $r -Recurse -Filter 'riscv-none-elf-gcc.exe' -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($hit) { return ($hit.FullName -replace 'gcc\.exe$', '') }
    }
    return $null
}

$fails = @()

# ---------------------------------------------------------------------------
# tb_iosys needs a RISC-V program in the flash model
# ---------------------------------------------------------------------------
$CROSS = Find-RiscvPrefix
if ($CROSS) {
    Write-Host "toolchain: $CROSS"
    Push-Location sim
    try {
        & "${CROSS}gcc" -x assembler-with-cpp -mabi=ilp32 -march=rv32i -c -o start.o ../firmware/start.S
        if ($LASTEXITCODE) { throw 'assembling core_autorun_test startup failed' }
        & "${CROSS}gcc" -Os -mabi=ilp32 -march=rv32i -ffreestanding -fno-builtin -ffunction-sections -fdata-sections `
            -Dload_rom=unused_load_rom -c -o core_rom_filter.o ../firmware/rom.c
        if ($LASTEXITCODE) { throw 'compiling core_autorun_test ROM filters failed' }
        & "${CROSS}gcc" -Os -mabi=ilp32 -march=rv32i -ffreestanding -fno-builtin -ffunction-sections -fdata-sections `
            '-Wl,--gc-sections,--build-id=none,-T,../firmware/baremetal.ld' -nostdlib `
            -o core_autorun_test.elf start.o core_autorun_test.c ../firmware/picorv32.c core_rom_filter.o -lgcc
        if ($LASTEXITCODE) { throw 'compiling core_autorun_test failed' }
        & "${CROSS}objcopy" core_autorun_test.elf core_autorun_test.bin -O binary
        if ($LASTEXITCODE) { throw 'objcopy core_autorun_test failed' }
    } finally {
        Pop-Location
    }
    python tools/bin2hex.py sim/core_autorun_test.bin sim/core_autorun_test.hex 131072
    & $iverilog -g2005-sv -s tb_core_autorun -o sim/tb_core_autorun.vvp sim/tb_core_autorun.v rtl/tang/iosys/picorv32.v
    if ($LASTEXITCODE) { throw 'iverilog core_autorun_test failed' }
    & $vvp sim/tb_core_autorun.vvp
    if ($LASTEXITCODE) { throw 'core_autorun_test failed' }
    Push-Location sim
    try {
        & "${CROSS}gcc" -Os -mabi=ilp32 -march=rv32i -ffreestanding -fno-builtin -ffunction-sections -fdata-sections `
            '-Wl,--gc-sections,--build-id=none,-T,../firmware/baremetal.ld' -nostdlib `
            -o nintendo_video_settings_test.elf start.o nintendo_video_settings_test.c `
            ../firmware/util.c ../firmware/picorv32.c core_rom_filter.o -lgcc
        if ($LASTEXITCODE) { throw 'compiling nintendo_video_settings_test failed' }
        & "${CROSS}objcopy" nintendo_video_settings_test.elf nintendo_video_settings_test.bin -O binary
        if ($LASTEXITCODE) { throw 'objcopy nintendo_video_settings_test failed' }
    } finally {
        Pop-Location
    }
    python tools/bin2hex.py sim/nintendo_video_settings_test.bin sim/nintendo_video_settings_test.hex 131072
    if ($LASTEXITCODE) { throw 'converting nintendo_video_settings_test failed' }
    & $vvp sim/tb_core_autorun.vvp '+IMAGE=sim/nintendo_video_settings_test.hex'
    if ($LASTEXITCODE) { throw 'nintendo_video_settings_test failed' }
    Push-Location sim
    try {
        & "${CROSS}gcc" -Os -mabi=ilp32 -march=rv32i -ffreestanding -fno-builtin -ffunction-sections -fdata-sections `
            '-Wl,--gc-sections,--build-id=none,-T,../firmware/baremetal.ld' -nostdlib `
            -o nintendo_loader_test.elf start.o nintendo_loader_test.c `
            ../firmware/util.c ../firmware/picorv32.c -lgcc
        if ($LASTEXITCODE) { throw 'compiling nintendo_loader_test failed' }
        & "${CROSS}objcopy" nintendo_loader_test.elf nintendo_loader_test.bin -O binary
        if ($LASTEXITCODE) { throw 'objcopy nintendo_loader_test failed' }
    } finally {
        Pop-Location
    }
    python tools/bin2hex.py sim/nintendo_loader_test.bin sim/nintendo_loader_test.hex 131072
    if ($LASTEXITCODE) { throw 'converting nintendo_loader_test failed' }
    & $vvp sim/tb_core_autorun.vvp '+IMAGE=sim/nintendo_loader_test.hex'
    if ($LASTEXITCODE) { throw 'nintendo_loader_test failed' }
    Push-Location sim
    try {
        & "${CROSS}gcc" -Os -mabi=ilp32 -march=rv32i -ffreestanding -fno-builtin -ffunction-sections -fdata-sections `
            '-Wl,--gc-sections,--build-id=none,-T,../firmware/baremetal.ld' -nostdlib `
            -o snes_loader_test.elf start.o snes_loader_test.c ../firmware/picorv32.c -lgcc
        if ($LASTEXITCODE) { throw 'compiling snes_loader_test failed' }
        & "${CROSS}objcopy" snes_loader_test.elf snes_loader_test.bin -O binary
        if ($LASTEXITCODE) { throw 'objcopy snes_loader_test failed' }
    } finally {
        Pop-Location
    }
    python tools/bin2hex.py sim/snes_loader_test.bin sim/snes_loader_test.hex 131072
    if ($LASTEXITCODE) { throw 'converting snes_loader_test failed' }
    & $iverilog -g2005-sv -s tb_core_autorun '-Ptb_core_autorun.MAX_CYCLES=40000000' `
        -o sim/tb_snes_loader.vvp sim/tb_core_autorun.v rtl/tang/iosys/picorv32.v
    if ($LASTEXITCODE) { throw 'iverilog snes_loader_test failed' }
    & $vvp sim/tb_snes_loader.vvp '+IMAGE=sim/snes_loader_test.hex'
    if ($LASTEXITCODE) { throw 'snes_loader_test failed' }
    Push-Location sim
    try {
        & "${CROSS}gcc" -Os -mabi=ilp32 -march=rv32i -ffreestanding -fno-builtin -ffunction-sections -fdata-sections `
            '-Wl,--gc-sections,--build-id=none,-T,..\firmware\baremetal.ld' -nostdlib `
            -o megadrive_loader_test.elf start.o megadrive_loader_test.c `
            ..\firmware\util.c ..\firmware\picorv32.c -lgcc
        if ($LASTEXITCODE) { throw 'compiling megadrive_loader_test failed' }
        & "${CROSS}objcopy" megadrive_loader_test.elf megadrive_loader_test.bin -O binary
        if ($LASTEXITCODE) { throw 'objcopy megadrive_loader_test failed' }
    } finally {
        Pop-Location
    }
    python tools\bin2hex.py sim\megadrive_loader_test.bin sim\megadrive_loader_test.hex 131072
    if ($LASTEXITCODE) { throw 'converting megadrive_loader_test failed' }
    & $vvp sim\tb_snes_loader.vvp '+IMAGE=sim/megadrive_loader_test.hex'
    if ($LASTEXITCODE) { throw 'megadrive_loader_test failed' }
    Push-Location sim
    & "${CROSS}gcc" -x assembler-with-cpp -mabi=ilp32 -march=rv32i -c -o start.o ../firmware/start.S
    & "${CROSS}gcc" -Os -mabi=ilp32 -march=rv32i -ffreestanding -fno-builtin -Wall -c -o prog.o prog.c
    & "${CROSS}gcc" -mabi=ilp32 -march=rv32i '-Wl,--build-id=none,-Bstatic,-T,../firmware/baremetal.ld,--strip-debug' `
        -nostdlib -o prog.elf start.o prog.o -lgcc
    & "${CROSS}objcopy" prog.elf prog.bin -O binary
    Pop-Location
    python tools/bin2hex.py sim/prog.bin sim/prog.hex 4096
    $sz = (Get-Item sim/prog.bin).Length
    Write-Host "sim/prog.bin: $sz bytes"
    if ($sz -gt 4096) { throw "sim/prog.bin does not fit in the 4096 byte simulated firmware window" }

    $iosysFiles = @(
        'sim/tb_iosys.v', 'sim/sdram_model.v', 'sim/spiflash_model.v',
        'rtl/tang/iosys/iosys.v', 'rtl/tang/iosys/picorv32.v',
        'rtl/tang/iosys/spiflash.v', 'rtl/tang/iosys/spi_master.v',
        'rtl/tang/iosys/simplespimaster.v', 'rtl/tang/iosys/simpleuart.v',
        'rtl/tang/iosys/textdisp.v', 'rtl/tang/iosys/font_rom.v',
        'rtl/tang/pce_sdram_ctrl_3ch.v'
    )
    $iosysFlags = @('-g2005-sv')
    if ($env:SIM_DUMP_VCD -eq '1') { $iosysFlags += '-DDUMP_VCD' }
    & $iverilog @iosysFlags -o sim/tb_iosys.vvp @iosysFiles
    if ($LASTEXITCODE) { throw 'iverilog failed for tb_iosys' }
    $out = & $vvp sim/tb_iosys.vvp
    $out | Write-Host
    $text = $out -join "`n"
    if ($text -match 'FAILED' -or $text -notmatch 'PASSED') { $fails += 'tb_iosys' }
} else {
    Write-Warning 'no RISC-V toolchain, skipping tb_iosys'
}

# ---------------------------------------------------------------------------
$gowinPrimSim = if ($env:GOWIN_HOME) {
    Join-Path $env:GOWIN_HOME 'IDE/simlib/gw2a/prim_sim.v'
} else {
    'G:\Gowin\Gowin_V1.9.11.03_Education_x64\IDE\simlib\gw2a\prim_sim.v'
}
foreach ($tb in @('tb_nes_gamepad', 'tb_gb_cart_mapper', 'tb_gbc_core', 'tb_gbc_apu', 'tb_nintendo_video', 'tb_gbc_color_correct', 'tb_nintendo_iosys', 'tb_snes_frame_probe', 'tb_snes_port_diag', 'tb_snes_vram_stream', 'tb_snes_video', 'tb_snes_video_stream', 'tb_snes_video_stream_bilinear', 'tb_snes_iosys_memory', 'tb_flash_pio', 'tb_textdisp', 'tb_dvi_video_window', 'tb_rom_source_arb', 'tb_sprite_stream', 'tb_sdram_reload', 'tb_vram_clear', 'tb_arcade_ram', 'tb_rv_uart_diagnostic', 'tb_rv_x22', 'tb_rv_memory_probe')) {
    if ($tb -eq 'tb_dvi_video_window' -and -not (Test-Path $gowinPrimSim)) {
        Write-Warning 'Gowin GW2A simulation library unavailable; skipping tb_dvi_video_window.'
        continue
    }
    $files = switch ($tb) {
        'tb_nes_gamepad' { @('rtl/nestang/src/nano20k/config.v', 'sim/tb_nes_gamepad.sv', 'rtl/top_tang_nano20k_nesgb.v', 'rtl/tang/snes_gamepad.v') }
        'tb_gb_cart_mapper' { @('sim/tb_gb_cart_mapper.sv', 'rtl/gb/gb_cart_mapper.sv') }
        'tb_nintendo_video' { @('sim/tb_nintendo_video.sv', 'rtl/nestang/src/nes2hdmi.sv', 'rtl/nestang/src/gbc_color_correct.sv') }
        'tb_gbc_color_correct' { @('sim/tb_gbc_color_correct.sv', 'rtl/nestang/src/gbc_color_correct.sv') }
        'tb_nintendo_iosys' { @('sim/tb_nintendo_iosys.sv', 'rtl/tang/iosys/iosys.v') }
        'tb_gbc_apu' { @('sim/tb_gbc_apu.sv', 'rtl/gbc/gbc_apu.v', 'rtl/gbc/gbc_apu_length_ctr.v', 'rtl/gbc/gbc_apu_noise.v', 'rtl/gbc/gbc_apu_square.v', 'rtl/gbc/gbc_apu_vol_env.v', 'rtl/gbc/gbc_apu_wave.v') }
        'tb_gbc_core' { @('sim/tb_gbc_core.sv','rtl/gbc/gbc_alu.v', 'rtl/gbc/gbc_apu.v', 'rtl/gbc/gbc_apu_length_ctr.v', 'rtl/gbc/gbc_apu_noise.v', 'rtl/gbc/gbc_apu_square.v', 'rtl/gbc/gbc_apu_vol_env.v', 'rtl/gbc/gbc_apu_wave.v', 'rtl/gbc/gbc_cart_mapper.sv', 'rtl/gbc/gbc_control.v', 'rtl/gbc/gbc_core.v', 'rtl/gbc/gbc_cpu.v', 'rtl/gbc/gbc_ppu.v', 'rtl/gbc/gbc_regfile.v', 'rtl/gbc/gbc_singlereg.v', 'rtl/gbc/gbc_timer.v') }
        'tb_snes_frame_probe' { @('sim/tb_snes_vram_stream.sv', 'rtl/top_tang_nano20k_snes.v') }
        'tb_snes_port_diag' { @('sim/tb_snes_vram_stream.sv', 'rtl/top_tang_nano20k_snes.v') }
        'tb_snes_vram_stream' { @('sim/tb_snes_vram_stream.sv', 'rtl/top_tang_nano20k_snes.v', 'rtl/snestang/src/sdram_nano.v', 'sim/sdram_model.v') }
        'tb_snes_video' { @('sim/tb_snes_video.sv', 'rtl/tang/snes_video_640.sv', 'rtl/snestang/src/dual_clk_fifo.v') }
        'tb_snes_video_stream' { @('sim/tb_snes_video.sv', 'rtl/tang/snes_video_640.sv', 'rtl/snestang/src/dual_clk_fifo.v') }
        'tb_snes_video_stream_bilinear' { @('sim/tb_snes_video.sv', 'rtl/tang/snes_video_640.sv', 'rtl/snestang/src/dual_clk_fifo.v') }
        'tb_snes_iosys_memory' { @('sim/tb_snes_iosys_memory.sv', 'sim/sdram_model.v', 'rtl/snestang/src/sdram_nano.v') }
    'tb_flash_pio' { @('sim/tb_flash_pio.v', 'rtl/tang/iosys/spiflash.v', 'rtl/tang/iosys/spi_master.v') }
        'tb_rv_memory_probe' { @('sim/tb_rv_memory_probe.v', 'rtl/tang/rv_memory_probe.v', 'rtl/tang/rv_stack_watch.v') }
        'tb_rv_x22' { @('sim/tb_rv_x22.v', 'rtl/tang/iosys/picorv32.v') }
        'tb_rv_uart_diagnostic' { @('sim/tb_rv_uart_diagnostic.v', 'rtl/tang/rv_uart_diagnostic.v', 'rtl/tang/iosys/simpleuart.v') }
        'tb_textdisp'       { @('sim/tb_textdisp.v', 'rtl/tang/iosys/textdisp.v', 'rtl/tang/iosys/font_rom.v') }
        'tb_dvi_video_window' { @('sim/tb_dvi_video_window.sv', 'rtl/tang/dvi_tx.v', 'rtl/tang/tmds_encoder.v', 'rtl/tang/hdmi_audio_packetizer.sv', 'rtl/tang/audio_sampler_48k.sv', $gowinPrimSim) }
        'tb_rom_source_arb' { @('sim/tb_rom_source_arb.v', 'rtl/tang/rom_source_arb.v') }
        'tb_sprite_stream'  { @('sim/tb_sprite_stream.v', 'sim/sdram_model.v', 'rtl/tang/pce_sdram_ctrl_3ch.v') }
        'tb_sdram_reload'   { @('sim/tb_sdram_reload.v', 'sim/sdram_model.v', 'rtl/tang/pce_sdram_ctrl_3ch.v') }
        'tb_vram_clear' { @('sim/tb_vram_clear.v', 'sim/sdram_model.v', 'rtl/tang/pce_sdram_ctrl_3ch.v') }
        'tb_arcade_ram' { @('sim/tb_arcade_ram.v', 'sim/sdram_model.v', 'rtl/tang/pce_sdram_ctrl_3ch.v') }
    }
    $flags = @('-g2005-sv')
    if ($tb -eq 'tb_gb_cart_mapper') { $flags = @('-g2012', '-s', $tb) }
    if ($tb -eq 'tb_gbc_apu') { $flags = @('-g2012', '-s', $tb) }
    if ($tb -eq 'tb_gbc_core') { $flags = @('-g2012', '-I', 'rtl/gbc', '-s', $tb) }
    if ($tb -in @('tb_nintendo_video', 'tb_gbc_color_correct', 'tb_nintendo_iosys')) { $flags = @('-g2012', '-i', '-s', $tb) }
    if ($tb -eq 'tb_nes_gamepad') { $flags = @('-g2012', '-i', '-s', $tb) }
    if ($tb -in @('tb_snes_port_diag', 'tb_snes_frame_probe')) { $flags = @('-g2012', '-i', '-s', $tb) }
    if ($tb -eq 'tb_snes_vram_stream') { $flags = @('-g2012', '-i', '-s', $tb) }
    if ($tb -in @('tb_snes_video', 'tb_snes_video_stream', 'tb_snes_video_stream_bilinear')) { $flags = @('-g2012', '-s', $tb) }
    if ($tb -eq 'tb_dvi_video_window') { $flags += @('-s', $tb) }
    & $iverilog @flags -o "sim/$tb.vvp" @files
    if ($LASTEXITCODE) { throw "iverilog failed for $tb" }
    $out = & $vvp "sim/$tb.vvp"
    $out | Write-Host
    $text = $out -join "`n"
    if ($text -match 'FAILED' -or $text -notmatch 'PASSED') { $fails += $tb }
}

$ghdl = Get-Command ghdl -ErrorAction SilentlyContinue
if ($ghdl) {
    $ghdlFlags = @('--std=08', '-fsynopsys', '-frelaxed', '--work=pce_vce_timing_test', "--workdir=$env:TEMP")
    & $ghdl.Source -a @ghdlFlags rtl/pce/mem_init_pkg.vhd rtl/pce/dpram.vhd rtl/pce/huc6260.vhd sim/tb_vce_frame_timing.vhd
    if ($LASTEXITCODE) { throw 'GHDL compilation failed for tb_vce_frame_timing' }
    $out = & $ghdl.Source -r @ghdlFlags tb_vce_frame_timing --assert-level=error --ieee-asserts=disable
    $out | Write-Host
    if ($LASTEXITCODE -ne 0 -or ($out -join "`n") -notmatch 'tb_vce_frame_timing PASSED') {
        $fails += 'tb_vce_frame_timing'
    }
} else {
    Write-Warning 'GHDL unavailable; skipping tb_vce_frame_timing.'
}

if ($fails.Count) {
    throw ("FAILED: " + ($fails -join ', '))
}
Write-Host "`nAll test benches passed."
