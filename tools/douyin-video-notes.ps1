param(
    [Parameter(Position = 0)]
    [string]$Url,
    [ValidateSet("download", "transcript", "both")]
    [string]$Action = "both",
    [string]$OutputDir,
    [switch]$KeepVideo,
    [switch]$Probe,
    [switch]$Legacy
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$GpuWorkflow = Join-Path $Root ".agents\skills\video-link-workflow\scripts\video-link-workflow.ps1"
$LegacyPython = Join-Path $Root "tools\douyin_video_to_note.py"
$VenvPython = Join-Path $Root "video-transcript-capture\service\.venv\Scripts\python.exe"

if ($Legacy) {
    if (-not $Url) { throw "Url is required for -Legacy." }
    $legacyArgs = @($Url)
    if (Test-Path -LiteralPath $VenvPython) {
        & $VenvPython $LegacyPython @legacyArgs
    } else {
        python $LegacyPython @legacyArgs
    }
    exit $LASTEXITCODE
}

if (-not (Test-Path -LiteralPath $GpuWorkflow -PathType Leaf)) {
    throw "GPU workflow is missing: $GpuWorkflow"
}

$workflowArgs = @()
if ($Probe) {
    $workflowArgs += "-Probe"
} else {
    if (-not $Url) { throw "Url is required unless -Probe is used." }
    $workflowArgs += @($Url, "-Action", $Action)
    if ($OutputDir) { $workflowArgs += @("-OutputDir", $OutputDir) }
    if ($KeepVideo) { $workflowArgs += "-KeepVideo" }
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $GpuWorkflow @workflowArgs
exit $LASTEXITCODE
