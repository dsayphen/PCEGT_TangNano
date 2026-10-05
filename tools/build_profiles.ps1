param(
    [ValidateSet('pce', 'sgx', 'cd', 'all')]
    [string]$Profile = 'all',
    [string]$GowinShell
)

$ErrorActionPreference = 'Stop'
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
    cd  = 2
}
$profiles = if ($Profile -eq 'all') { @('pce', 'sgx', 'cd') } else { @($Profile) }
$profileTop = Join-Path $workDir 'top_tang_nano20k.v'

New-Item -ItemType Directory -Force -Path $workDir, $outputRoot | Out-Null

foreach ($name in $profiles) {
    $stem = "PCE_GT_TangNano_$name"
    $projectCopy = Join-Path $root "$stem.gprj"
    $configCopy = Join-Path $root "impl/${stem}_process_config.json"
    $tclScript = Join-Path $workDir "build_$name.tcl"
    $id = $profileIds[$name]

    try {
        $topSource = Get-Content (Join-Path $root 'rtl/top_tang_nano20k.v') -Raw
        $parameterPattern = "parameter \[1:0\] CORE_PROFILE = 2'd3"
        if ([regex]::Matches($topSource, $parameterPattern).Count -ne 1) {
            throw 'Expected exactly one default CORE_PROFILE parameter in top_tang_nano20k.v.'
        }
        $profileSource = [regex]::Replace(
            $topSource,
            $parameterPattern,
            "parameter [1:0] CORE_PROFILE = 2'd$id",
            1)
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
        $topFile[0].SetAttribute('path', 'impl/profile-build/top_tang_nano20k.v')
        $project.Save($projectCopy)

        Add-Type -AssemblyName System.Web.Extensions
        $jsonSerializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $buildConfig = $jsonSerializer.DeserializeObject((Get-Content $configPath -Raw))
        $buildConfig['OUTPUT_BASE_NAME'] = $stem
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

        $profileOutput = Join-Path $outputRoot $name
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
        Remove-Item $projectCopy, $configCopy, $tclScript, $profileTop `
            -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Profile artifacts and reports: $outputRoot"