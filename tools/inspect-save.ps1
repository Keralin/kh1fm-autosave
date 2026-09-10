# Read-only. Reports the layout of the KH1 save container so an autosave can be written
# into a real slot. Writes nothing.
#
#   powershell -ExecutionPolicy Bypass -File inspect-save.ps1
#   powershell -ExecutionPolicy Bypass -File inspect-save.ps1 -GameData "D:\somewhere\KINGDOM HEARTS HD 1.5+2.5 ReMIX"
#   powershell -ExecutionPolicy Bypass -File inspect-save.ps1 -Autosave "C:\path\kh1-autosave.dat"

param(
    [string]$GameData = "",
    [string]$Autosave = ""
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

# Documents gets redirected (OneDrive, or a moved profile folder), so ask Windows where it is
# instead of gluing $env:USERPROFILE and "Documents" together.
function Get-DataRoots {
    $roots = @()
    $docs = [Environment]::GetFolderPath('MyDocuments')
    if ($docs) { $roots += $docs; $roots += (Join-Path $docs "My Games") }
    if ($env:OneDrive) {
        $roots += (Join-Path $env:OneDrive "Documents")
        $roots += (Join-Path $env:OneDrive "Documents\My Games")
    }
    $roots += (Join-Path $env:USERPROFILE "Documents")
    $roots += (Join-Path $env:USERPROFILE "Documents\My Games")
    $roots += (Join-Path $env:USERPROFILE "Saved Games")
    return $roots | Select-Object -Unique
}

function Get-SteamGameDirs {
    $dirs = @()
    $steam = ""
    try { $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath } catch { }
    if (-not $steam) { return $dirs }

    $libraries = @($steam.Replace('/', '\'))
    $vdf = Join-Path $libraries[0] "steamapps\libraryfolders.vdf"
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

Write-Host "=== save container ===" -ForegroundColor Cyan

if ($GameData -eq "") {
    $tried = Get-DataRoots
    foreach ($root in $tried) {
        if (-not (Test-Path $root)) { continue }
        $hit = Get-ChildItem $root -Directory -Filter "KINGDOM HEARTS*" -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -ne $hit) { $GameData = $hit.FullName; break }
    }
    if ($GameData -eq "") {
        Write-Host "No 'KINGDOM HEARTS*' folder under any of these:"
        $tried | ForEach-Object { Write-Host "  $_" }
        Write-Host ""
        Write-Host "Find it yourself and pass it: -GameData ""<path>"""
        Write-Host "It is the folder holding a 'scripts' subfolder and the save .png files."
        exit 1
    }
}

Write-Host "game data: $GameData"
if (-not (Test-Path $GameData)) { Write-Host "That path does not exist."; exit 1 }
Write-Host ""

$candidates = Get-ChildItem $GameData -Recurse -Filter *.png -ErrorAction SilentlyContinue
if ($candidates.Count -eq 0) { Write-Host "No .png save files in there at all." }
foreach ($f in $candidates) {
    $tag = ""
    if ($f.Length -eq $KH1_SIZE) { $tag = "  <-- KH1FM" }
    Write-Host ("{0,12}  {1}{2}" -f $f.Length, $f.FullName.Replace("$GameData\", ""), $tag)
}

$save = $candidates | Where-Object { $_.Length -eq $KH1_SIZE } | Select-Object -First 1
if ($null -eq $save) {
    Write-Host ""
    Write-Host "No file of exactly $KH1_SIZE bytes. Either KH1 has never been saved, or this"
    Write-Host "build uses a container size the save editor does not know. Report the sizes above."
    exit 1
}

Write-Host ""
Write-Host "=== slots in $($save.Name) ===" -ForegroundColor Cyan
Write-Host "slot     entry        body    length  name                      modified"

# Slot 0's entry sits inside the XOR-encrypted first 0xF0 bytes of the table, so its name
# reads as garbage here. Every other slot is plaintext.
$slots = @(0..7) + @(98, 99, 100, 199)
foreach ($i in $slots) {
    $entryOffset = $PNG_HEADER + $i * $ENTRY_LEN
    $entry = Read-Bytes $save.FullName $entryOffset $ENTRY_LEN
    $name = Read-CString $entry
    $length = [BitConverter]::ToInt32($entry, 0x50)
    $modified = [BitConverter]::ToInt32($entry, 0x48)
    $when = ""
    if ($modified -gt 0) {
        $when = [DateTimeOffset]::FromUnixTimeSeconds($modified).LocalDateTime.ToString("yyyy-MM-dd HH:mm")
    }
    $shown = $name
    if ($shown -eq "") { $shown = "(empty)" }
    if ($i -eq 0) { $shown = "$shown [xor region]" }
    Write-Host ("{0,4}  {1,8:x}  {2,10:x}  {3,8:x}  {4,-24}  {5}" -f `
        $i, $entryOffset, ($PNG_HEADER + $ENTRY_COUNT * $ENTRY_LEN + $i * $STRIDE), $length, $shown, $when)
}

Write-Host ""
Write-Host "=== first populated slot, raw entry ===" -ForegroundColor Cyan
$found = $false
foreach ($i in 1..($ENTRY_COUNT - 1)) {
    $entryOffset = $PNG_HEADER + $i * $ENTRY_LEN
    $entry = Read-Bytes $save.FullName $entryOffset $ENTRY_LEN
    if ((Read-CString $entry) -ne "") {
        Write-Host "slot $i entry at 0x$('{0:x}' -f $entryOffset), first 0x60 bytes:"
        Write-Host (Show-Hex $entry[0..0x5F])
        $bodyOffset = $PNG_HEADER + $ENTRY_COUNT * $ENTRY_LEN + $i * $STRIDE
        Write-Host "body at 0x$('{0:x}' -f $bodyOffset), first 16 bytes:"
        Write-Host (Show-Hex (Read-Bytes $save.FullName $bodyOffset 16))
        $found = $true
        break
    }
}
if (-not $found) { Write-Host "No populated slot found. Save the game once in-game first." }

Write-Host ""
Write-Host "=== continue-block dump ===" -ForegroundColor Cyan
if ($Autosave -eq "") {
    $searchIn = @($PSScriptRoot, (Get-Location).Path) + (Get-SteamGameDirs) + @($GameData)
    foreach ($dir in ($searchIn | Select-Object -Unique)) {
        if (-not $dir -or -not (Test-Path $dir)) { continue }
        $hit = Get-ChildItem $dir -Recurse -Filter "kh1-autosave.dat" -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -ne $hit) { $Autosave = $hit.FullName; break }
    }
}
if ($Autosave -eq "" -or -not (Test-Path $Autosave)) {
    Write-Host "kh1-autosave.dat not found. Run the mod once, or pass it with -Autosave."
    Write-Host "Looked in the script folder, the current folder, the Steam game folders and the game data folder."
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
    Write-Host "magic code $magic, expected 5 for Final Mix. The continue block may not be a save body." -ForegroundColor Yellow
}
