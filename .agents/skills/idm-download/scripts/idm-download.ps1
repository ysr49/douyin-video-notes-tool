param(
    [Parameter(Position = 0)]
    [string]$Url,
    [string]$OutputDir,
    [string]$FileName,
    [int]$TimeoutSeconds = 1800,
    [int]$PollSeconds = 2,
    [int]$StableChecks = 5,
    [switch]$Probe
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

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

function Write-IdmResult([hashtable]$Value) {
    Write-Output ("IDM_DOWNLOAD_RESULT=" + ($Value | ConvertTo-Json -Depth 8 -Compress))
}

function Get-MediaProbe([string]$Path, [string]$Ffprobe) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    if ((Get-Item -LiteralPath $Path).Length -lt 1024) { return $null }
    $raw = & $Ffprobe -v error -show_entries "stream=codec_type,codec_name" -show_entries "format=duration,size" -of json -- $Path 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
    try { $probe = ($raw -join [Environment]::NewLine) | ConvertFrom-Json } catch { return $null }
    $duration = 0.0
    if (-not [double]::TryParse([string]$probe.format.duration, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$duration)) {
        return $null
    }
    $mediaStreams = @($probe.streams | Where-Object { $_.codec_type -in @("audio", "video") })
    if ($duration -le 0 -or $mediaStreams.Count -eq 0) { return $null }
    return @{
        duration_seconds = $duration
        streams = @($mediaStreams | ForEach-Object { @{type=$_.codec_type; codec=$_.codec_name} })
    }
}

$idm = Find-Executable @("IDMan.exe") @(
    "C:\Program Files (x86)\Internet Download Manager\IDMan.exe",
    "C:\Program Files\Internet Download Manager\IDMan.exe"
)
$ffprobe = Find-Executable @("ffprobe.exe", "ffprobe")

if ($Probe) {
    $version = if ($idm) { (Get-Item -LiteralPath $idm).VersionInfo.FileVersion } else { $null }
    Write-IdmResult @{
        success = [bool]($idm -and $ffprobe)
        probe = $true
        idm = $idm
        idm_version = $version
        ffprobe = $ffprobe
    }
    exit $(if ($idm -and $ffprobe) { 0 } else { 1 })
}

if (-not $Url) { throw "Url is required unless -Probe is used." }
if (-not $idm) { throw "IDM executable was not found." }
if (-not $ffprobe) { throw "ffprobe executable was not found." }
if (-not $OutputDir) { throw "OutputDir is required." }

try { $uri = [Uri]$Url } catch { throw "Invalid media URL." }
if ($uri.Scheme -notin @("http", "https")) { throw "IDM requires an HTTP/HTTPS media URL." }

if (-not $FileName) {
    $FileName = [Uri]::UnescapeDataString([IO.Path]::GetFileName($uri.AbsolutePath))
    if (-not $FileName) { $FileName = "idm-download-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss')).mp4" }
}
if ([IO.Path]::GetFileName($FileName) -ne $FileName) { throw "FileName must be a leaf filename." }

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$OutputDir = (Resolve-Path -LiteralPath $OutputDir).Path
$target = Join-Path $OutputDir $FileName

$existingProbe = Get-MediaProbe $target $ffprobe
if ($existingProbe) {
    Write-IdmResult @{
        success = $true
        media_verified = $true
        reused = $true
        path = $target
        bytes = (Get-Item -LiteralPath $target).Length
        probe = $existingProbe
    }
    exit 0
}
if (Test-Path -LiteralPath $target) {
    throw "Existing target is not valid media; refusing to overwrite it: $target"
}

& $idm /d $Url /p $OutputDir /f $FileName /n
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$lastLength = -1L
$stable = 0
$verifiedProbe = $null

while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        $length = (Get-Item -LiteralPath $target).Length
        if ($length -gt 1024 -and $length -eq $lastLength) { $stable++ } else { $stable = 0 }
        $lastLength = $length
        if ($stable -ge $StableChecks) {
            $verifiedProbe = Get-MediaProbe $target $ffprobe
            if ($verifiedProbe) { break }
            $stable = 0
        }
    }
    Start-Sleep -Seconds $PollSeconds
}

if (-not $verifiedProbe) {
    throw "IDM did not produce verified media within $TimeoutSeconds seconds: $target"
}

Write-IdmResult @{
    success = $true
    media_verified = $true
    reused = $false
    path = $target
    bytes = (Get-Item -LiteralPath $target).Length
    probe = $verifiedProbe
}

