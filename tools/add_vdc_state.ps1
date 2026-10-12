param([switch]$Apply)
$ErrorActionPreference = 'Stop'
$path = Join-Path (Split-Path -Parent $PSScriptRoot) 'rtl/huc6270.vhd'
$source = [IO.File]::ReadAllText($path)
if ($source.Contains('SS_DATA')) { throw 'VDC state interface already present' }
$masked = [regex]::Replace($source, '--[^\r\n]*', { param($match) ' ' * $match.Length })
$types = @{}
$types['std_logic'] = @{ Width = 1; Kind = 'bit' }
foreach ($match in [regex]::Matches($masked, '(?is)type\s+(\w+)\s+is\s*\(([^;]+)\);')) {
    $count = ($match.Groups[2].Value -split ',').Count
    $types[$match.Groups[1].Value] = @{ Width = [int][Math]::Ceiling([Math]::Log($count, 2)); Kind = 'enum'; Name = $match.Groups[1].Value }
}
function Get-Type([string]$text) {
    $text = $text.Trim()
    if ($text -match '^(std_logic_vector|unsigned)\s*\(\s*(\d+)\s+downto\s+(\d+)\s*\)$') {
        return @{ Width = [int]$Matches[2] - [int]$Matches[3] + 1; Kind = $Matches[1] }
    }
    if ($types.ContainsKey($text)) { return $types[$text] }
    throw "Unknown state type: $text"
}
foreach ($match in [regex]::Matches($masked, '(?is)type\s+(\w+)\s+is\s+record\s+(.*?)end\s+record;')) {
    $fields = @()
    $width = 0
    foreach ($field in [regex]::Matches($match.Groups[2].Value, '(\w+)\s*:\s*([^;]+);')) {
        $type = Get-Type $field.Groups[2].Value
        $fields += @{ Name = $field.Groups[1].Value; Type = $type; Offset = $width }
        $width += $type.Width
    }
    $types[$match.Groups[1].Value] = @{ Width = $width; Kind = 'record'; Fields = $fields }
}
foreach ($match in [regex]::Matches($masked, '(?is)type\s+(\w+)\s+is\s+array\s*\(0\s+to\s+([^\)]+)\)\s+of\s+([^;]+);')) {
    $bound = $match.Groups[2].Value.Trim()
    if ($bound -eq 'MAX_SPRITES-1') { $count = 64; $last = 'MAX_SPRITES-1' }
    elseif ($bound -match '^\d+$') { $count = [int]$bound + 1; $last = $bound }
    else { throw "Unknown state array bound: $bound" }
    $element = Get-Type $match.Groups[3].Value
    $types[$match.Groups[1].Value] = @{ Width = $count * $element.Width; Kind = 'array'; Element = $element; Last = $last }
}
$signals = @{}
foreach ($match in [regex]::Matches($masked, '(?im)^\s*signal\s+(\w+)\s*:\s*([^;:=]+)')) {
    $signals[$match.Groups[1].Value] = $match.Groups[2].Value.Trim()
}
$aliases = @{}
foreach ($match in [regex]::Matches($masked, '(?im)^\s*alias\s+(\w+)\s*:[^;]+?\bis\s+(\w+)')) {
    $aliases[$match.Groups[1].Value] = $match.Groups[2].Value
}
$processes = @()
$owners = @{}
foreach ($match in [regex]::Matches($masked, '(?is)\bprocess\s*\([^\)]*\).*?end\s+process;')) {
    $clock = [regex]::Match($match.Value, '(?i)(?:elsif|if)\s+rising_edge\s*\(\s*CLK\s*\)\s+then')
    if (-not $clock.Success) { continue }
    $body = $match.Value.Substring($clock.Index + $clock.Length)
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($assignment in [regex]::Matches($body, '(?im)(?:^\s*|\bthen\s+|\belse\s+|=>\s*|;\s*)(\w+)(?:\([^;\r\n]*?\))?(?:\.\w+(?:\([^;\r\n]*?\))?)*\s*<=')) {
        $name = $assignment.Groups[1].Value
        if ($aliases.ContainsKey($name)) { $name = $aliases[$name] }
        if ($signals.ContainsKey($name)) { [void]$names.Add($name) }
    }
    $variables = @()
    foreach ($variable in [regex]::Matches($match.Value.Substring(0, $clock.Index), '(?i)variable\s+(\w+)\s*:\s*([^;]+);')) {
        $name = $variable.Groups[1].Value
        if ($name -notin @('fetch_cnt', 'RC_CNT_UPDATED', 'SPR_TILE_PIX', 'RENDER_STATE')) { continue }
        $typeText = $variable.Groups[2].Value.Trim()
        if ($typeText -eq 'integer range 0 to 2') { $type = @{ Width = 2; Kind = 'integer' } }
        else { $type = Get-Type $typeText }
        $variables += @{ Name = $name; Type = $type; Mirror = 'ss_' + $name }
    }
    $entry = @{ Match = $match; Clock = $clock; Names = @($names | Sort-Object); Variables = $variables; Restore = [Collections.Generic.List[string]]::new() }
    foreach ($name in $entry.Names) {
        if ($owners.ContainsKey($name)) { throw "Multiple state owners: $name" }
        $owners[$name] = $entry
    }
    $processes += $entry
}
$reads = [Collections.Generic.List[string]]::new()
$offset = 0
function Emit-State([string]$name, $type, [string]$base, $restore, [string]$operator = '<=') {
    if ($type.Kind -eq 'array') {
        $reads.Add("ss_$($name)_map : for state_index in 0 to $($type.Last) generate")
        $restore.Add("for state_index in 0 to $($type.Last) loop")
        Emit-State "$name(state_index)" $type.Element "($base + state_index * $($type.Element.Width))" $restore
        $restore.Add('end loop;')
        $reads.Add('end generate;')
    } elseif ($type.Kind -eq 'record') {
        foreach ($field in $type.Fields) {
            Emit-State "$name.$($field.Name)" $field.Type "($base + $($field.Offset))" $restore
        }
    } else {
        if ($type.Kind -eq 'bit') { $slice = "($base)" } else { $slice = "($base + $($type.Width - 1) downto $base)" }
        $read = $name
        $value = "SS_DATA$slice"
        switch ($type.Kind) {
            'unsigned' { $read = "std_logic_vector($name)"; $value = "unsigned($value)" }
            'integer' { $read = "std_logic_vector(to_unsigned($name, $($type.Width)))"; $value = "to_integer(unsigned($value))" }
            'enum' { $read = "std_logic_vector(to_unsigned($($type.Name)'pos($name), $($type.Width)))"; $value = "$($type.Name)'val(to_integer(unsigned($value)))" }
        }
        $reads.Add("SS_Q$slice <= $read;")
        $restore.Add("$name $operator $value;")
    }
}
foreach ($name in @($owners.Keys | Sort-Object)) {
    $type = Get-Type $signals[$name]
    Emit-State $name $type "$offset" $owners[$name].Restore
    $offset += $type.Width
}
$declarations = [Collections.Generic.List[string]]::new()
foreach ($entry in $processes) {
    foreach ($variable in $entry.Variables) {
        $type = $variable.Type
        $base = $offset
        $offset += $type.Width
        $declarations.Add("signal $($variable.Mirror) : std_logic_vector($($type.Width-1) downto 0) := (others => '0');")
        $reads.Add("SS_Q($($offset-1) downto $base) <= $($variable.Mirror);")
        if ($type.Kind -eq 'bit') { $value = "SS_DATA($base)"; $mirror = "(0 => $($variable.Name))" }
        elseif ($type.Kind -eq 'integer') { $value = "to_integer(unsigned(SS_DATA($($offset-1) downto $base)))"; $mirror = "std_logic_vector(to_unsigned($($variable.Name), $($type.Width)))" }
        else { $value = "unsigned(SS_DATA($($offset-1) downto $base))"; $mirror = "std_logic_vector($($variable.Name))" }
        $entry.Restore.Add("$($variable.Name) := $value;")
        $variable['MirrorExpression'] = $mirror
    }
}
if ($offset -gt 7904) { throw "VDC state exceeds allocated register area: $offset" }
$reads.Add("SS_Q(7903 downto $offset) <= (others => '0');")
foreach ($entry in @($processes | Sort-Object { $_.Match.Index } -Descending)) {
    $original = $source.Substring($entry.Match.Index, $entry.Match.Length)
    $start = $entry.Clock.Index + $entry.Clock.Length
    $finish = [regex]::Match($original, '(?is)\s*end\s+if;\s*end\s+process;\s*$')
    if (-not $finish.Success) { throw 'Unknown VDC clock process ending' }
    $body = $original.Substring($start, $finish.Index - $start)
    $replacement = $original.Substring(0, $start) + "`nif SS_HOLD = '1' and SS_LOAD = '1' then`n" +
        ($entry.Restore -join "`n") + "`nelsif SS_HOLD = '0' then`n" + $body + "`nend if;`n"
    foreach ($variable in $entry.Variables) { $replacement += "$($variable.Mirror) <= $($variable.MirrorExpression);`n" }
    $replacement += $original.Substring($finish.Index)
    $source = $source.Remove($entry.Match.Index, $entry.Match.Length).Insert($entry.Match.Index, $replacement)
}
$source = $source.Replace("`tCLR_A  <= CLR_A + 1 when rising_edge(CLK);`n`tCLR_WE <= CLR_MEM   when rising_edge(CLK);", @'
process(CLK)
begin
    if rising_edge(CLK) then
        if SS_HOLD = '1' and SS_LOAD = '1' then
            CLR_A <= unsigned(SS_DATA(7911 downto 7904));
            CLR_WE <= SS_DATA(7912);
        elsif SS_HOLD = '0' then
            CLR_A <= CLR_A + 1;
            CLR_WE <= CLR_MEM;
        end if;
    end if;
end process;
'@)
$source = [regex]::Replace($source, '(?i)\bCLR_A\s*<=\s*CLR_A\s*\+\s*1\s+when\s+rising_edge\(CLK\);\s*CLR_WE\s*<=\s*CLR_MEM\s+when\s+rising_edge\(CLK\);', @'
process(CLK)
begin
    if rising_edge(CLK) then
        if SS_HOLD = '1' and SS_LOAD = '1' then
            CLR_A <= unsigned(SS_DATA(7911 downto 7904));
            CLR_WE <= SS_DATA(7912);
        elsif SS_HOLD = '0' then
            CLR_A <= CLR_A + 1;
            CLR_WE <= CLR_MEM;
        end if;
    end if;
end process;
'@)
$reads.Add("SS_Q(7911 downto 7904) <= std_logic_vector(CLR_A);")
$reads.Add("SS_Q(7912) <= CLR_WE;")
$reads.Add("SS_Q(7935 downto 7913) <= (others => '0');")
$reads.Add("SS_Q(8191 downto 7936) <= (others => '0');")
$source = $source.Insert($source.IndexOf('begin', $source.IndexOf('architecture rtl')), ($declarations -join "`n") + "`n")
$begin = $source.IndexOf('begin', $source.IndexOf('architecture rtl')) + 5
$source = $source.Insert($begin, "`n" + ($reads -join "`n") + "`n")
$ports = @'
        SS_HOLD : in std_logic := '0';
        SS_LOAD : in std_logic := '0';
        SS_DATA : in std_logic_vector(8191 downto 0) := (others => '0');
        SS_Q : out std_logic_vector(8191 downto 0) := (others => '0');
'@
$source = [regex]::Replace($source, '(?m)(\s*CLR_MEM\s*:\s*in\s+std_logic;)', ('$1' + "`n" + $ports), 1)
Write-Output "VDC register state: $offset bits; processes=$($processes.Count)"
if ($Apply) { [IO.File]::WriteAllText($path, $source, [Text.UTF8Encoding]::new($false)) }