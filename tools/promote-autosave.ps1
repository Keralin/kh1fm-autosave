# Writes an autosave snapshot into a real save slot. Refuses to run while the game is open,
# because that is what corrupts the container: the game keeps the same file and rewrites it on
# its own schedule, and two writers make a mixed file.
#
#   powershell -ExecutionPolicy Bypass -File promote-autosave.ps1
#   powershell -ExecutionPolicy Bypass -File promote-autosave.ps1 -Autosave "C:\path\kh1-autosave-prev.dat"

param(
    [string]$Autosave = "",
    [string]$Container = "",
    [int]$Slot = 98
)

$PNG_HEADER = 0x70
$ENTRY_LEN = 0x158
$ENTRY_COUNT = 200
$BODY_BASE = 0x10D30
$STRIDE = 0x16C40
$BODY_LEN = 0x16C00
$FILE_SIZE = 18788509
$MAGIC_FM = 5

function Read-Bytes($path, $offset, $count) {
    $stream = [IO.File]::OpenRead($path)
    try {
        $buffer = New-Object byte[] $count
        $stream.Position = $offset
        [void]$stream.Read($buffer, 0, $count)
        return $buffer
    } finally { $stream.Close() }
}

# The game must not be running. This is the whole point of doing it here.
$running = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like "*KINGDOM*" }
if ($running) {
    foreach ($p in $running) { Write-Host "RUNNING: $($p.ProcessName)" -ForegroundColor Red }
    Write-Host "Close the game first. Writing the container while it is open is what corrupts saves."
    exit 1
}

if ($Container -eq "") {
    $roots = @()
    $docs = [Environment]::GetFolderPath('MyDocuments')
    foreach ($base in @($docs, (Join-Path $env:USERPROFILE "Documents"), (Join-Path $env:OneDrive "Documents"))) {
        if (-not $base) { continue }
        $roots += (Join-Path $base "My Games\KINGDOM HEARTS HD 1.5+2.5 ReMIX")
        $roots += (Join-Path $base "KINGDOM HEARTS HD 1.5+2.5 ReMIX")
    }
    foreach ($root in ($roots | Select-Object -Unique)) {
        if (-not (Test-Path $root)) { continue }
        $hit = Get-ChildItem $root -Recurse -Filter "KHFM*.png" -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -eq $FILE_SIZE } | Select-Object -First 1
        if ($null -ne $hit) { $Container = $hit.FullName; break }
    }
}
if ($Container -eq "" -or -not (Test-Path $Container)) {
    Write-Host "Save container not found. Pass it with -Container ""<path to KHFM_WW.png>"""
    exit 1
}
if ((Get-Item $Container).Length -ne $FILE_SIZE) {
    Write-Host "$Container is not $FILE_SIZE bytes, refusing to touch it."
    exit 1
}

if ($Autosave -eq "") {
    foreach ($dir in @($PSScriptRoot, (Get-Location).Path)) {
        $hit = Get-ChildItem $dir -Recurse -Filter "kh1-autosave.dat" -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -ne $hit) { $Autosave = $hit.FullName; break }
    }
}
if ($Autosave -eq "" -or -not (Test-Path $Autosave)) {
    Write-Host "Snapshot not found. Pass it with -Autosave ""<path to kh1-autosave.dat>"""
    exit 1
}

$body = [IO.File]::ReadAllBytes($Autosave)
if ($body.Length -ne $BODY_LEN) {
    Write-Host "$Autosave is $($body.Length) bytes, expected $BODY_LEN. Refusing."
    exit 1
}
$magic = [BitConverter]::ToUInt32($body, 0)
if ($magic -ne $MAGIC_FM) {
    Write-Host "$Autosave starts with magic $magic, expected $MAGIC_FM for Final Mix. Refusing."
    exit 1
}

# Slot 0's entry is XOR'd with a 16-byte key held in the clear at table offset 0xE0. Its name
# gives the product code prefix this install uses.
$raw = Read-Bytes $Container $PNG_HEADER 0xF0
$key = New-Object byte[] 16
[Array]::Copy($raw, 0xE0, $key, 0, 16)
$plain = New-Object byte[] 0xF0
for ($i = 0; $i -lt 0xF0; $i++) { $plain[$i] = [byte](($raw[$i] -bxor $key[$i % 16]) -band 0xFF) }
$end = [Array]::IndexOf($plain, [byte]0)
if ($end -le 0) {
    Write-Host "Cannot read a save name from slot 0. Save once in-game first."
    exit 1
}
$slot0Name = [Text.Encoding]::ASCII.GetString($plain, 0, $end)
if ($slot0Name -notmatch '^(.*)-\d+$') {
    Write-Host "Slot 0 is named '$slot0Name', which is not the expected <prefix>-NN. Refusing."
    exit 1
}
$name = "{0}-{1:d2}" -f $matches[1], ($Slot + 1)

$backup = "$Container.bak-" + (Get-Date -Format "yyyyMMdd-HHmmss")
Copy-Item $Container $backup
Write-Host "backup:    $backup"
Write-Host "container: $Container"
Write-Host "snapshot:  $Autosave"
Write-Host "writing slot $Slot as $name"

$entryOffset = $PNG_HEADER + $Slot * $ENTRY_LEN
$bodyOffset = $BODY_BASE + $Slot * $STRIDE

$entry = New-Object byte[] 0x58
$nameBytes = [Text.Encoding]::ASCII.GetBytes($name)
[Array]::Copy($nameBytes, 0, $entry, 0, $nameBytes.Length)
$now = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
[Array]::Copy([BitConverter]::GetBytes($now), 0, $entry, 0x40, 4)
[Array]::Copy([BitConverter]::GetBytes($now), 0, $entry, 0x48, 4)
[Array]::Copy([BitConverter]::GetBytes([int]$BODY_LEN), 0, $entry, 0x50, 4)

$fs = [IO.File]::Open($Container, 'Open', 'ReadWrite')
try {
    # Blank the name, write the body, then write the entry, so an interrupted write leaves an
    # empty-looking slot rather than a valid entry over a half-written save.
    $fs.Position = $entryOffset
    $fs.Write((New-Object byte[] 0x10), 0, 0x10)
    $fs.Position = $bodyOffset
    $fs.Write($body, 0, $body.Length)
    $fs.Position = $entryOffset
    $fs.Write($entry, 0, $entry.Length)
    $fs.Flush()
} finally { $fs.Close() }

# Read it back rather than trusting the write.
$checkEntry = Read-Bytes $Container $entryOffset 0x58
$checkEnd = [Array]::IndexOf($checkEntry, [byte]0)
$checkName = [Text.Encoding]::ASCII.GetString($checkEntry, 0, $checkEnd)
$checkLen = [BitConverter]::ToInt32($checkEntry, 0x50)
$checkBody = Read-Bytes $Container $bodyOffset 16
$sameHead = $true
for ($i = 0; $i -lt 16; $i++) { if ($checkBody[$i] -ne $body[$i]) { $sameHead = $false } }

if ($checkName -eq $name -and $checkLen -eq $BODY_LEN -and $sameHead -and
    (Get-Item $Container).Length -eq $FILE_SIZE) {
    Write-Host ""
    Write-Host "done. Save $($Slot + 1) should be in the Load menu next time you start the game." -ForegroundColor Green
    Write-Host "If anything looks wrong, restore: Copy-Item ""$backup"" ""$Container"" -Force"
} else {
    Write-Host ""
    Write-Host "verification failed, restoring the backup" -ForegroundColor Red
    Copy-Item $backup $Container -Force
    exit 1
}
