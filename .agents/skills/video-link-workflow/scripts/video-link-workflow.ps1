param(
    [Parameter(Position = 0)]
    [string]$Url,
    [ValidateSet("download", "transcript", "both")]
    [string]$Action = "both",
    [ValidateSet("auto", "idm", "ytdlp")]
    [string]$Backend = "auto",
    [ValidateSet("none", "chrome", "edge")]
    [string]$Browser = "none",
    [string]$OutputDir,
    [string]$FileName,
    [switch]$Playlist,
    [switch]$KeepVideo,
    [switch]$Probe,
    [int]$IdmTimeoutSeconds = 1800
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

function Find-CommandPath([string[]]$Names, [string[]]$Fallbacks = @()) {
    foreach ($name in $Names) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
    foreach ($path in $Fallbacks) {
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { return $path }
    }
    return $null
}

function Write-Result([hashtable]$Result) {
    $json = $Result | ConvertTo-Json -Depth 8 -Compress
    Write-Output "VIDEO_LINK_WORKFLOW_RESULT=$json"
}

function Test-Media([string]$Path, [string]$Ffprobe) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Downloaded file is missing: $Path" }
    if ((Get-Item -LiteralPath $Path).Length -lt 1024) { throw "Downloaded file is too small: $Path" }
    $probe = & $Ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 -- $Path 2>&1
    if ($LASTEXITCODE -ne 0 -or -not ($probe | Select-Object -First 1)) { throw "ffprobe could not validate media: $Path" }
    return [double]($probe | Select-Object -First 1)
}

function Wait-IdmFile([string]$Path, [int]$TimeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastLength = -1L
    $stable = 0
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $length = (Get-Item -LiteralPath $Path).Length
            if ($length -gt 1024 -and $length -eq $lastLength) { $stable++ } else { $stable = 0 }
            if ($stable -ge 3) { return }
            $lastLength = $length
        }
        Start-Sleep -Seconds 2
    }
    throw "IDM did not produce a stable final file within $TimeoutSeconds seconds: $Path"
}

$workspaceRoot = Split-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) -Parent
$resourceRoot = Get-ChildItem -LiteralPath $workspaceRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "03_*" } | Select-Object -First 1
if (-not $OutputDir) {
    if ($resourceRoot) {
        $OutputDir = Join-Path $resourceRoot.FullName "downloads"
    } else {
        $OutputDir = Join-Path $workspaceRoot "downloads"
    }
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$OutputDir = (Resolve-Path -LiteralPath $OutputDir).Path

$idm = Find-CommandPath @("IDMan.exe") @("C:\Program Files (x86)\Internet Download Manager\IDMan.exe", "C:\Program Files\Internet Download Manager\IDMan.exe")
$ytdlp = Find-CommandPath @("yt-dlp.exe", "yt-dlp") @((Join-Path $env:APPDATA "Python\Python314\Scripts\yt-dlp.exe"))
$ffmpeg = Find-CommandPath @("ffmpeg.exe", "ffmpeg")
$ffprobe = Find-CommandPath @("ffprobe.exe", "ffprobe")
$gpuWrapper = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "gpu-transcribe\scripts\gpu-transcribe.ps1"
$idmWrapper = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "idm-download\scripts\idm-download.ps1"
$douyinResolver = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "gpu-workflow\scripts\douyin-idm-single.js"

if ($Probe) {
    Write-Result @{success=$true; probe=$true; idm=$idm; idm_wrapper=(Test-Path -LiteralPath $idmWrapper); ytdlp=$ytdlp; ffmpeg=$ffmpeg; ffprobe=$ffprobe; gpu_wrapper=(Test-Path -LiteralPath $gpuWrapper); douyin_resolver=(Test-Path -LiteralPath $douyinResolver)}
    exit 0
}
if (-not $Url) { throw "Url is required unless -Probe is used." }
if (-not $ffprobe) { throw "ffprobe is required for media validation." }

$uri = $null
try { $uri = [Uri]$Url } catch { throw "Invalid URL: $Url" }
$hostName = $uri.Host.ToLowerInvariant()
$isDouyin = $hostName -match '(^|\.)(douyin\.com|iesdouyin\.com|tiktok\.com)$'

if ($isDouyin) {
    if (-not (Test-Path -LiteralPath $douyinResolver -PathType Leaf)) { throw "Douyin IDM resolver is missing: $douyinResolver" }
    $resolverOutput = @(& node $douyinResolver $Url $OutputDir $idmWrapper 2>&1 | ForEach-Object { $_.ToString() })
    $resolverOutput | ForEach-Object { Write-Output $_ }
    if ($LASTEXITCODE -ne 0) { throw "Douyin resolver failed with exit code $LASTEXITCODE" }
    $resolverProof = $resolverOutput | Where-Object { $_ -like "DOUYIN_IDM_SINGLE_RESULT=*" } | Select-Object -Last 1
    if (-not $resolverProof) { throw "Douyin resolver result is missing." }
    $resolved = $resolverProof.Substring("DOUYIN_IDM_SINGLE_RESULT=".Length) | ConvertFrom-Json
    if (-not $resolved.success -or -not (Test-Path -LiteralPath $resolved.path -PathType Leaf)) { throw "Douyin resolver did not produce verified media." }

    if ($Action -eq "download") {
        Write-Result @{success=$true; platform="douyin"; adapter="douyin-idm-single"; action=$Action; output_dir=$OutputDir; media=@([string]$resolved.path)}
        exit 0
    }

    $gpuOutput = @(& $gpuWrapper ([string]$resolved.path) -Language zh -Formats @("txt", "srt", "vtt") -OutputDir $OutputDir 2>&1 | ForEach-Object { $_.ToString() })
    $gpuOutput | ForEach-Object { Write-Output $_ }
    $gpuProofLine = $gpuOutput | Where-Object { $_ -match "GPU_TRANSCRIBE_RESULT=" } | Select-Object -Last 1
    if (-not $gpuProofLine) { throw "GPU transcription failed or returned no proof." }
    $proofIndex = $gpuProofLine.IndexOf("GPU_TRANSCRIBE_RESULT=")
    $gpuProof = $gpuProofLine.Substring($proofIndex + "GPU_TRANSCRIBE_RESULT=".Length) | ConvertFrom-Json
    if (-not $gpuProof.gpu_verified) { throw "GPU verification proof is missing." }
    foreach ($extension in @(".txt", ".srt", ".vtt")) {
        $output = @($gpuProof.outputs | Where-Object { [IO.Path]::GetExtension([string]$_).ToLowerInvariant() -eq $extension }) | Select-Object -First 1
        if (-not $output -or -not (Test-Path -LiteralPath $output -PathType Leaf) -or (Get-Item -LiteralPath $output).Length -le 0) {
            throw "Verified transcript output is missing: $extension"
        }
    }
    $mediaRemoved = $false
    if ($Action -eq "transcript" -and -not $KeepVideo) {
        Remove-Item -LiteralPath ([string]$resolved.path) -Force
        $mediaRemoved = $true
    }
    Write-Result @{success=$true; platform="douyin"; adapter="douyin-idm-single"; action=$Action; output_dir=$OutputDir; media=@([string]$resolved.path); media_removed=$mediaRemoved; transcripts=@($gpuProof)}
    exit 0
}

$directPattern = '\.(mp4|m4v|mov|mkv|webm|avi|mp3|m4a|aac|wav|flac|ogg)(?:$|\?)'
$isDirect = $Url -match $directPattern
if ($Backend -eq "auto") { $Backend = if ($isDirect) { "idm" } else { "ytdlp" } }

$mediaFiles = @()
if ($Backend -eq "idm") {
    if (-not $isDirect -and -not $FileName) { throw "For a resolved media URL without a file extension, pass -FileName. Ordinary webpage URLs must be resolved first." }
    if (-not (Test-Path -LiteralPath $idmWrapper -PathType Leaf)) { throw "IDM download wrapper is missing: $idmWrapper" }
    if (-not $FileName) {
        $FileName = [Uri]::UnescapeDataString([IO.Path]::GetFileName($uri.AbsolutePath))
        if (-not $FileName) { throw "Cannot derive a filename for IDM. Pass -FileName." }
    }
    $idmOutput = @(& $idmWrapper -Url $Url -OutputDir $OutputDir -FileName $FileName -TimeoutSeconds $IdmTimeoutSeconds 2>&1 | ForEach-Object { $_.ToString() })
    $idmOutput | ForEach-Object { Write-Output $_ }
    $idmProof = $idmOutput | Where-Object { $_ -like "IDM_DOWNLOAD_RESULT=*" } | Select-Object -Last 1
    if (-not $idmProof) { throw "IDM download result is missing." }
    $idmResult = $idmProof.Substring("IDM_DOWNLOAD_RESULT=".Length) | ConvertFrom-Json
    if (-not $idmResult.success -or -not $idmResult.media_verified) { throw "IDM did not produce verified media." }
    $mediaFiles = @([string]$idmResult.path)
} else {
    if (-not $ytdlp) { throw "yt-dlp executable was not found." }
    if (-not $ffmpeg) { throw "ffmpeg is required for webpage audio/video merging." }
    $template = Join-Path $OutputDir "%(title).180B [%(id)s].%(ext)s"
    $args = @("--newline", "--windows-filenames", "--no-progress", "--merge-output-format", "mp4", "-f", "bestvideo*+bestaudio/best", "-o", $template, "--print", "after_move:VIDEO_LINK_MEDIA=%(filepath)s")
    if (-not $Playlist) { $args += "--no-playlist" }
    if ($Browser -ne "none") { $args += @("--cookies-from-browser", $Browser) }
    $args += $Url
    $downloadOutput = @(& $ytdlp @args 2>&1 | ForEach-Object { $_.ToString() })
    $exitCode = $LASTEXITCODE
    $downloadOutput | ForEach-Object { Write-Output $_ }
    if ($exitCode -ne 0) { throw "yt-dlp failed with exit code $exitCode" }
    $mediaFiles = @($downloadOutput | Where-Object { $_ -like "VIDEO_LINK_MEDIA=*" } | ForEach-Object { $_.Substring("VIDEO_LINK_MEDIA=".Length) })
    if ($mediaFiles.Count -eq 0) { throw "yt-dlp completed without reporting an output media path." }
    foreach ($media in $mediaFiles) { [void](Test-Media $media $ffprobe) }
}

$transcripts = @()
if ($Action -ne "download") {
    if (-not (Test-Path -LiteralPath $gpuWrapper -PathType Leaf)) { throw "GPU transcription wrapper is missing: $gpuWrapper" }
    foreach ($media in $mediaFiles) {
        $gpuOutput = @(& powershell -ExecutionPolicy Bypass -File $gpuWrapper $media -PlainText 2>&1 | ForEach-Object { $_.ToString() })
        $gpuExitCode = $LASTEXITCODE
        $gpuOutput | ForEach-Object { Write-Output $_ }
        if ($gpuExitCode -ne 0) { throw "GPU transcription failed for: $media" }
        $proof = $gpuOutput | Where-Object { $_ -like "GPU_TRANSCRIBE_RESULT=*" } | Select-Object -Last 1
        if (-not $proof -or $proof -notmatch '"gpu_verified"\s*:\s*true') { throw "GPU verification proof is missing for: $media" }
        $transcripts += $proof.Substring("GPU_TRANSCRIBE_RESULT=".Length) | ConvertFrom-Json
    }
}

Write-Result @{success=$true; platform="generic"; backend=$Backend; action=$Action; media=@($mediaFiles); transcripts=@($transcripts); output_dir=$OutputDir}
