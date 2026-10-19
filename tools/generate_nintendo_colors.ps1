param(
    [string]$PaletteDirectory = "$PSScriptRoot\..\rtl\nestang\palettes"
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$out = Join-Path $root 'rtl\nestang\palettes'
$files = @('Original.pal', 'Composite Direct (FBX).pal', 'NES Classic (FBX).pal',
           'PC-10.pal', 'PVM Style D93 (FBX).pal', 'Smooth (FBX).pal',
           'Sony CXA.pal', 'Wavebeam.pal')
$colors = foreach ($file in $files) {
    $bytes = [IO.File]::ReadAllBytes((Join-Path $PaletteDirectory $file))
    if ($bytes.Length -ne 192) { throw "$file must contain 64 RGB triplets" }
    for ($i = 0; $i -lt 192; $i += 3) {
        '{0:x2}{1:x2}{2:x2}' -f $bytes[$i], $bytes[$i+1], $bytes[$i+2]
    }
}
[IO.File]::WriteAllLines((Join-Path $out 'nes.hex'), [string[]]$colors)

# Pokefan531 / hunterk's public-domain gbc-color matrix, with Gambatte's
# default Accurate brightness (gamma 2.2 - 0.5). Q16 linear contributions.
$matrix = @(@(0.82, 0.24, -0.06), @(0.125, 0.665, 0.21), @(0.195, 0.075, 0.73))
for ($source = 0; $source -lt 3; $source++) {
    $lines = @("function automatic signed [17:0] gbc_contrib_$source(input [6:0] address);",
               '    case (address)')
    for ($component = 0; $component -lt 3; $component++) {
        for ($v = 0; $v -lt 32; $v++) {
            $n = [int][Math]::Round(65535 * 0.94 * $matrix[$component][$source] * [Math]::Pow($v / 31.0, 1.7))
            $literal = if ($n -lt 0) { "-18'sd$(-$n)" } else { "18'sd$n" }
            $lines += "        7'd$($component*32+$v): gbc_contrib_$source = $literal;"
        }
    }
    $lines += @("        default: gbc_contrib_$source = 18'sd0;", '    endcase', 'endfunction')
    [IO.File]::WriteAllLines((Join-Path $out "gbc_contrib_$source.svh"), [string[]]$lines)
}
# Dense at black, 32-unit Q16 buckets above 1024. One shared gamma ROM.
$gamma = for ($i = 0; $i -lt 4096; $i++) {
    $linear = if ($i -lt 1024) { $i } else { 1024 + ($i - 1024) * 32 + 16 }
    $v = [Math]::Min(255, [Math]::Round(255 * [Math]::Pow($linear / 65535.0, 1.0/2.2)))
    '{0:x2}' -f [int]$v
}
[IO.File]::WriteAllLines((Join-Path $out 'gbc_gamma.hex'), [string[]]$gamma)
Write-Host 'Generated NES palettes and GBC Accurate fixed-point tables.'
