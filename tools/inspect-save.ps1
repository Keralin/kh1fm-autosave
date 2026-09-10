# Read-only. Reports the layout of the KH1 save container so an autosave can be written
# into a real slot. Writes nothing.
#
#   powershell -ExecutionPolicy Bypass -File inspect-save.ps1
#   powershell -ExecutionPolicy Bypass -File inspect-save.ps1 -Autosave "C:\path\kh1-autosave.dat"

param(
    [string]$GameData = "$env:USERPROFILE\Documents\KINGDOM HEARTS HD 1.5+2.5 ReMIX",
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
        if ($read -lt $count) { return $buffer[0..($read - 1)] }
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

Write-Host "=== save container ===" -ForegroundColor Cyan
if (-not (Test-Path $GameData)) {
    Write-Host "Game data folder not found: $GameData"
    Write-Host "Pass the right one with -GameData"
    exit 1
}

$candidates = Get-ChildItem $GameData -Recurse -Filter *.png -ErrorAction SilentlyContinue
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
Write-Host "slot  entry     body        length    name                    modified"

# Slot 0's entry sits inside the XOR-encrypted first 0xF0 bytes of the table, so its name
# reads as garbage here. Every other slot is plaintext.
foreach ($i in 0..7 + 98 + 99 + 100 + 199) {
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
    if ($i -eq 0) { $shown = "$shown  [xor-encrypted region]" }
    Write-Host ("{0,4}  {1,8:x}  {2,10:x}  {3,8:x}  {4,-22}  {5}" -f `
        $i, $entryOffset, ($PNG_HEADER + $ENTRY_COUNT * $ENTRY_LEN + $i * $STRIDE), $length, $shown, $when)
}

Write-Host ""
Write-Host "=== first populated slot, raw entry ===" -ForegroundColor Cyan
$found = $false
foreach ($i in 1..($ENTRY_COUNT - 1)) {
    $entryOffset = $PNG_HEADER + $i * $ENTRY_LEN
    $entry = Read-Bytes $save.FullName $entryOffset $ENTRY_LEN
    if ((Read-CString $entry) -ne "") {
        Write-Host "slot $i entry at $('{0:x}' -f $entryOffset), first 0x60 bytes:"
        Write-Host (Show-Hex $entry[0..0x5F])
        $bodyOffset = $PNG_HEADER + $ENTRY_COUNT * $ENTRY_LEN + $i * $STRIDE
        Write-Host "body at $('{0:x}' -f $bodyOffset), first 16 bytes:"
        Write-Host (Show-Hex (Read-Bytes $save.FullName $bodyOffset 16))
        $found = $true
        break
    }
}
if (-not $found) { Write-Host "No populated slot found. Save the game once in-game first." }

Write-Host ""
Write-Host "=== continue-block dump ===" -ForegroundColor Cyan
if ($Autosave -eq "") {
    $hit = Get-ChildItem "$env:ProgramFiles*", "C:\", "$GameData" -Recurse -Filter "kh1-autosave.dat" -ErrorAction SilentlyContinue -Depth 6 | Select-Object -First 1
    if ($null -ne $hit) { $Autosave = $hit.FullName }
}
if ($Autosave -eq "" -or -not (Test-Path $Autosave)) {
    Write-Host "kh1-autosave.dat not found. Pass it with -Autosave, or run the mod once first."
} else {
    $size = (Get-Item $Autosave).Length
    Write-Host "$Autosave"
    Write-Host ("size {0} bytes, expected {1}" -f $size, $BODY_LEN)
    $head = Read-Bytes $Autosave 0 16
    Write-Host "first 16 bytes: $(Show-Hex $head)"
    $magic = [BitConverter]::ToUInt32($head, 0)
    if ($magic -eq 5) {
        Write-Host "magic code 5: this is a KH1 Final Mix save body" -ForegroundColor Green
    } else {
        Write-Host "magic code $magic, expected 5 for Final Mix (4 for vanilla)" -ForegroundColor Yellow
    }
}
