# Builds firmware.bin for the PicoRV32 IO subsystem (RV32I, linked at 0).
#
# Needs the xPack RISC-V bare metal GCC:
#   https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases
# Point $env:RISCV_PREFIX at <toolchain>/bin/riscv-none-elf- or drop the
# toolchain in one of the locations probed below.
#
#   pwsh firmware/build.ps1
#
# Burn the result to SPI flash offset 0x500000 with the Gowin programmer,
# see README.md.

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

function Find-Prefix {
    if ($env:RISCV_PREFIX) { return $env:RISCV_PREFIX }
    $cmd = Get-Command 'riscv-none-elf-gcc' -ErrorAction SilentlyContinue
    if ($cmd) { return 'riscv-none-elf-' }
    $cmd = Get-Command 'riscv64-unknown-elf-gcc' -ErrorAction SilentlyContinue
    if ($cmd) { return 'riscv64-unknown-elf-' }
    foreach ($root in @("$env:USERPROFILE\opt", 'C:\opt', 'D:\opt')) {
        if (-not (Test-Path $root)) { continue }
        $hit = Get-ChildItem $root -Recurse -Filter 'riscv-none-elf-gcc.exe' -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($hit) { return ($hit.FullName -replace 'gcc\.exe$', '') }
    }
    throw "No RISC-V toolchain found. Set RISCV_PREFIX, e.g. C:\opt\xpack-riscv-none-elf-gcc-13.2.0-2\bin\riscv-none-elf-"
}

$CROSS  = Find-Prefix
$CFLAGS = @('-Os', '-mabi=ilp32', '-march=rv32i', '-ffreestanding',
            '-fno-builtin', '-fomit-frame-pointer', '-Wall')

Write-Host "toolchain: $CROSS"

$objs = @()

& "${CROSS}gcc" -x assembler-with-cpp -mabi=ilp32 -march=rv32i -c -o start.o start.S
if ($LASTEXITCODE) { throw 'assembling start.S failed' }
$objs += 'start.o'

foreach ($src in @('firmware.c', 'browser.c', 'rom.c', 'cd.c', 'cheats.c', 'menu.c',
                   'settings.c', 'saves.c', 'osd.c', 'util.c',
                   'picorv32.c', 'spi_sd.c',
                   'fatfs/diskio.c', 'fatfs/ff.c', 'fatfs/ffunicode.c')) {
    $obj = [System.IO.Path]::ChangeExtension($src, 'o')
    & "${CROSS}gcc" @CFLAGS -c -o $obj $src
    if ($LASTEXITCODE) { throw "compiling $src failed" }
    $objs += $obj
}

& "${CROSS}gcc" @CFLAGS '-Wl,--build-id=none,-Bstatic,-T,baremetal.ld,--strip-debug' `
    -nostdlib -o firmware.elf @objs -lgcc
if ($LASTEXITCODE) { throw 'linking failed' }

& "${CROSS}objcopy" firmware.elf firmware.bin -O binary
if ($LASTEXITCODE) { throw 'objcopy failed' }

& "${CROSS}objdump" -Mnumeric -D firmware.elf | Out-File -Encoding ascii firmware.elf.list

$size = (Get-Item firmware.bin).Length
Write-Host ("firmware.bin: {0} bytes ({1:N1} KiB)" -f $size, ($size / 1KB))

# must fit in the window iosys.v copies out of flash
$limit = 128 * 1024
if ($size -gt $limit) {
    throw "firmware.bin is larger than FIRMWARE_SIZE ($limit bytes). Raise FIRMWARE_SIZE in rtl/top_tang_nano20k.v or shrink the firmware."
}
Write-Host 'OK - burn firmware.bin to SPI flash offset 0x500000'
