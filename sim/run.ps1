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
        'rtl/tang/pce_sdram_ctrl.v', 'rtl/tang/sdram.v'
    )
    & $iverilog -g2005-sv -o sim/tb_iosys.vvp @iosysFiles
    if ($LASTEXITCODE) { throw 'iverilog failed for tb_iosys' }
    $out = & $vvp sim/tb_iosys.vvp
    $out | Write-Host
    if ($out -match 'FAILED' -or $out -notmatch 'PASSED') { $fails += 'tb_iosys' }
} else {
    Write-Warning 'no RISC-V toolchain, skipping tb_iosys'
}

# ---------------------------------------------------------------------------
foreach ($tb in @('tb_textdisp', 'tb_rom_source_arb')) {
    $files = switch ($tb) {
        'tb_textdisp'       { @('sim/tb_textdisp.v', 'rtl/tang/iosys/textdisp.v', 'rtl/tang/iosys/font_rom.v') }
        'tb_rom_source_arb' { @('sim/tb_rom_source_arb.v', 'rtl/tang/rom_source_arb.v') }
    }
    & $iverilog -g2005-sv -o "sim/$tb.vvp" @files
    if ($LASTEXITCODE) { throw "iverilog failed for $tb" }
    $out = & $vvp "sim/$tb.vvp"
    $out | Write-Host
    if ($out -match 'FAILED' -or $out -notmatch 'PASSED') { $fails += $tb }
}

if ($fails.Count) {
    throw ("FAILED: " + ($fails -join ', '))
}
Write-Host "`nAll test benches passed."
