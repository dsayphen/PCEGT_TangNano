param(
    [string]$GowinShell = 'G:\Gowin\Gowin_V1.9.11.03_Education_x64\IDE\bin\gw_sh.exe',
    [switch]$SynthesisOnly,
    [string]$PlaceOption = '1'
)
$ErrorActionPreference = 'Stop'
if (!(Test-Path -LiteralPath $GowinShell)) { throw "Gowin shell not found: $GowinShell" }
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path $root 'impl\profile-build\megadrive-board'
$output = Join-Path $root 'impl\profiles\megadrive'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$script = Join-Path $work 'build.tcl'
$project = Join-Path $work 'megadrive.gprj'
$physicalConstraints = Join-Path $work 'megadrive.cst'
Copy-Item -LiteralPath (Join-Path $root 'constraints\tang_nano20k.cst') `
    -Destination $physicalConstraints -Force
Add-Content -LiteralPath $physicalConstraints -Value 'CLOCK_LOC "clk_serial" BUFS = CLK;'
$config = Join-Path $work 'impl\megadrive_process_config.json'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $config) | Out-Null
$upstream = Join-Path $root 'rtl\mdtang\src'
$sources = @()
foreach ($dir in @('common','fx68k','jt12','jt12\adpcm','jt12\mixer','jt89','peripherals','t80','vdp')) {
    $sources += Get-ChildItem -LiteralPath (Join-Path $upstream $dir) -File |
        Where-Object { $_.Extension -in @('.v','.sv') } | Sort-Object Name | Select-Object -ExpandProperty FullName
}
$sources += Join-Path $upstream 'system.sv'
foreach ($name in @('iosys','picorv32','font_rom','textdisp','simplespimaster','spi_master','spiflash')) {
    $sources += Join-Path $root "rtl\tang\iosys\$name.v"
}
foreach ($name in @('sdram.v','megadrive_probe.sv','megadrive_sdram.sv','megadrive_sdram_probe.sv',
    'megadrive_host_bridge.sv','megadrive_menu_probe.sv','megadrive_pll.v','megadrive_video.sv',
    'snes_gamepad.v','dvi_tx.v','tmds_encoder.v','hdmi_audio_packetizer.sv',
    'audio_sampler_48k.sv','i2s_tx.v','audio_tone.v')) {
    $sources += Join-Path $root "rtl\tang\$name"
}
$sources += Join-Path $root 'rtl\top_tang_nano20k_megadrive.sv'
$xml = New-Object System.Xml.XmlDocument
$xml.LoadXml('<?xml version="1.0" encoding="UTF-8"?><Project><Template>FPGA</Template><Version>5</Version><Device name="GW2AR-18C" pn="GW2AR-LV18QN88C8/I7">gw2ar18c-000</Device><FileList/></Project>')
foreach ($path in $sources + @($physicalConstraints,(Join-Path $root 'constraints\megadrive_nano20k.sdc'))) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing source: $path" }
    $entry = $xml.CreateElement('File')
    $entry.SetAttribute('path', $path.Replace('\','/'))
    $type = 'file.verilog'
    if ($path.EndsWith('.cst')) { $type = 'file.cst' }
    if ($path.EndsWith('.sdc')) { $type = 'file.sdc' }
    $entry.SetAttribute('type', $type)
    $entry.SetAttribute('enable', '1')
    [void]$xml.SelectSingleNode('/Project/FileList').AppendChild($entry)
}
$xml.Save($project)
Add-Type -AssemblyName System.Web.Extensions
$serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$settings = $serializer.DeserializeObject((Get-Content -LiteralPath (Join-Path $root 'impl\PCE_GT_TangNano_process_config.json') -Raw))
$settings['OUTPUT_BASE_NAME'] = 'PCE_GT_TangNano_megadrive'
$settings['TopModule'] = 'top_tang_nano20k_megadrive'
$settings['GwSyn_Loop_Limit'] = 8192
$settings['Place_Option'] = $PlaceOption
$settings['Generate_Plain_Text_Timing_Report'] = $true
[System.IO.File]::WriteAllText($config, $serializer.Serialize($settings))
foreach ($dir in @($work,(Join-Path $work 'impl\gwsynthesis'))) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    foreach ($name in @('microrom.mem','nanorom.mem')) {
        Copy-Item -LiteralPath (Join-Path $upstream "fx68k\$name") -Destination $dir -Force
    }
}
$run = 'run all'
if ($SynthesisOnly) { $run = 'run syn' }
@("open_project {$($project.Replace('\','/'))}", $run, 'exit') | Set-Content -LiteralPath $script -Encoding ascii
Push-Location $work
try {
    foreach ($extension in @('fs','bin','tr')) {
        $previous = Join-Path $work "impl\pnr\PCE_GT_TangNano_megadrive.$extension"
        if (Test-Path -LiteralPath $previous) { Remove-Item -LiteralPath $previous -Force }
    }
    & $GowinShell $script
    if ($LASTEXITCODE -ne 0) { throw "Mega Drive build failed (exit $LASTEXITCODE). See $work." }
    if (!$SynthesisOnly) {
        foreach ($extension in @('fs','bin')) {
            $artifact = Join-Path $work "impl\pnr\PCE_GT_TangNano_megadrive.$extension"
            if (!(Test-Path -LiteralPath $artifact)) { throw "Missing bitstream: $artifact" }
        }
        $binary = Get-Item -LiteralPath (Join-Path $work 'impl\pnr\PCE_GT_TangNano_megadrive.bin')
        if ($binary.Length -gt 1MB) { throw 'Mega Drive binary exceeds its 1 MiB flash slot.' }
        $timingPath = Join-Path $work 'impl\pnr\PCE_GT_TangNano_megadrive.tr'
        $timing = Get-Content -LiteralPath $timingPath -Raw
        foreach ($kind in @('Setup','Hold')) {
            $count = [regex]::Match($timing, "<Numbers of $kind Violated Endpoints>:\s*(\d+)")
            if (!$count.Success -or [int]$count.Groups[1].Value -ne 0) {
                throw "$kind timing is not closed. See $timingPath. No new profile exported."
            }
        }
        foreach ($subdir in @('gwsynthesis','pnr')) {
            $dest = Join-Path $output $subdir
            New-Item -ItemType Directory -Force -Path $dest | Out-Null
            Get-ChildItem -LiteralPath (Join-Path $work "impl\$subdir") -File |
                Where-Object { $_.Name -like 'PCE_GT_TangNano_megadrive*' } |
                Copy-Item -Destination $dest -Force
        }
        Write-Host "Mega Drive artifacts: $output (not flashed; inspect timing reports before hardware use)."
    }
} finally { Pop-Location }
