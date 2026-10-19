param(
    [string]$InputDirectory,
    [string]$OutputDirectory,
    [switch]$CombinedImage,
    [switch]$MegaDriveOnly,
    [switch]$SnesOnly
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$inputDirectoryProvided = -not [string]::IsNullOrWhiteSpace($InputDirectory)
if (-not $InputDirectory) { $InputDirectory = Join-Path $root 'impl/pnr' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'impl/core-slots' }
$slotSize = 1MB
$manifestOffset = $slotSize - 32

if (-not ('CoreSlotCrc' -as [type])) {
    Add-Type -TypeDefinition @'
public static class CoreSlotCrc {
    public static uint Compute(byte[] bytes) {
        uint crc = 0xffffffffu;
        foreach (byte value in bytes) {
            crc ^= value;
            for (int bit = 0; bit < 8; bit++)
                crc = (crc >> 1) ^ ((crc & 1) != 0 ? 0xedb88320u : 0u);
        }
        return ~crc;
    }
}
'@
}

if ([CoreSlotCrc]::Compute([Text.Encoding]::ASCII.GetBytes('123456789')) -ne [uint32]3421780262) {
    throw 'CRC32 self-test failed.'
}

$profiles = @(
    @{ Name = 'sgx'; Id = 1; Slot = 1; Label = 'HuCard' },
    @{ Name = 'cd'; Id = 2; Slot = 2; Label = 'CD-Rom' },
    @{ Name = 'snes'; Id = 4; Slot = 3; Label = 'Nintendo' },
    @{ Name = 'nesgb'; Id = 5; Slot = 4; Label = 'Nintendo 8-bit' }
)
if ($MegaDriveOnly -and $SnesOnly) {
    throw '-MegaDriveOnly and -SnesOnly are mutually exclusive.'
}
if ($MegaDriveOnly -or $SnesOnly) {
    if ($CombinedImage) { throw '-MegaDriveOnly cannot be combined with -CombinedImage (slot 5 contains firmware).' }
    if ($MegaDriveOnly) {
        $profiles = @(@{ Name = 'megadrive'; Id = 6; Slot = 6; Label = 'Mega Drive experimental' })
    } else {
        $profiles = @(@{ Name = 'snes'; Id = 4; Slot = 3; Label = 'Nintendo' })
    }
}

$profileSources = @{}
foreach ($profile in $profiles) {
    $source = Join-Path $InputDirectory ("PCE_GT_TangNano_{0}.bin" -f $profile.Name)
    if (-not $inputDirectoryProvided) {
        $archivedSource = Join-Path $root ("impl/profiles/{0}/pnr/PCE_GT_TangNano_{0}.bin" -f $profile.Name)
        if (Test-Path $archivedSource) { $source = $archivedSource }
    }
    if (-not (Test-Path $source)) { throw "Missing bitstream: $source" }
    $profileSources[$profile.Name] = $source
    $size = (Get-Item $source).Length
    if ($size -le 0 -or $size -gt $manifestOffset) {
        throw "$source must contain 1..$manifestOffset bytes."
    }
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
foreach ($profile in $profiles) {
    $source = $profileSources[$profile.Name]
    $binary = [IO.File]::ReadAllBytes($source)
    $crc = [CoreSlotCrc]::Compute($binary)
    $slot = New-Object byte[] $slotSize
    for ($index = 0; $index -lt $slotSize; $index++) { $slot[$index] = 255 }
    [Array]::Copy($binary, 0, $slot, 0, $binary.Length)
    $stream = New-Object IO.MemoryStream(,$slot)
    $writer = New-Object IO.BinaryWriter($stream)
    $stream.Position = $manifestOffset
    $writer.Write([uint32]0x50434543)
    $writer.Write([uint32]1)
    $writer.Write([uint32]$profile.Id)
    $writer.Write([uint32]$binary.Length)
    $writer.Write([uint32]$crc)
    $writer.Flush()
    $destination = Join-Path $OutputDirectory ("{0}_slot.bin" -f $profile.Name)
    [IO.File]::WriteAllBytes($destination, $slot)
    $writer.Dispose()
    $stream.Dispose()
    Write-Host ("{0}: {1} -> 0x{2:X6}, size={3}, CRC32={4:X8}" -f
        $profile.Label, $destination, ($profile.Slot * $slotSize), $binary.Length, $crc)
}
if ($CombinedImage) {
    $order = @('sgx', 'sgx', 'cd', 'snes', 'nesgb')
    $combined = New-Object byte[] ($order.Count * $slotSize)
    for ($index = 0; $index -lt $combined.Length; $index++) { $combined[$index] = 255 }
    for ($slotIndex = 0; $slotIndex -lt $order.Count; $slotIndex++) {
        if (-not $order[$slotIndex]) { continue }
        $sourceSlot = Join-Path $OutputDirectory ("{0}_slot.bin" -f $order[$slotIndex])
        $bytes = [IO.File]::ReadAllBytes($sourceSlot)
        if ($bytes.Length -ne $slotSize) { throw "Invalid slot size: $sourceSlot" }
        [Array]::Copy($bytes, 0, $combined, ($slotIndex * $slotSize), $slotSize)
    }
    $destination = Join-Path $OutputDirectory 'cores_sgx_cd_snes_nesgb.bin'
    [IO.File]::WriteAllBytes($destination, $combined)
    Write-Host ("Combined cores: {0} -> 0x000000, {1} bytes; firmware not included." -f
        $destination, $combined.Length)
}
Write-Host 'Program these slot images as raw SPI flash data, without erasing the entire flash.'
Write-Host 'Bitstreams must include flash PIO support. Keep firmware at 0x500000.'