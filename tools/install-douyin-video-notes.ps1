$ErrorActionPreference = "Stop"

$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
$SkillSource = Join-Path $Root ".agents\skills\douyin-video-notes"
$SkillTarget = "D:\CodexHome\skills\douyin-video-notes"
$ServiceDir = Join-Path $Root "video-transcript-capture\service"
$VenvPython = Join-Path $ServiceDir ".venv\Scripts\python.exe"

Write-Host "Installing Douyin Video Notes workflow..." -ForegroundColor Cyan

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw "Node.js is required. Install Node.js first."
}

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw "Python is required. Install Python first."
}

$ChromePath = "C:\Program Files\Google\Chrome\Application\chrome.exe"
if (-not (Test-Path $ChromePath)) {
    Write-Warning "Chrome was not found at $ChromePath. Set CHROME_PATH before running the workflow if Chrome is installed elsewhere."
}

if (-not (Test-Path (Join-Path $Root "node_modules\playwright-core"))) {
    Write-Host "Installing Node dependencies..." -ForegroundColor Cyan
    Push-Location $Root
    npm install
    Pop-Location
}

if (-not (Test-Path $VenvPython)) {
    Write-Host "Creating Python virtual environment for transcription service..." -ForegroundColor Cyan
    Push-Location $ServiceDir
    python -m venv .venv
    Pop-Location
}

Write-Host "Installing transcription dependencies..." -ForegroundColor Cyan
Push-Location $ServiceDir
& $VenvPython -m pip install --upgrade pip
& $VenvPython -m pip install -r requirements.txt
Pop-Location

if (-not (Test-Path $SkillSource)) {
    throw "Skill source not found: $SkillSource"
}

New-Item -ItemType Directory -Force -Path $SkillTarget | Out-Null
Copy-Item -Path (Join-Path $SkillSource "*") -Destination $SkillTarget -Recurse -Force

Write-Host ""
Write-Host "Installed." -ForegroundColor Green
Write-Host "Run this workflow with:" -ForegroundColor Cyan
Write-Host "  powershell -ExecutionPolicy Bypass -File `"$Root\tools\douyin-video-notes.ps1`" `"https://v.douyin.com/xxxx/`""
Write-Host ""
Write-Host "Codex skill installed at:" -ForegroundColor Cyan
Write-Host "  $SkillTarget"
