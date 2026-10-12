# Builds and runs the simulation test benches with Icarus Verilog.
#
#   pwsh sim/run.ps1
#
# Requires iverilog on PATH (or set $env:IVERILOG_BIN to its bin directory)
# and, for tb_iosys, the RISC-V toolchain used by firmware/build.ps1.

param([Alias('Savestate')][switch]$CpuSavestate)

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

if ($CpuSavestate) {
    $ghdl = Find-Tool 'ghdl' @()
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    [System.IO.Directory]::CreateDirectory($work) | Out-Null
    try {
        $sources = @(
            'rtl/HUC6280/HUC6280_PKG.vhd', 'rtl/HUC6280/AddSubBCD.vhd',
            'rtl/HUC6280/HUC6280_AG.vhd', 'rtl/HUC6280/HUC6280_ALU.vhd',
            'rtl/HUC6280/HUC6280_MC.vhd', 'rtl/HUC6280/HUC6280_CPU.vhd',
            'rtl/mem_init_pkg.vhd', 'rtl/dpram.vhd',
            'rtl/huc6202.vhd', 'rtl/huc6260.vhd',
            'sim/gowin_dp_model.vhd', 'rtl/dpram_ip.vhd', 'rtl/dpram_ip_9x10.vhd',
            'rtl/huc6270.vhd', 'sim/tb_vdc_savestate.vhd',
            'rtl/HUC6280/psg_mixer.vhd', 'rtl/HUC6280/psg.vhd',
            'rtl/HUC6280/HUC6280.vhd',
            'rtl/pce_top_extram.vhd', 'rtl/tang/pce_core.vhd', 'sim/tb_state_portal.vhd',
            'sim/tb_cpu_savestate.vhd'
        )
        & $ghdl -a --std=08 -fsynopsys -frelaxed-rules "--workdir=$work" @sources
        if ($LASTEXITCODE) { throw 'CPU savestate analysis failed' }
        & $ghdl --elab-run --std=08 -fsynopsys -frelaxed-rules "--workdir=$work" tb_cpu_savestate --assert-level=error --ieee-asserts=disable --stop-time=1ms
        if ($LASTEXITCODE) { throw 'CPU savestate simulation failed' }
        & $ghdl --elab-run --std=08 -fsynopsys -frelaxed-rules "--workdir=$work" tb_vdc_savestate --assert-level=error --ieee-asserts=disable
        if ($LASTEXITCODE) { throw 'VDC savestate simulation failed' }
        & $ghdl --elab-run --std=08 -fsynopsys -frelaxed-rules "--workdir=$work" tb_state_portal --assert-level=error --ieee-asserts=disable
        if ($LASTEXITCODE) { throw 'State portal simulation failed' }
        $toolDirs = @($env:IVERILOG_BIN, 'C:\iverilog\bin', 'C:\Program Files\iverilog\bin') | Where-Object { $_ }
        $iverilog = Find-Tool 'iverilog' $toolDirs
        $vvp = Find-Tool 'vvp' $toolDirs
        $bridgeTest = Join-Path $work 'tb_state_bridge.vvp'
        & $iverilog -g2012 -s tb_state_bridge -o $bridgeTest sim/tb_state_bridge.sv rtl/tang/state_bridge.v
        if ($LASTEXITCODE) { throw 'State bridge compilation failed' }
        & $vvp $bridgeTest
        if ($LASTEXITCODE) { throw 'State bridge simulation failed' }
    } finally {
        Remove-Item -Recurse -Force $work
    }
    return
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
foreach ($tb in @('tb_flash_pio', 'tb_textdisp', 'tb_rom_source_arb', 'tb_sprite_stream', 'tb_sdram_reload', 'tb_vram_clear', 'tb_arcade_ram', 'tb_rv_uart_diagnostic', 'tb_rv_x22', 'tb_rv_memory_probe')) {
    $files = switch ($tb) {
    'tb_flash_pio' { @('sim/tb_flash_pio.v', 'rtl/tang/iosys/spiflash.v', 'rtl/tang/iosys/spi_master.v') }
        'tb_rv_memory_probe' { @('sim/tb_rv_memory_probe.v', 'rtl/tang/rv_memory_probe.v', 'rtl/tang/rv_stack_watch.v') }
        'tb_rv_x22' { @('sim/tb_rv_x22.v', 'rtl/tang/iosys/picorv32.v') }
        'tb_rv_uart_diagnostic' { @('sim/tb_rv_uart_diagnostic.v', 'rtl/tang/rv_uart_diagnostic.v', 'rtl/tang/iosys/simpleuart.v') }
        'tb_textdisp'       { @('sim/tb_textdisp.v', 'rtl/tang/iosys/textdisp.v', 'rtl/tang/iosys/font_rom.v') }
        'tb_rom_source_arb' { @('sim/tb_rom_source_arb.v', 'rtl/tang/rom_source_arb.v') }
        'tb_sprite_stream'  { @('sim/tb_sprite_stream.v', 'sim/sdram_model.v', 'rtl/tang/pce_sdram_ctrl_3ch.v') }
        'tb_sdram_reload'   { @('sim/tb_sdram_reload.v', 'sim/sdram_model.v', 'rtl/tang/pce_sdram_ctrl_3ch.v') }
        'tb_vram_clear' { @('sim/tb_vram_clear.v', 'sim/sdram_model.v', 'rtl/tang/pce_sdram_ctrl_3ch.v') }
        'tb_arcade_ram' { @('sim/tb_arcade_ram.v', 'sim/sdram_model.v', 'rtl/tang/pce_sdram_ctrl_3ch.v') }
    }
    & $iverilog -g2005-sv -o "sim/$tb.vvp" @files
    if ($LASTEXITCODE) { throw "iverilog failed for $tb" }
    $out = & $vvp "sim/$tb.vvp"
    $out | Write-Host
    $text = $out -join "`n"
    if ($text -match 'FAILED' -or $text -notmatch 'PASSED') { $fails += $tb }
}

if ($fails.Count) {
    throw ("FAILED: " + ($fails -join ', '))
}
Write-Host "`nAll test benches passed."
