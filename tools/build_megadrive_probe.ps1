param(
    [string]$GowinShell,
    [switch]$WithSdram,
    [switch]$WithMenu
)

$ErrorActionPreference = 'Stop'
if ($WithSdram -and $WithMenu) {
    throw 'Choose either -WithSdram or -WithMenu; the menu probe already includes SDRAM.'
}
$root = Split-Path -Parent $PSScriptRoot
if (-not $GowinShell) {
    if ($env:GOWIN_HOME) {
        $GowinShell = Join-Path $env:GOWIN_HOME 'IDE\bin\gw_sh.exe'
    } else {
        $GowinShell = 'G:\Gowin\Gowin_V1.9.11.03_Education_x64\IDE\bin\gw_sh.exe'
    }
}
if (-not (Test-Path -LiteralPath $GowinShell)) {
    throw "Gowin Tcl shell not found: $GowinShell. Pass -GowinShell or set GOWIN_HOME."
}
$GowinShell = (Resolve-Path -LiteralPath $GowinShell).Path
$top = 'megadrive_probe'
$profile = 'megadrive-probe'
if ($WithSdram) {
    $top = 'megadrive_sdram_probe'
    $profile = 'megadrive-sdram-probe'
}
if ($WithMenu) {
    $top = 'megadrive_menu_probe'
    $profile = 'megadrive-menu-probe'
}
$work = Join-Path $root "impl\profile-build\$profile"
New-Item -ItemType Directory -Path $work -Force | Out-Null
$netlist = Join-Path $work "impl\gwsynthesis\$top.vg"
$report = Join-Path $work "impl\gwsynthesis\$($top)_syn.rpt.html"
foreach ($path in @($netlist, $report)) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path
    }
}

Write-Host 'Synthesizing 68000, Z80, VDP, PSG and FM.'
if ($WithSdram) { Write-Host 'Including Nano 20K x32 SDRAM controller and host port.' }
if ($WithMenu) { Write-Host 'Including SDRAM, IOSys menu, firmware CPU and loader bridge; no video scaler.' }
Write-Host 'No board top, place-and-route, bitstream or flash operation.'
Push-Location $work
try {
    & $GowinShell (Join-Path $PSScriptRoot "$top.tcl")
    if ($LASTEXITCODE -ne 0) {
        throw "Mega Drive probe synthesis failed (exit $LASTEXITCODE). See $work."
    }
    if (-not (Test-Path -LiteralPath $netlist)) {
        throw "Synthesis did not produce the expected netlist: $netlist"
    }
    $reportText = Get-Content -LiteralPath $report -Raw
    foreach ($resource in @('Logic', 'Register', 'BSRAM')) {
        $match = [regex]::Match($reportText, "<td class=`"label`">$resource</td>\s*<td>([^<]+)</td>")
        if (-not $match.Success) {
            throw "Missing $resource utilization in synthesis report: $report"
        }
        Write-Host ("{0}: {1}" -f $resource, $match.Groups[1].Value)
    }
} finally {
    Pop-Location
}
Write-Host "Console synthesis completed. Resource reports: $work\impl\gwsynthesis"
Write-Host 'This is not evidence of board-level fit, timing closure or game compatibility.'
