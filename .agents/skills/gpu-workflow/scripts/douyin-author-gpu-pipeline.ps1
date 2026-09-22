param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,
    [Parameter(Mandatory = $true)]
    [string]$WorkflowRoot,
    [int]$BatchSize = 4
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
if ($BatchSize -lt 1) { throw "BatchSize must be at least 1." }

$skillRoot = Split-Path $PSScriptRoot -Parent
$skillsRoot = Split-Path $skillRoot -Parent
$downloader = Join-Path $PSScriptRoot "douyin-idm-author-download.js"
$idmWrapper = Join-Path $skillsRoot "idm-download\scripts\idm-download.ps1"
$gpuBatch = Join-Path $skillsRoot "gpu-transcribe\scripts\gpu-transcribe-batch.ps1"
$cleanup = Join-Path $PSScriptRoot "cleanup-verified-media.ps1"
$mediaDir = Join-Path $WorkflowRoot "media"
$transcriptDir = Join-Path $WorkflowRoot "transcripts"
$downloadStatePath = Join-Path $WorkflowRoot "download-state.json"
$transcriptionStatePath = Join-Path $WorkflowRoot "transcription-state.json"
$lockPath = Join-Path $WorkflowRoot "gpu-author-pipeline.lock"

foreach ($requiredFile in @($ManifestPath, $downloader, $idmWrapper, $gpuBatch, $cleanup)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required workflow file is missing: $requiredFile"
    }
}
New-Item -ItemType Directory -Force -Path $WorkflowRoot, $mediaDir, $transcriptDir | Out-Null

$lockStream = $null
try {
    $lockStream = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)

    $manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $videoIds = @($manifest |
        Where-Object { $_.type -eq "video" -or "$($_.url)" -match "/video/\d+" } |
        ForEach-Object {
            if ($_.id) { "$($_.id)" }
            elseif ("$($_.url)" -match "/video/(\d+)") { $Matches[1] }
        } |
        Where-Object { $_ } |
        Sort-Object -Unique)
    if ($videoIds.Count -eq 0) { throw "The manifest contains no video items." }

    function Get-CompletionSummary {
        $completedIds = @()
        if (Test-Path -LiteralPath $transcriptionStatePath -PathType Leaf) {
            $state = Get-Content -LiteralPath $transcriptionStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($property in @($state.items.PSObject.Properties)) {
                $item = $property.Value
                if (-not $item.gpu_verified) { continue }
                $outputs = @($item.outputs)
                $valid = $true
                foreach ($extension in @(".txt", ".srt", ".vtt")) {
                    $candidate = $outputs | Where-Object {
                        [IO.Path]::GetExtension([string]$_).ToLowerInvariant() -eq $extension
                    } | Select-Object -First 1
                    if (-not $candidate -or
                        -not (Test-Path -LiteralPath $candidate -PathType Leaf) -or
                        (Get-Item -LiteralPath $candidate).Length -le 0) {
                        $valid = $false
                        break
                    }
                }
                if ($valid) { $completedIds += $property.Name }
            }
        }
        $manifestCompleted = @($videoIds | Where-Object { $_ -in $completedIds })
        return @{
            completed = $manifestCompleted.Count
            total = $videoIds.Count
            pending = $videoIds.Count - $manifestCompleted.Count
        }
    }

    while ($true) {
        $summary = Get-CompletionSummary
        if ($summary.completed -eq $summary.total) {
            $result = @{
                success = $true
                total = $summary.total
                completed = $summary.completed
                pending = 0
                batch_size = $BatchSize
                transcripts = (Resolve-Path -LiteralPath $transcriptDir).Path
                state = $transcriptionStatePath
            }
            Write-Output ("GPU_AUTHOR_PIPELINE_RESULT=" + ($result | ConvertTo-Json -Compress))
            exit 0
        }

        $mediaFiles = @(Get-ChildItem -LiteralPath $mediaDir -File | Where-Object {
            $_.Extension.ToLowerInvariant() -in @(".mp4", ".m4a", ".mp3", ".wav", ".mov", ".mkv", ".webm")
        })
        if ($mediaFiles.Count -gt 0) {
            $gpuOutput = @(& $gpuBatch `
                -MediaDir $mediaDir `
                -OutputDir $transcriptDir `
                -StatePath $transcriptionStatePath `
                -MaxItems $BatchSize 2>&1 |
                ForEach-Object { $_.ToString() })
            $gpuOutput | ForEach-Object { Write-Output $_ }
            $gpuResultLine = $gpuOutput | Where-Object { $_ -match "GPU_BATCH_RESULT=" } | Select-Object -Last 1
            if (-not $gpuResultLine) { throw "GPU batch result proof is missing." }
            $gpuResult = $gpuResultLine.Substring($gpuResultLine.IndexOf("GPU_BATCH_RESULT=") + "GPU_BATCH_RESULT=".Length) |
                ConvertFrom-Json
            if (-not $gpuResult.success) { throw "GPU batch verification failed." }

            $cleanupOutput = @(& $cleanup -SearchRoot $WorkflowRoot 2>&1 |
                ForEach-Object { $_.ToString() })
            $cleanupOutput | ForEach-Object { Write-Output $_ }
            $cleanupResultLine = $cleanupOutput | Where-Object { $_ -match "GPU_WORKFLOW_CLEANUP_RESULT=" } | Select-Object -Last 1
            if (-not $cleanupResultLine -or $cleanupResultLine -notmatch '"success"\s*:\s*true') {
                throw "Verified-media cleanup failed."
            }
            continue
        }

        $downloadOutput = @(& node $downloader `
            $ManifestPath `
            $mediaDir `
            $downloadStatePath `
            $idmWrapper `
            $BatchSize `
            $transcriptionStatePath 2>&1 |
            ForEach-Object { $_.ToString() })
        $downloadOutput | ForEach-Object { Write-Output $_ }
        $downloadResultLine = $downloadOutput | Where-Object { $_ -match "DOUYIN_IDM_BATCH_RESULT=" } | Select-Object -Last 1
        if (-not $downloadResultLine) { throw "IDM batch result proof is missing." }
        $downloadResult = $downloadResultLine.Substring($downloadResultLine.IndexOf("DOUYIN_IDM_BATCH_RESULT=") + "DOUYIN_IDM_BATCH_RESULT=".Length) |
            ConvertFrom-Json
        if ($downloadResult.failed -gt 0) { throw "IDM batch reported failed items." }
        if ($downloadResult.downloaded_this_run -lt 1) {
            throw "Pipeline made no download progress while transcripts are still pending."
        }
    }
} finally {
    if ($lockStream) { $lockStream.Dispose() }
}
