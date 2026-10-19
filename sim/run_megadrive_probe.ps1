param(
    [string]$GowinHome = $env:GOWIN_HOME,
    [string]$IverilogBin = $env:IVERILOG_BIN
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $GowinHome) {
    $GowinHome = 'G:\Gowin\Gowin_V1.9.11.03_Education_x64'
}
$primitive = Join-Path $GowinHome 'IDE\simlib\gw2a\prim_sim.v'
if (-not (Test-Path -LiteralPath $primitive)) {
    throw "Gowin simulation library not found: $primitive. Pass -GowinHome."
}
if (-not $IverilogBin) {
    $command = Get-Command iverilog -ErrorAction SilentlyContinue
    if ($command) {
        $IverilogBin = Split-Path -Parent $command.Source
    } elseif (Test-Path 'C:\iverilog\bin\iverilog.exe') {
        $IverilogBin = 'C:\iverilog\bin'
    } else {
        $IverilogBin = 'C:\Program Files\iverilog\bin'
    }
}
$iverilog = Join-Path $IverilogBin 'iverilog.exe'
$vvp = Join-Path $IverilogBin 'vvp.exe'
foreach ($path in @($iverilog, $vvp)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Simulation tool not found: $path. Pass -IverilogBin."
    }
}
$work = Join-Path $root 'impl\profile-build\megadrive-probe'
New-Item -ItemType Directory -Path $work -Force | Out-Null
# Icarus cannot elaborate fx68k's unpacked structures. Exercise the actual
# clock-enable and bus-idle blocks without replacing them with copied models.
$system = Get-Content -LiteralPath (Join-Path $root 'rtl\mdtang\src\system.sv') -Raw
$cpu = Get-Content -LiteralPath (Join-Path $root 'rtl\mdtang\src\fx68k\fx68k.sv') -Raw
$fragments = @{
    'md_clock_enables.vh' = [regex]::Match($system, '(?s)reg\s+FM_CLKEN;.*?(?=reg \[16:1\] ram_rst_a;)').Value
    'md_cpu_enables.vh' = [regex]::Match($cpu, '(?s)reg \[4:0\] tState =.*?(?=`else)').Value
    'md_bus_idle.vh' = [regex]::Match($system, '(?s)MBUS_IDLE:\s*begin.*?(?=\s*MBUS_WAIT_FOR_S4:)').Value
    'md_z80_shadow.vh' = [regex]::Match($system, '(?s)reg\s+Z80_BUSAK_N = 1;.*?(?=// use our own T80)').Value
}
foreach ($name in $fragments.Keys) {
    $fragment = $fragments[$name]
    if (!$fragment) { throw "Cannot extract $name from Mega Drive RTL." }
    $fragment = $fragment.Replace('Clks.clk', 'MCLK').Replace('Clks.pwrUp', '!RESET_N').
        Replace('Clks.enPhi1', 'M68K_CLKENp').Replace('Clks.enPhi2', 'M68K_CLKENn')
    # FPGA registers power up at zero; the RTL never resets this counter.
    $fragment = $fragment.Replace('reg [3:0] ZCLKCNT;', 'reg [3:0] ZCLKCNT = 0;')
    Set-Content -LiteralPath (Join-Path $work $name) -Value $fragment -Encoding ascii
}
Push-Location $work
try {
    foreach ($case in @('tb_megadrive_enables', 'tb_megadrive_probe', 'tb_megadrive_sdp', 'tb_megadrive_sdram', 'tb_megadrive_host', 'tb_fx68k_regfile', 'tb_megadrive_video', 'tb_megadrive_fm_mux', 'tb_megadrive_center', 'tb_megadrive_hdmi', 'tb_megadrive_hdmi_four', 'tb_megadrive_phase_inc', 'tb_megadrive_z80_shadow')) {
        $bench = $case
        $options = @()
        if ($case -eq 'tb_megadrive_hdmi_four') {
            $bench = 'tb_megadrive_hdmi'
            $options = @('-Ptb_megadrive_hdmi.SAMPLES_PER_PACKET=4')
        }
        $image = Join-Path $work "$case.vvp"
        & $iverilog @options -g2012 -s $bench -o $image `
            (Join-Path $root "sim\$bench.sv") `
            (Join-Path $root 'sim\sdram_model.v') `
            (Join-Path $root 'rtl\tang\sdram.v') `
            (Join-Path $root 'rtl\tang\megadrive_sdram.sv') `
            (Join-Path $root 'rtl\tang\megadrive_host_bridge.sv') `
            (Join-Path $root 'rtl\tang\megadrive_video.sv') `
            (Join-Path $root 'rtl\tang\dvi_tx.v') `
            (Join-Path $root 'rtl\tang\tmds_encoder.v') `
            (Join-Path $root 'rtl\tang\hdmi_audio_packetizer.sv') `
            (Join-Path $root 'rtl\tang\audio_sampler_48k.sv') `
            (Join-Path $root 'rtl\mdtang\src\fx68k\fx68k_regfile.sv') `
            (Join-Path $root 'rtl\mdtang\src\common\dpram_block.v') `
            (Join-Path $root 'rtl\mdtang\src\common\dpram32_block.v') `
            (Join-Path $root 'rtl\mdtang\src\common\md_sdp_ram.sv') `
            (Join-Path $root 'rtl\mdtang\src\jt12\jt12_sh.v') `
            (Join-Path $root 'rtl\mdtang\src\jt12\jt12_sh_rst.v') `
            (Join-Path $root 'rtl\mdtang\src\jt12\jt12_reg.v') `
            (Join-Path $root 'rtl\mdtang\src\jt12\jt12_sumch.v') `
            (Join-Path $root 'rtl\mdtang\src\jt12\jt12_kon.v') `
            (Join-Path $root 'rtl\mdtang\src\jt12\jt12_csr.v') `
            (Join-Path $root 'rtl\mdtang\src\jt12\jt12_mod.v') `
            (Join-Path $root 'rtl\mdtang\src\jt12\jt12_pg_inc.v') `
            (Join-Path $root 'rtl\mdtang\src\jt12\jt12_div.v') `
            (Join-Path $root 'rtl\mdtang\src\jt12\jt12_lfo.v') `
            (Join-Path $root 'rtl\mdtang\src\jt12\jt12_logsin.v') `
            (Join-Path $root 'rtl\mdtang\src\jt12\jt12_exprom.v') $primitive
        if ($LASTEXITCODE -ne 0) { throw "$bench compilation failed." }
        & $vvp $image
        if ($LASTEXITCODE -ne 0) { throw "$bench failed." }
    }
} finally {
    Pop-Location
}
