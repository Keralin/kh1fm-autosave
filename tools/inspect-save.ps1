# Read-only. Finds every KH1 save container on this machine and reports which one holds the
# game saves, plus the layout needed to write an autosave into a real slot. Writes nothing.
#
#   powershell -ExecutionPolicy Bypass -File inspect-save.ps1
#   powershell -ExecutionPolicy Bypass -File inspect-save.ps1 -DeepScan
#   powershell -ExecutionPolicy Bypass -File inspect-save.ps1 -GameData "D:\path\to\folder"
#   powershell -ExecutionPolicy Bypass -File inspect-save.ps1 -Autosave "C:\path\kh1-autosave.dat"

param(
    [string]$GameData = "",
    [string]$Autosave = "",
    [string]$Compare = "",
    [switch]$DeepScan
)

$PNG_HEADER = 0x70
$ENTRY_LEN = 0x158
$ENTRY_COUNT = 200
$STRIDE = 0x16C40
$BODY_LEN = 0x16C00
$KH1_SIZE = 18788509  # 0x11EB09D, what KingdomSaveEditor accepts as a PC KH1FM archive

function Read-Bytes($path, $offset, $count) {
    $stream = [IO.File]::OpenRead($path)
    try {
        $buffer = New-Object byte[] $count
        $stream.Position = $offset
        $read = $stream.Read($buffer, 0, $count)
        if ($read -lt $count -and $read -gt 0) { return $buffer[0..($read - 1)] }
        return $buffer
    } finally { $stream.Close() }
}

function Show-Hex($bytes) { ($bytes | ForEach-Object { $_.ToString("x2") }) -join " " }

function Read-CString($bytes) {
    $end = [Array]::IndexOf($bytes, [byte]0)
    if ($end -lt 0) { $end = $bytes.Length }
    if ($end -eq 0) { return "" }
    return [Text.Encoding]::ASCII.GetString($bytes, 0, $end)
}

function Clean-Name($name) {
    $out = ($name.ToCharArray() | ForEach-Object {
        if ([int]$_ -ge 32 -and [int]$_ -lt 127) { $_ } else { "." }
    }) -join ""
    if ($out.Length -gt 26) { $out = $out.Substring(0, 26) }
    return $out
}

# Documents gets redirected (OneDrive, a moved profile folder), so ask Windows where it is
# rather than gluing USERPROFILE and "Documents" together.
# The first 0xF0 bytes of the entry table are XOR'd with a 16-byte key that sits, in the clear,
# at table offset 0xE0. Only slot 0's entry falls inside that range, which is why its name and
# length read as noise until it is decrypted.
function Get-TableHead($path) {
    $raw = Read-Bytes $path $PNG_HEADER 0xF0
    $key = New-Object byte[] 16
    [Array]::Copy($raw, 0xE0, $key, 0, 16)
    $out = New-Object byte[] 0xF0
    for ($i = 0; $i -lt 0xF0; $i++) { $out[$i] = [byte](($raw[$i] -bxor $key[$i % 16]) -band 0xFF) }
    return @{ Key = $key; Plain = $out }
}

function Get-DataRoots {
    $roots = @()
    $docs = [Environment]::GetFolderPath('MyDocuments')
    if ($docs) { $roots += $docs; $roots += (Join-Path $docs "My Games") }
    if ($env:OneDrive) {
        $roots += (Join-Path $env:OneDrive "Documents")
        $roots += (Join-Path $env:OneDrive "Documents\My Games")
    }
    if ($env:OneDriveConsumer) { $roots += (Join-Path $env:OneDriveConsumer "Documents") }
    $roots += (Join-Path $env:USERPROFILE "Documents")
    $roots += (Join-Path $env:USERPROFILE "Documents\My Games")
    $roots += (Join-Path $env:USERPROFILE "Saved Games")
    $roots += (Join-Path $env:LOCALAPPDATA "KINGDOM HEARTS HD 1.5+2.5 ReMIX")
    return $roots | Select-Object -Unique
}

function Get-SteamPath {
    try { return (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath.Replace('/', '\') }
    catch { return "" }
}

function Get-SteamGameDirs {
    $dirs = @()
    $steam = Get-SteamPath
    if ($steam -eq "") { return $dirs }
    $libraries = @($steam)
    $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
    if (Test-Path $vdf) {
        foreach ($line in (Get-Content $vdf)) {
            if ($line -match '"path"\s+"(.+)"') { $libraries += $matches[1].Replace('\\', '\') }
        }
    }
    foreach ($lib in ($libraries | Select-Object -Unique)) {
        $common = Join-Path $lib "steamapps\common"
        if (Test-Path $common) {
            $dirs += Get-ChildItem $common -Directory -Filter "KINGDOM HEARTS*" -ErrorAction SilentlyContinue |
                ForEach-Object { $_.FullName }
        }
    }
    return $dirs
}

# Compare two containers region by region, to see which slots a bad write actually touched.
if ($Compare -ne "") {
    if ($GameData -eq "") {
        Write-Host "-Compare needs the live container too: -GameData is not it, pass -Autosave"
        Write-Host "Usage: -Compare ""<backup.png>"" -Container ""<live.png>"" is not supported;"
        Write-Host "instead pass the two files as -Compare ""<a.png>"" and -Autosave ""<b.png>"""
    }
    $a = $Compare
    $b = $Autosave
    if (-not (Test-Path $a) -or -not (Test-Path $b)) {
        Write-Host "Compare needs two existing files: -Compare <a.png> -Autosave <b.png>"
        exit 1
    }
    Write-Host "=== comparing containers ===" -ForegroundColor Cyan
    Write-Host "A: $a"
    Write-Host "B: $b"
    $ba = [IO.File]::ReadAllBytes($a)
    $bb = [IO.File]::ReadAllBytes($b)
    if ($ba.Length -ne $bb.Length) { Write-Host "sizes differ: $($ba.Length) vs $($bb.Length)" }

    $limit = [Math]::Min($ba.Length, $bb.Length)
    $regions = @()
    $regions += @{ Name = "png header"; Start = 0; End = $PNG_HEADER }
    for ($i = 0; $i -lt $ENTRY_COUNT; $i++) {
        $regions += @{ Name = "entry $i"; Start = ($PNG_HEADER + $i * $ENTRY_LEN); End = ($PNG_HEADER + ($i + 1) * $ENTRY_LEN) }
    }
    for ($i = 0; $i -lt $ENTRY_COUNT; $i++) {
        $regions += @{ Name = "body $i"; Start = ($BODY_BASE + $i * $STRIDE); End = ($BODY_BASE + $i * $STRIDE + $BODY_LEN) }
    }
    $diffs = 0
    foreach ($r in $regions) {
        if ($r.Start -ge $limit) { continue }
        $stop = [Math]::Min($r.End, $limit)
        $first = -1
        $count = 0
        for ($j = $r.Start; $j -lt $stop; $j++) {
            if ($ba[$j] -ne $bb[$j]) {
                if ($first -lt 0) { $first = $j }
                $count++
            }
        }
        if ($count -gt 0) {
            Write-Host ("  {0,-12} differs: {1} bytes, first at 0x{2:x}" -f $r.Name, $count, $first)
            $diffs++
        }
    }
    if ($diffs -eq 0) { Write-Host "  identical across every slot" }
    exit 0
}

Write-Host "=== is the game running? ===" -ForegroundColor Cyan
$running = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like "*KINGDOM*" }
if ($running) {
    foreach ($p in $running) { Write-Host "RUNNING: $($p.ProcessName)" -ForegroundColor Yellow }
    Write-Host "The container on disk can be stale while the game holds it. Close the game and re-run."
} else {
    Write-Host "No KINGDOM HEARTS process, the files on disk are current."
}

Write-Host ""
Write-Host "=== candidate folders ===" -ForegroundColor Cyan
$dirs = @()
if ($GameData -ne "") {
    $dirs += $GameData
} else {
    # Collect every match, not just the first. Several installs can coexist (Epic and Steam,
    # a OneDrive-redirected Documents next to a local one), and only one holds the saves.
    foreach ($root in (Get-DataRoots)) {
        if (-not (Test-Path $root)) { continue }
        $dirs += Get-ChildItem $root -Directory -Filter "KINGDOM HEARTS*" -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName }
    }
    $steam = Get-SteamPath
    if ($steam -ne "" -and (Test-Path (Join-Path $steam "userdata"))) {
        $dirs += (Join-Path $steam "userdata")
    }
    $dirs += Get-SteamGameDirs
}
$dirs = $dirs | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
if ($dirs.Count -eq 0) {
    Write-Host "Nothing found. Roots checked:"
    Get-DataRoots | ForEach-Object { Write-Host "  $_" }
    Write-Host "Pass the folder with -GameData ""<path>"", or try -DeepScan."
    exit 1
}
$dirs | ForEach-Object { Write-Host "  $_" }

Write-Host ""
Write-Host "=== save containers found ===" -ForegroundColor Cyan
$pngs = @()
foreach ($dir in $dirs) {
    $pngs += Get-ChildItem $dir -Recurse -Filter *.png -ErrorAction SilentlyContinue
}
if ($DeepScan) {
    Write-Host "deep scanning $env:USERPROFILE, this takes a while..."
    $pngs += Get-ChildItem $env:USERPROFILE -Recurse -File -Filter *.png -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -eq $KH1_SIZE }
}
$pngs = $pngs | Sort-Object FullName -Unique
if ($pngs.Count -eq 0) { Write-Host "No .png files in any candidate folder." }
foreach ($f in $pngs) {
    $tag = ""
    if ($f.Length -eq $KH1_SIZE) { $tag = "  <-- KH1FM container" }
    Write-Host ("{0,12}  {1}{2}" -f $f.Length, $f.FullName, $tag)
}

$containers = $pngs | Where-Object { $_.Length -eq $KH1_SIZE }
if ($containers.Count -eq 0) {
    Write-Host ""
    Write-Host "No file of exactly $KH1_SIZE bytes. Try -DeepScan. If that finds nothing either,"
    Write-Host "this build stores saves in a format the save editor does not know."
    exit 1
}

$bestSave = $null
$BODY_BASE = $PNG_HEADER + $ENTRY_COUNT * $ENTRY_LEN

foreach ($c in $containers) {
    Write-Host ""
    Write-Host "=== slots in $($c.FullName) ===" -ForegroundColor Cyan
    Write-Host "slot     entry        body    length  name                        body[0:8]            modified"

    $tableHead = Get-TableHead $c.FullName
    Write-Host ("xor key at 0x{0:x}: {1}" -f ($PNG_HEADER + 0xE0), (Show-Hex $tableHead.Key))

    $stream = [IO.File]::OpenRead($c.FullName)
    try {
        $entry = New-Object byte[] $ENTRY_LEN
        $head = New-Object byte[] 8
        $used = 0

        for ($i = 0; $i -lt $ENTRY_COUNT; $i++) {
            $entryOffset = $PNG_HEADER + $i * $ENTRY_LEN
            $bodyOffset = $BODY_BASE + $i * $STRIDE

            $stream.Position = $entryOffset
            [void]$stream.Read($entry, 0, $ENTRY_LEN)
            $stream.Position = $bodyOffset
            [void]$stream.Read($head, 0, 8)

            if ($i -eq 0) { [Array]::Copy($tableHead.Plain, 0, $entry, 0, 0xF0) }

            $name = Read-CString $entry
            $length = [BitConverter]::ToInt32($entry, 0x50)

            # A slot counts as used if EITHER its table entry or its body says so. Judging by
            # the entry alone would hide a save whose metadata is blank but whose body is written.
            $bodyLive = $false
            foreach ($b in $head) { if ($b -ne 0) { $bodyLive = $true; break } }
            if ($name -eq "" -and $length -eq 0 -and -not $bodyLive -and $i -ne 99) { continue }
            $used++

            $modified = [BitConverter]::ToInt32($entry, 0x48)
            $when = ""
            if ($modified -gt 0) {
                $when = [DateTimeOffset]::FromUnixTimeSeconds($modified).LocalDateTime.ToString("yyyy-MM-dd HH:mm")
            }
            $shown = Clean-Name $name
            if ($shown -eq "") { $shown = "(no name)" }
            if ($i -eq 0) { $shown = "$shown [xor]" }
            if ($i -eq 99) { $shown = "$shown <- target" }

            Write-Host ("{0,4}  {1,8:x}  {2,10:x}  {3,8:x}  {4,-26}  {5}  {6}" -f `
                $i, $entryOffset, $bodyOffset, $length, $shown, (Show-Hex $head), $when)

            if ($null -eq $bestSave -and $bodyLive -and [BitConverter]::ToUInt32($head, 0) -ge 4 -and [BitConverter]::ToUInt32($head, 0) -le 5) {
                $bestSave = @{ File = $c.FullName; Slot = $i; Entry = $entry.Clone(); EntryOffset = $entryOffset }
            }
        }
        Write-Host "$used of $ENTRY_COUNT slots show any content (slot 99 always listed)"
    } finally { $stream.Close() }
}

# If no slot looks like a save, the layout itself is suspect. Show what the table region
# actually contains so the real stride and naming are visible instead of assumed.
if ($null -eq $bestSave) {
    Write-Host ""
    Write-Host "=== structure of the table region (layout check) ===" -ForegroundColor Cyan
    $c = $containers[0]
    $region = Read-Bytes $c.FullName 0 ($BODY_BASE + 0x100)
    $text = [Text.Encoding]::ASCII.GetString($region)

    Write-Host "printable runs of 6+ chars in the first $('0x{0:x}' -f $region.Length) bytes:"
    $hits = 0
    foreach ($m in [regex]::Matches($text, '[\x20-\x7E]{6,}')) {
        Write-Host ("  0x{0:x8}  {1}" -f $m.Index, $m.Value)
        $hits++
        if ($hits -ge 40) { Write-Host "  ..."; break }
    }
    if ($hits -eq 0) { Write-Host "  none" }

    Write-Host "offsets holding the value 0x16C00 (a full save body length):"
    $needle = [BitConverter]::GetBytes([int]$BODY_LEN)
    $found = 0
    for ($i = 0; $i -le $region.Length - 4; $i++) {
        if ($region[$i] -eq $needle[0] -and $region[$i+1] -eq $needle[1] -and
            $region[$i+2] -eq $needle[2] -and $region[$i+3] -eq $needle[3]) {
            Write-Host ("  0x{0:x8}  (entry would start at 0x{1:x})" -f $i, ($i - 0x50))
            $found++
            if ($found -ge 20) { Write-Host "  ..."; break }
        }
    }
    if ($found -eq 0) { Write-Host "  none, so no entry in this file declares a full save body" }
}

Write-Host ""
Write-Host "=== raw entry of a real game save ===" -ForegroundColor Cyan
if ($null -eq $bestSave) {
    Write-Host "No slot anywhere has a full save body ($BODY_LEN bytes)."
    Write-Host "Every container found holds only the system file, so the live save is elsewhere."
    Write-Host "Re-run with -DeepScan."
} else {
    Write-Host "$($bestSave.File) slot $($bestSave.Slot), entry at 0x$('{0:x}' -f $bestSave.EntryOffset) (decrypted if slot 0):"
    Write-Host (Show-Hex $bestSave.Entry[0..0x5F])
    $bodyOffset = $PNG_HEADER + $ENTRY_COUNT * $ENTRY_LEN + $bestSave.Slot * $STRIDE
    Write-Host "body at 0x$('{0:x}' -f $bodyOffset), first 16 bytes:"
    Write-Host (Show-Hex (Read-Bytes $bestSave.File $bodyOffset 16))
}

Write-Host ""
Write-Host "=== continue-block dump ===" -ForegroundColor Cyan
if ($Autosave -eq "") {
    $searchIn = @($PSScriptRoot, (Get-Location).Path) + (Get-SteamGameDirs) + $dirs
    foreach ($dir in ($searchIn | Select-Object -Unique)) {
        if (-not $dir -or -not (Test-Path $dir)) { continue }
        $hit = Get-ChildItem $dir -Recurse -Filter "kh1-autosave.dat" -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -ne $hit) { $Autosave = $hit.FullName; break }
    }
}
if ($Autosave -eq "" -or -not (Test-Path $Autosave)) {
    Write-Host "kh1-autosave.dat not found. Run the mod once, or pass it with -Autosave."
    exit 0
}
$size = (Get-Item $Autosave).Length
Write-Host "$Autosave"
Write-Host ("size {0} bytes, expected {1}" -f $size, $BODY_LEN)
$head = Read-Bytes $Autosave 0 16
Write-Host "first 16 bytes: $(Show-Hex $head)"
$magic = [BitConverter]::ToUInt32($head, 0)
if ($magic -eq 5) {
    Write-Host "magic code 5: this is a KH1 Final Mix save body" -ForegroundColor Green
} elseif ($magic -eq 4) {
    Write-Host "magic code 4: vanilla KH1 save body, not Final Mix" -ForegroundColor Yellow
} else {
    Write-Host "magic code $magic, expected 5. The continue block may not be a save body." -ForegroundColor Yellow
}
