# System test for SNES "Reset Game" with a 4 MiB ROM: the real SNES top, CPU,
# WRAM and SDRAM controller run a small program that copies high and low ROM
# with DMA and CPU reads. The PPU is replaced by a timing stub and the SMP/DSP
# by forced ARAM traffic, because Icarus cannot parse their SystemVerilog.
# Icarus-compatible copies of cpu.v and the Gowin primitives are generated in
# sim/gen.
#
#   powershell -File sim/run_snes_reset_dma.ps1 [-Resets 8] [-PauseBase 4000]

param([int]$Resets = 8, [int]$PauseBase = 4000)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$ivdirs = @($env:IVERILOG_BIN, 'C:\iverilog\bin', 'C:\Program Files\iverilog\bin') | Where-Object { $_ }
foreach ($d in $ivdirs) { if (Test-Path "$d\iverilog.exe") { $env:PATH = "$d;$env:PATH"; break } }
$prim = if ($env:GOWIN_PRIM_SIM) { $env:GOWIN_PRIM_SIM } else {
    'G:\Gowin\Gowin_V1.9.11.03_Education_x64\IDE\simlib\gw2a\prim_sim.v' }
if (-not (Test-Path $prim)) { throw "Gowin prim_sim.v not found (set GOWIN_PRIM_SIM)" }
New-Item -ItemType Directory -Force sim\gen | Out-Null

$env:SNES_PRIM_SIM = $prim
@'
import os, re
gen = os.path.join('sim', 'gen')

# cpu.v: '{N{v}} initialisers and array parameters -> regs + initial blocks.
src = open(os.path.join('rtl', 'snestang', 'src', 'cpu.v'), encoding='latin-1').read()
inits = []
def rep(m):
    w, name, n, cnt, val = m.groups()
    inits.append(f"integer i_{name}; initial for (i_{name} = 0; i_{name} < {cnt}; i_{name} = i_{name} + 1) {name}[i_{name}] = {val};")
    return f"reg {w} {name}[0:{n}];"
src = re.sub(r"reg\s*(\[[^\]]+\])\s*(\w+)\s*\[0:(\d+)\]\s*=\s*'\{(\d+)\{([^}]+)\}\};", rep, src)
def tab(m):
    rows = re.findall(r"'\{([^}]*)\}", m.group(1))
    return "reg [1:0] DMA_TRMODE_TAB[0:31];\ninitial begin\n" + "".join(
        f"  DMA_TRMODE_TAB[{r * 4 + c}] = {v.strip()};\n"
        for r, row in enumerate(rows) for c, v in enumerate(row.split(','))) + "end"
src = re.sub(r"parameter \[1:0\] DMA_TRMODE_TAB\[0:7\]\[0:3\] = '\{(.*?)\n\};", tab, src, flags=re.S)
src = re.sub(r"parameter \[1:0\] DMA_TRMODE_LEN\[0:7\] = '\{([^}]*)\};",
    lambda m: "reg [1:0] DMA_TRMODE_LEN[0:7];\ninitial begin\n" + "".join(
        f"  DMA_TRMODE_LEN[{i}] = {v.strip()};\n" for i, v in enumerate(m.group(1).split(','))) + "end", src)
src = re.sub(r"DMA_TRMODE_TAB\[(DMAP\[\w+\]\[2:0\])\]\[(\w+)\]", r"DMA_TRMODE_TAB[{\1, \2}]", src)
assert len(inits) == 9 and src.count("DMA_TRMODE_TAB[{") == 2, "cpu.v conversion out of date"
idx = src.rfind("endmodule")
src = src[:idx] + "\n".join(inits) + "\n" + src[idx:]
open(os.path.join(gen, 'cpu_sim.v'), 'w', encoding='latin-1').write(src)

# Gowin primitives: their ALU clashes with the 65C816 ALU.
p = open(os.environ['SNES_PRIM_SIM'], encoding='latin-1').read()
open(os.path.join(gen, 'prim_sim.v'), 'w', encoding='latin-1').write(
    re.sub(r'(?m)^module ALU \(', 'module GW_PRIM_ALU (', p))

# Empty modules with the real port lists for the top-level peripherals.
stubs = {
    'snes_video_640': 'rtl/tang/snes_video_640.sv', 'snes_gamepad': 'rtl/tang/snes_gamepad.v',
    'controller_adapter': 'rtl/snestang/src/controller_adapter.sv', 'audio_tone': 'rtl/tang/audio_tone.v',
    'i2s_tx': 'rtl/tang/i2s_tx.v', 'iosys': 'rtl/tang/iosys/iosys.v',
}
out = []
for name, f in stubs.items():
    s = open(f, encoding='latin-1').read()
    s = re.sub(r'/\*.*?\*/', '', re.sub(r'//[^\n]*', '', s), flags=re.S)
    m = re.compile(r'module\s+' + name + r'\s*(#\s*\()?').search(s)
    k = m.end()
    def close(k, depth=1):
        while depth:
            depth += (s[k] == '(') - (s[k] == ')'); k += 1
        return k
    if m.group(1): k = close(k)
    k = close(s.index('(', k) + 1)
    hdr = re.sub(r'output\s+(reg|logic)\b', 'output wire', s[m.start():k])
    hdr = re.sub(r'output\s+(?!wire)', 'output wire ', hdr)
    hdr = re.sub(r'(output wire[^,\n]*?)\s*=\s*[^,\n)]+', r'\1', hdr)
    out.append(hdr + ';\nendmodule\n')
out.append('''module DSPn(input CLK, input CE, input RST_N, input ENABLE, input A0, input [7:0] DI,
    output [7:0] DO, input CS_N, input RD_N, input WR_N, input [11:0] DP_ADDR,
    input DP_SEL, input [2:0] VER, input REV);
assign DO = 8'h00;
endmodule
module SRTC(input CLK, input A0, input [7:0] DI, output [7:0] DO, input CS, input CPURD_N,
    input CPUWR_N, input SYSCLKF_CE, input [64:0] EXT_RTC);
assign DO = 8'h00;
endmodule
''')
open(os.path.join(gen, 'snes_top_stubs.sv'), 'w').write('\n'.join(out))
'@ | python -
if ($LASTEXITCODE) { throw 'generating simulation sources failed' }

$src = 'rtl/snestang/src'
$files = @("$src/65C816/common.sv", 'sim/tb_snes_reset_dma.sv', 'rtl/top_tang_nano20k_snes.v',
    "$src/sdram_nano.v", 'sim/sdram_model.v', "$src/main.v", "$src/SNES.v", 'sim/gen/cpu_sim.v',
    "$src/swram.v", "$src/CEGen.v", "$src/smc_parser.v", 'sim/snes_ppu_timing_stub.v',
    "$src/chip/DSP/dsp_data_ram.v", "$src/chip/DSP/DSP_LHRomMap.v", "$src/chip/DSP/OBC1.v",
    "$src/pllr/gowin_pll_snes.v", "$src/pllr/gowin_pll_hdmi.v",
    'sim/gen/snes_top_stubs.sv', 'sim/gen/prim_sim.v')
$files += Get-ChildItem "$src/65C816" -Filter *.v | ForEach-Object { "$src/65C816/$($_.Name)" }
$files += "$src/65C816/mcode.sv"
iverilog -g2012 -DDISABLE_SMP -I $src -s tb_snes_reset_dma -s GSR `
    "-Ptb_snes_reset_dma.RESETS=$Resets" "-Ptb_snes_reset_dma.PAUSE_BASE=$PauseBase" `
    -o sim/gen/tb_snes_reset_dma.vvp @files
if ($LASTEXITCODE) { throw 'iverilog failed for tb_snes_reset_dma' }
$log = vvp -n sim/gen/tb_snes_reset_dma.vvp
$log
if (-not ($log -match '^PASS$')) { throw 'tb_snes_reset_dma failed' }
