param(
    [ValidateSet('pce', 'sgx', 'sgx_rv_diag', 'sgx_no_hdmi_audio', 'sgx_gpio26_input', 'sgx_gpio29_input', 'sgx_gpio29_pulse', 'cd', 'cdprobe', 'cd_sgx', 'cd_vdc1', 'cd_vdc1_gg', 'cd_vdc1_quiet', 'snes', 'all')]
    [string]$Profile = 'all',
    [string]$GowinShell,
    [switch]$SnesSdramPhase180,
    [switch]$SnesMemoryDiagnostic,
    [switch]$SnesUpstreamRamDiagnostic,
    [switch]$SnesWramWaitDiagnostic
)

$ErrorActionPreference = 'Stop'
if ($SnesSdramPhase180 -and $Profile -ne 'snes') {
    throw '-SnesSdramPhase180 is a diagnostic option for -Profile snes only.'
}
if ($SnesMemoryDiagnostic -and $Profile -ne 'snes') {
    throw '-SnesMemoryDiagnostic is a diagnostic option for -Profile snes only.'
}
if ($SnesUpstreamRamDiagnostic -and $Profile -ne 'snes') {
    throw '-SnesUpstreamRamDiagnostic is a diagnostic option for -Profile snes only.'
}
if ($SnesWramWaitDiagnostic -and $Profile -ne 'snes') {
    throw '-SnesWramWaitDiagnostic is a diagnostic option for -Profile snes only.'
}
if (@($SnesSdramPhase180, $SnesMemoryDiagnostic, $SnesUpstreamRamDiagnostic, $SnesWramWaitDiagnostic).Where({ $_ }).Count -gt 1) {
    throw 'Run one SNES diagnostic at a time.'
}
$root = Split-Path -Parent $PSScriptRoot
$projectPath = Join-Path $root 'PCE_GT_TangNano.gprj'
$configPath = Join-Path $root 'impl/PCE_GT_TangNano_process_config.json'
$workDir = Join-Path $root 'impl/profile-build'
$outputRoot = Join-Path $root 'impl/profiles'
$flashSlotSize = 1MB

if (-not $GowinShell) {
    if ($env:GOWIN_HOME) {
        $GowinShell = Join-Path $env:GOWIN_HOME 'IDE/bin/gw_sh.exe'
    } else {
        $GowinShell = 'G:\Gowin\Gowin_V1.9.11.03_Education_x64\IDE\bin\gw_sh.exe'
    }
}
if (-not (Test-Path $GowinShell)) {
    throw "Gowin Tcl shell not found: $GowinShell. Pass -GowinShell or set GOWIN_HOME."
}

$profileIds = @{
    pce = 0
    sgx = 1
    sgx_rv_diag = 1
    sgx_no_hdmi_audio = 1
    sgx_gpio26_input = 1
    sgx_gpio29_input = 1
    sgx_gpio29_pulse = 1
    cd  = 2
    cdprobe = 2
    cd_sgx = 2
    cd_vdc1 = 2
    cd_vdc1_gg = 2
    cd_vdc1_quiet = 2
    snes = 4
}
$profiles = if ($Profile -eq 'all') { @('sgx', 'cd', 'snes') } else { @($Profile) }

New-Item -ItemType Directory -Force -Path $workDir, $outputRoot | Out-Null

foreach ($name in $profiles) {
    $outputName = if ($SnesSdramPhase180) { 'snes_sdram_phase180' } elseif ($SnesMemoryDiagnostic) { 'snes_memory_diag' } elseif ($SnesUpstreamRamDiagnostic) { 'snes_upstream_ram' } elseif ($SnesWramWaitDiagnostic) { 'snes_wram_wait' } else { $name }
    $stem = "PCE_GT_TangNano_$outputName"
    $projectCopy = Join-Path $root "$stem.gprj"
    $configCopy = Join-Path $root "impl/${stem}_process_config.json"
    $tclScript = Join-Path $workDir "build_$name.tcl"
    $constraintsCopy = Join-Path $workDir "$stem.cst"
    $id = $profileIds[$name]

    $topName = if ($name -eq 'snes') { 'top_tang_nano20k_snes.v' } else { 'top_tang_nano20k.v' }
    $profileTop = Join-Path $workDir $topName
    try {
        $topSourcePath = Join-Path $root "rtl/$topName"
        $topSource = Get-Content $topSourcePath -Raw
        $profileSource = $topSource
        if ($SnesWramWaitDiagnostic) {
            $profileSource = $profileSource.Replace(
                'parameter SNES_WRAM_WAIT = 0',
                'parameter SNES_WRAM_WAIT = 1')
        }
        if ($SnesUpstreamRamDiagnostic) {
            $profileSource = $profileSource.Replace(
                'parameter SNES_UPSTREAM_RAM_LAYOUT = 0',
                'parameter SNES_UPSTREAM_RAM_LAYOUT = 1')
        }
        if ($SnesMemoryDiagnostic) {
            $profileSource = $profileSource.Replace(
                'parameter SNES_MEMORY_DIAGNOSTIC = 0',
                'parameter SNES_MEMORY_DIAGNOSTIC = 1')
        }
        if ($SnesSdramPhase180) {
            $profileSource = $profileSource.Replace(
            'parameter SNES_SDRAM_PHASE = "1010"',
            'parameter SNES_SDRAM_PHASE = "1000"')
        }
        if ($name -ne 'snes') {
            $parameterPattern = "parameter \[1:0\] CORE_PROFILE = 2'd1"
            if ([regex]::Matches($topSource, $parameterPattern).Count -ne 1) {
                throw 'Expected exactly one default CORE_PROFILE parameter in top_tang_nano20k.v.'
            }
            $profileSource = [regex]::Replace(
                $topSource,
                $parameterPattern,
                "parameter [1:0] CORE_PROFILE = 2'd$id",
                1)
        }
        if ($name -in @('sgx_gpio26_input', 'sgx_gpio29_input')) {
            $profileSource = [regex]::Replace(
                $profileSource,
                'parameter CORE_RECONFIG_INPUT_ONLY = 0',
                'parameter CORE_RECONFIG_INPUT_ONLY = 1',
                1)
            if ($name -eq 'sgx_gpio26_input') {
                $profileSource = [regex]::Replace(
                    $profileSource,
                    'parameter CORE_RECONFIG_PIN = 29',
                    'parameter CORE_RECONFIG_PIN = 26',
                    1)
            }
        } elseif ($name -eq 'sgx_gpio29_pulse') {
            $profileSource = [regex]::Replace(
                $profileSource,
                'parameter CORE_RECONFIG_OUTPUT_TEST = 0',
                'parameter CORE_RECONFIG_OUTPUT_TEST = 1',
                1)
        } elseif ($name -eq 'sgx_rv_diag') {
            $profileSource = [regex]::Replace(
                $profileSource,
                'parameter CORE_RV_DIAGNOSTIC = 0',
                'parameter CORE_RV_DIAGNOSTIC = 1',
                1)
        } elseif ($name -eq 'cdprobe') {
            $profileSource = [regex]::Replace(
                $profileSource,
                'parameter \[1:0\] CORE_LOGIC_PROFILE = CORE_PROFILE',
                "parameter [1:0] CORE_LOGIC_PROFILE = 2'd3",
                1)
        } elseif ($name -eq 'cd_sgx') {
            $profileSource = [regex]::Replace(
                $profileSource,
                'parameter CORE_EXTRA_SGX = 0',
                'parameter CORE_EXTRA_SGX = 1',
                1)
        } elseif ($name -eq 'cd_vdc1') {
            $profileSource = [regex]::Replace(
                $profileSource,
                'parameter CORE_EXTRA_VDC1 = 0',
                'parameter CORE_EXTRA_VDC1 = 1',
                1)
        } elseif ($name -eq 'cd_vdc1_gg') {
            $profileSource = [regex]::Replace(
                $profileSource,
                'parameter CORE_EXTRA_VDC1 = 0',
                'parameter CORE_EXTRA_VDC1 = 1',
                1)
            $profileSource = [regex]::Replace(
                $profileSource,
                'parameter CORE_EXTRA_CHEATS = 0',
                'parameter CORE_EXTRA_CHEATS = 1',
                1)
        } elseif ($name -eq 'cd_vdc1_quiet') {
            $profileSource = [regex]::Replace(
                $profileSource,
                'parameter CORE_EXTRA_VDC1 = 0',
                'parameter CORE_EXTRA_VDC1 = 1',
                1)
            $profileSource = [regex]::Replace(
                $profileSource,
                'parameter CORE_VDC1_MEMORY = 1',
                'parameter CORE_VDC1_MEMORY = 0',
                1)
        } elseif ($name -eq 'sgx_no_hdmi_audio') {
            $profileSource = [regex]::Replace(
                $profileSource,
                'parameter CORE_HDMI_AUDIO = 1',
                'parameter CORE_HDMI_AUDIO = 0',
                1)
        }
        [System.IO.File]::WriteAllText(
            $profileTop,
            $profileSource,
            [System.Text.UTF8Encoding]::new($false))

        $projectText = Get-Content $projectPath -Raw
        $projectText = $projectText -replace '^<\?xml version="1" encoding="UTF-8"\?>',
            '<?xml version="1.0" encoding="UTF-8"?>'
        $project = New-Object System.Xml.XmlDocument
        $project.LoadXml($projectText)
        $topFile = @($project.Project.FileList.File | Where-Object {
            $_.GetAttribute('path') -eq 'rtl/top_tang_nano20k.v'
        })
        if ($topFile.Count -ne 1) {
            throw 'Expected exactly one top_tang_nano20k.v entry in PCE_GT_TangNano.gprj.'
        }
        if ($name -eq 'snes') {
            $topFile[0].SetAttribute('path', 'impl/profile-build/top_tang_nano20k_snes.v')
            $topFile[0].SetAttribute('enable', '1')

            $snesSources = @(
                'rtl/snestang/src/65C816/ALU.v',
                'rtl/snestang/src/65C816/AddSubBCD.v',
                'rtl/snestang/src/65C816/AddrGen.v',
                'rtl/snestang/src/65C816/BCDAdder.v',
                'rtl/snestang/src/65C816/P65C816.v',
                'rtl/snestang/src/65C816/adder4.v',
                'rtl/snestang/src/65C816/bit_adder.v',
                'rtl/snestang/src/65C816/common.sv',
                'rtl/snestang/src/65C816/mcode.sv',
                'rtl/snestang/src/CEGen.v',
                'rtl/snestang/src/chip/DSP/DSP_LHRomMap.v',
                'rtl/snestang/src/chip/DSP/DSPn.v',
                'rtl/snestang/src/chip/DSP/OBC1.v',
                'rtl/snestang/src/chip/DSP/SRTC.v',
                'rtl/snestang/src/chip/dsp/dsp_data_ram.v',
                'rtl/snestang/src/controller_adapter.sv',
                'rtl/snestang/src/cpu.v',
                'rtl/snestang/src/dsp.v',
                'rtl/snestang/src/dual_clk_fifo.v',
                'rtl/snestang/src/gowin_dpb_cgram.v',
                'rtl/snestang/src/gowin_dpb_hoam.v',
                'rtl/snestang/src/gowin_dpb_oam.v',
                'rtl/snestang/src/hdmi2/audio_clock_regeneration_packet.sv',
                'rtl/snestang/src/hdmi2/audio_info_frame.sv',
                'rtl/snestang/src/hdmi2/audio_sample_packet.sv',
                'rtl/snestang/src/hdmi2/auxiliary_video_information_info_frame.sv',
                'rtl/snestang/src/hdmi2/hdmi.sv',
                'rtl/snestang/src/hdmi2/packet_assembler.sv',
                'rtl/snestang/src/hdmi2/packet_picker.sv',
                'rtl/snestang/src/hdmi2/serializer.sv',
                'rtl/snestang/src/hdmi2/source_product_description_info_frame.sv',
                'rtl/snestang/src/hdmi2/tmds_channel.sv',
                'rtl/snestang/src/main.v',
                'rtl/snestang/src/pllr/gowin_pll_hdmi.v',
                'rtl/snestang/src/pllr/gowin_pll_snes.v',
                'rtl/snestang/src/ppu.v',
                'rtl/snestang/src/ppucgram.v',
                'rtl/snestang/src/ppuhoam.v',
                'rtl/snestang/src/ppuoam.v',
                'rtl/snestang/src/sdram_nano.v',
                'rtl/snestang/src/smc_parser.v',
                'rtl/snestang/src/smp.v',
                'rtl/snestang/src/snes.v',
                'rtl/tang/snes_video_640.sv',
                'rtl/snestang/src/spc700/_spc700_package.v',
                'rtl/snestang/src/spc700/addrgen.v',
                'rtl/snestang/src/spc700/addsub.v',
                'rtl/snestang/src/spc700/alu.v',
                'rtl/snestang/src/spc700/bcdadj.v',
                'rtl/snestang/src/spc700/mcode.v',
                'rtl/snestang/src/spc700/muldiv.v',
                'rtl/snestang/src/spc700/spc700.v',
                'rtl/snestang/src/swram.v',
                'rtl/snestang/src/uart_tx_V2.v'
            )
            foreach ($source in $snesSources) {
                if (-not (Test-Path (Join-Path $root $source))) {
                    throw "Missing SNES source: $source"
                }
                $sourceEntry = $project.CreateElement('File')
                $sourceEntry.SetAttribute('path', $source)
                $sourceEntry.SetAttribute('type', 'file.verilog')
                $sourceEntry.SetAttribute('enable', '1')
                [void]$project.Project.FileList.AppendChild($sourceEntry)
            }
            $pceVhdl = @($project.Project.FileList.File | Where-Object {
                $_.GetAttribute('type') -eq 'file.vhdl'
            })
            foreach ($vhdlFile in $pceVhdl) {
                [void]$project.Project.FileList.RemoveChild($vhdlFile)
            }

            $sdcFile = @($project.Project.FileList.File | Where-Object {
                $_.GetAttribute('type') -eq 'file.sdc'
            })
            if ($sdcFile.Count -ne 1) {
                throw 'Expected exactly one timing constraints file in PCE_GT_TangNano.gprj.'
            }
            $sdcFile[0].SetAttribute('path', 'constraints/snes_nano20k.sdc')
        } else {
            $topFile[0].SetAttribute('path', 'impl/profile-build/top_tang_nano20k.v')
        }
        if ($name -in @('sgx_gpio26_input', 'sgx_gpio29_input', 'sgx_gpio29_pulse')) {
            $constraintsFile = @($project.Project.FileList.File | Where-Object {
                $_.GetAttribute('path') -eq 'constraints/tang_nano20k.cst'
            })
            if ($constraintsFile.Count -ne 1) {
                throw 'Expected exactly one tang_nano20k.cst project entry.'
            }
            $constraintsText = Get-Content (Join-Path $root 'constraints/tang_nano20k.cst') -Raw
            $outputConstraint = 'IO_PORT "fpga_reconfig_n" IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=4;'
            if (-not $constraintsText.Contains($outputConstraint)) {
                throw 'Expected the reload output constraint before creating diagnostic constraints.'
            }
            if ($name -ne 'sgx_gpio29_pulse') {
                $constraintsText = $constraintsText.Replace(
                    $outputConstraint,
                    'IO_PORT "fpga_reconfig_n" IO_TYPE=LVCMOS33 PULL_MODE=NONE;')
            }
            if ($name -eq 'sgx_gpio26_input') {
                $gpio29Location = 'IO_LOC  "fpga_reconfig_n" 29;'
                if (-not $constraintsText.Contains($gpio29Location)) {
                    throw 'Expected the GPIO29 location before creating GPIO26 input constraints.'
                }
                $constraintsText = $constraintsText.Replace(
                    $gpio29Location,
                    'IO_LOC  "fpga_reconfig_n" 26;')
            }
            [System.IO.File]::WriteAllText(
                $constraintsCopy,
                $constraintsText,
                [System.Text.UTF8Encoding]::new($false))
            $constraintsFile[0].SetAttribute('path', "impl/profile-build/$stem.cst")
        }
        if ($name -eq 'sgx_no_hdmi_audio') {
            $audioFiles = @($project.Project.FileList.File | Where-Object {
                $_.GetAttribute('path') -in @(
                    'rtl/tang/audio_sampler_48k.sv',
                    'rtl/tang/hdmi_audio_packetizer.sv'
                )
            })
            if ($audioFiles.Count -ne 2) {
                throw 'Expected the HDMI audio sampler and packetizer project entries.'
            }
            foreach ($audioFile in $audioFiles) {
                [void]$project.Project.FileList.RemoveChild($audioFile)
            }
        }
        $project.Save($projectCopy)

        Add-Type -AssemblyName System.Web.Extensions
        $jsonSerializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $buildConfig = $jsonSerializer.DeserializeObject((Get-Content $configPath -Raw))
        $buildConfig['OUTPUT_BASE_NAME'] = $stem
        if ($name -eq 'snes') {
            $buildConfig['TopModule'] = 'top_tang_nano20k_snes'
            $buildConfig['GwSyn_Loop_Limit'] = 8192
        }
        [System.IO.File]::WriteAllText(
            $configCopy,
            $jsonSerializer.Serialize($buildConfig),
            [System.Text.UTF8Encoding]::new($false))

        @(
            "open_project ./$stem.gprj"
            'run all'
            'exit'
        ) | Set-Content -Path $tclScript -Encoding ascii

        Write-Host "Building $name profile (CORE_PROFILE=$id)..."
        Push-Location $root
        try {
            & $GowinShell $tclScript
            if ($LASTEXITCODE -ne 0) {
                throw "Gowin build failed for profile '$name' with exit code $LASTEXITCODE."
            }
        } finally {
            Pop-Location
        }

        $pnrDir = Join-Path $root 'impl/pnr'
        $binary = Join-Path $pnrDir "$stem.bin"
        $fs = Join-Path $pnrDir "$stem.fs"
        foreach ($artifact in @($binary, $fs)) {
            if (-not (Test-Path $artifact)) {
                throw "Expected Gowin artifact was not generated: $artifact"
            }
        }
        $binarySize = (Get-Item $binary).Length
        if ($binarySize -gt $flashSlotSize) {
            throw "$stem.bin is $binarySize bytes and exceeds the 1 MiB candidate flash slot."
        }

        $profileOutput = Join-Path $outputRoot $outputName
        foreach ($subdir in @('gwsynthesis', 'pnr')) {
            $sourceDir = Join-Path $root "impl/$subdir"
            $destinationDir = Join-Path $profileOutput $subdir
            New-Item -ItemType Directory -Force -Path $destinationDir | Out-Null
            Get-ChildItem $sourceDir -Filter "$stem*" -File |
                Copy-Item -Destination $destinationDir -Force
        }

        Write-Host ("{0}: .bin {1} bytes ({2:N1} KiB), .fs {3:N1} MiB" -f
            $name, $binarySize, ($binarySize / 1KB), ((Get-Item $fs).Length / 1MB))
    } finally {
        Remove-Item $projectCopy, $configCopy, $tclScript, $profileTop, $constraintsCopy `
            -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Profile artifacts and reports: $outputRoot"