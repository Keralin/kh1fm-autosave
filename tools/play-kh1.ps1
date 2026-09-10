# Promotes the last autosave snapshot into save 99 and then starts the game.
#
# The container is only ever written here, with the game not yet running, so there is no second
# writer to race. After a crash you just launch through this and save 99 is waiting in the Load
# menu, holding the last room you walked into.
#
#   powershell -ExecutionPolicy Bypass -File play-kh1.ps1
#   powershell -ExecutionPolicy Bypass -File play-kh1.ps1 -Exe "D:\...\KINGDOM HEARTS FINAL MIX.exe"

param(
    [string]$Exe = "",
    [string]$Autosave = "",
    [switch]$NoLaunch
)

$running = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like "*KINGDOM*" }
if ($running) {
    Write-Host "The game is already running, nothing to do." -ForegroundColor Yellow
    exit 0
}

$promote = Join-Path $PSScriptRoot "promote-autosave.ps1"
if (-not (Test-Path $promote)) {
    Write-Host "promote-autosave.ps1 is missing from $PSScriptRoot"
    exit 1
}

$args = @{}
if ($Autosave -ne "") { $args["Autosave"] = $Autosave }
& $promote @args
$promoted = $LASTEXITCODE -eq 0

if (-not $promoted) {
    # A missing snapshot is normal on a first run, so this is not a reason to block the game.
    Write-Host ""
    Write-Host "Nothing promoted, starting the game anyway." -ForegroundColor Yellow
}

if ($NoLaunch) { exit 0 }

if ($Exe -eq "") {
    $libraries = @()
    try {
        $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath.Replace('/', '\')
        $libraries += $steam
        $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
        if (Test-Path $vdf) {
            foreach ($line in (Get-Content $vdf)) {
                if ($line -match '"path"\s+"(.+)"') { $libraries += $matches[1].Replace('\\', '\') }
            }
        }
    } catch { }

    foreach ($lib in ($libraries | Select-Object -Unique)) {
        $common = Join-Path $lib "steamapps\common"
        if (-not (Test-Path $common)) { continue }
        $hit = Get-ChildItem $common -Recurse -Depth 2 -Filter "*FINAL MIX*.exe" -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -ne $hit) { $Exe = $hit.FullName; break }
    }
}

if ($Exe -eq "" -or -not (Test-Path $Exe)) {
    Write-Host ""
    Write-Host "Could not find the game exe. Pass it with -Exe ""<path>"", or start the game yourself:"
    Write-Host "the promotion above is already done."
    exit 0
}

Write-Host ""
Write-Host "launching $Exe"
Start-Process $Exe
