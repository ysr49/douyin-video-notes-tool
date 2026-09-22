$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$SkillSource = Join-Path $Root ".agents\skills"

Write-Host "Installing Douyin GPU video-notes workflow..." -ForegroundColor Cyan

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw "Node.js is required. Install Node.js first."
}

$chromePath = $env:CHROME_PATH
if (-not $chromePath) {
    $chromePath = "C:\Program Files\Google\Chrome\Application\chrome.exe"
}
if (-not (Test-Path -LiteralPath $chromePath -PathType Leaf)) {
    Write-Warning "Chrome was not found at $chromePath. Set CHROME_PATH if Chrome is installed elsewhere."
}

function Find-Executable([string[]]$Names, [string[]]$Fallbacks = @()) {
    foreach ($name in $Names) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
    foreach ($path in $Fallbacks) {
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { return $path }
    }
    return $null
}

$idm = Find-Executable @("IDMan.exe") @(
    "C:\Program Files (x86)\Internet Download Manager\IDMan.exe",
    "C:\Program Files\Internet Download Manager\IDMan.exe"
)
$ffprobe = Find-Executable @("ffprobe.exe", "ffprobe")
$ffmpeg = Find-Executable @("ffmpeg.exe", "ffmpeg")

if (-not $idm) { Write-Warning "IDM was not found. Douyin downloads need IDMan.exe." }
if (-not $ffprobe) { Write-Warning "ffprobe was not found. Add ffmpeg to PATH." }
if (-not $ffmpeg) { Write-Warning "ffmpeg was not found. Bilibili/YouTube merges need it." }

if (-not (Test-Path -LiteralPath (Join-Path $Root "node_modules\playwright-core"))) {
    Write-Host "Installing Node dependencies..." -ForegroundColor Cyan
    Push-Location $Root
    npm install
    Pop-Location
}

$skillTargets = @(
    (Join-Path $env:USERPROFILE ".agents\skills"),
    (Join-Path $env:USERPROFILE ".codex\skills")
)
if ($env:CODEX_HOME) {
    $skillTargets += (Join-Path $env:CODEX_HOME "skills")
} elseif (Test-Path -LiteralPath "D:\CodexHome") {
    $skillTargets += "D:\CodexHome\skills"
}

$skillNames = @(
    "douyin-video-notes",
    "video-link-workflow",
    "idm-download",
    "gpu-transcribe",
    "gpu-workflow"
)

foreach ($targetRoot in $skillTargets) {
    if (-not (Test-Path -LiteralPath (Split-Path $targetRoot -Parent))) { continue }
    New-Item -ItemType Directory -Force -Path $targetRoot | Out-Null
    foreach ($name in $skillNames) {
        $source = Join-Path $SkillSource $name
        if (-not (Test-Path -LiteralPath $source)) { continue }
        $destination = Join-Path $targetRoot $name
        New-Item -ItemType Directory -Force -Path $destination | Out-Null
        Copy-Item -Path (Join-Path $source "*") -Destination $destination -Recurse -Force
        Write-Host "Copied $name -> $destination"
    }
}

Write-Host ""
Write-Host "Installed." -ForegroundColor Green
Write-Host "Probe dependencies:"
Write-Host "  powershell -ExecutionPolicy Bypass -File `"$Root\tools\douyin-video-notes.ps1`" -Probe"
Write-Host "Run a Douyin link:"
Write-Host "  powershell -ExecutionPolicy Bypass -File `"$Root\tools\douyin-video-notes.ps1`" `"https://v.douyin.com/xxxx/`""
Write-Host ""
Write-Host "If GPU transcription is not found, set WHISPER_GPU_DIR to the folder that contains main.exe, Whisper.dll, and ggml-medium.bin."
