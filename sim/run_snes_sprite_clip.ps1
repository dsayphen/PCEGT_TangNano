$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
$iverilog = Get-Command iverilog -ErrorAction SilentlyContinue
if (-not $iverilog) {
    $bin = if ($env:IVERILOG_BIN) { $env:IVERILOG_BIN } else { 'C:\iverilog\bin' }
    $env:PATH = "$bin;$env:PATH"
}
New-Item -ItemType Directory -Force sim\gen | Out-Null
$ppu = Get-Content rtl\snestang\src\ppu.v -Raw
$start = $ppu.IndexOf('always @(posedge CLK) begin : calc_sprite_range')
$end = $ppu.IndexOf('assign OBJ_VRAM_ADDR', $start)
if ($start -lt 0 -or $end -lt 0) { throw 'sprite engine markers not found' }
$engine = $ppu.Substring($start, $end - $start)
# Icarus does not support unpacked array assignment patterns.
$engine = $engine.Replace("OAM_RANGE <= '{32{7'b0}};",
    "for (integer k = 0; k < 32; k = k + 1) OAM_RANGE[k] <= 7'b0;")
Set-Content sim\gen\snes_sprite_engine.vh $engine

$defines = Get-Content rtl\snestang\src\ppu_defines.vh -Raw
$tables = foreach ($name in @('SPR_WIDTH', 'SPR_HEIGHT')) {
    $m = [regex]::Match($defines, "parameter SprSize_t $name = '\{([^}]+)\};")
    if (-not $m.Success) { throw "$name not found" }
    $values = $m.Groups[1].Value.Split(',') | ForEach-Object { $_.Trim() }
    "reg [7:0] $name [0:15];"
    'initial begin'
    for ($i = 0; $i -lt 16; $i++) { "    $name[$i] = $($values[$i]);" }
    'end'
}
Set-Content sim\gen\snes_sprite_sizes.vh $tables
iverilog -g2012 -I sim\gen -s tb_snes_sprite_clip -o sim\gen\tb_snes_sprite_clip.vvp sim\tb_snes_sprite_clip.sv
if ($LASTEXITCODE) { throw 'compiling sprite clipping test failed' }
vvp -n sim\gen\tb_snes_sprite_clip.vvp
if ($LASTEXITCODE) { throw 'sprite clipping test failed' }
