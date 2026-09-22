param(
    [string]$Url,
    [string]$MediaDir,
    [string]$ManifestPath,
    [string]$WorkflowRoot,
    [int]$BatchSize = 4,
    [string]$OutputDir,
    [string]$StatePath,
    [switch]$KeepMedia,
    [switch]$Probe
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$skillRoot = Split-Path $PSScriptRoot -Parent
$skillsRoot = Split-Path $skillRoot -Parent
$videoWorkflow = Join-Path $skillsRoot "video-link-workflow\scripts\video-link-workflow.ps1"
$gpuBatch = Join-Path $skillsRoot "gpu-transcribe\scripts\gpu-transcribe-batch.ps1"
$idmProbe = Join-Path $skillsRoot "idm-download\scripts\idm-download.ps1"
$cleanup = Join-Path $PSScriptRoot "cleanup-verified-media.ps1"
$authorPipeline = Join-Path $PSScriptRoot "douyin-author-gpu-pipeline.ps1"

if ($Probe) {
    $paths = @{
        video_workflow = $videoWorkflow
        gpu_batch = $gpuBatch
        idm_download = $idmProbe
        cleanup = $cleanup
        author_pipeline = $authorPipeline
    }
    $missing = @($paths.GetEnumerator() | Where-Object { -not (Test-Path -LiteralPath $_.Value -PathType Leaf) } | ForEach-Object { $_.Key })
    Write-Output ("GPU_WORKFLOW_RESULT=" + (@{success=($missing.Count -eq 0); probe=$true; missing=$missing; components=$paths} | ConvertTo-Json -Compress))
    if ($missing.Count -gt 0) { exit 1 }
    exit 0
}

if ($Url) {
    $args = @("-Url", $Url, "-Action", "transcript")
    if ($KeepMedia) { $args += "-KeepVideo" }
    & $videoWorkflow @args
    exit $LASTEXITCODE
}

if ($MediaDir) {
    if (-not $OutputDir) { $OutputDir = Join-Path (Split-Path $MediaDir -Parent) "transcripts" }
    if (-not $StatePath) { $StatePath = Join-Path (Split-Path $MediaDir -Parent) "transcription-state.json" }
    & $gpuBatch -MediaDir $MediaDir -OutputDir $OutputDir -StatePath $StatePath
    exit $LASTEXITCODE
}

if ($ManifestPath) {
    if (-not $WorkflowRoot) {
        $WorkflowRoot = Join-Path (Split-Path $ManifestPath -Parent) "gpu_workflow"
    }
    & $authorPipeline -ManifestPath $ManifestPath -WorkflowRoot $WorkflowRoot -BatchSize $BatchSize
    exit $LASTEXITCODE
}

throw "Pass -Url, -MediaDir, -ManifestPath, or -Probe."
