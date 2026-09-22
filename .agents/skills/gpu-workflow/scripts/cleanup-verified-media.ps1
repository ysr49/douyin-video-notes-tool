param(
    [string]$SearchRoot = ""
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$allowedMediaExtensions = @(".mp4", ".m4a", ".mp3", ".wav", ".mov", ".mkv", ".webm", ".aac", ".flac", ".ogg")
$deleted = @()
$skipped = @()

if ([string]::IsNullOrWhiteSpace($SearchRoot)) {
    $workspaceRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..\..\..")).Path
    $resourceRoot = Get-ChildItem -LiteralPath $workspaceRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "03_*" -and (Test-Path -LiteralPath (Join-Path $_.FullName "downloads") -PathType Container) } |
        Select-Object -First 1
    if ($resourceRoot) {
        $SearchRoot = Join-Path $resourceRoot.FullName "downloads"
    } else {
        $SearchRoot = Join-Path $workspaceRoot "downloads"
    }
}
if (-not (Test-Path -LiteralPath $SearchRoot -PathType Container)) {
    throw "Cleanup search root does not exist: $SearchRoot"
}
$rootPath = (Resolve-Path -LiteralPath $SearchRoot).Path
$stateFiles = @(Get-ChildItem -LiteralPath $rootPath -Filter "transcription-state.json" -File -Recurse -ErrorAction SilentlyContinue)

foreach ($stateFile in $stateFiles) {
    try {
        $state = Get-Content -Raw -Encoding UTF8 -LiteralPath $stateFile.FullName | ConvertFrom-Json
        $workflowRoot = $stateFile.Directory.FullName
        $mediaRootCandidate = Join-Path $workflowRoot "media"
        if (-not (Test-Path -LiteralPath $mediaRootCandidate -PathType Container)) { continue }
        $mediaRoot = (Resolve-Path -LiteralPath $mediaRootCandidate).Path.TrimEnd("\") + "\"
        $properties = @($state.items.PSObject.Properties)

        foreach ($property in $properties) {
            $item = $property.Value
            if (-not $item.gpu_verified) { continue }
            $outputs = @($item.outputs)
            $required = @(".txt", ".srt", ".vtt")
            $validOutputs = $true
            foreach ($extension in $required) {
                $candidate = $outputs | Where-Object { [IO.Path]::GetExtension([string]$_).ToLowerInvariant() -eq $extension } | Select-Object -First 1
                if (-not $candidate -or -not (Test-Path -LiteralPath $candidate -PathType Leaf) -or (Get-Item -LiteralPath $candidate).Length -le 0) {
                    $validOutputs = $false
                    break
                }
            }
            if (-not $validOutputs) {
                $skipped += @{id=$property.Name; reason="required transcript outputs are missing"}
                continue
            }

            $mediaPath = [string]$item.media
            if (-not $mediaPath -or -not (Test-Path -LiteralPath $mediaPath -PathType Leaf)) { continue }
            $resolvedMedia = (Resolve-Path -LiteralPath $mediaPath).Path
            $extension = [IO.Path]::GetExtension($resolvedMedia).ToLowerInvariant()
            if (-not $resolvedMedia.StartsWith($mediaRoot, [StringComparison]::OrdinalIgnoreCase) -or $extension -notin $allowedMediaExtensions) {
                $skipped += @{id=$property.Name; reason="media path is outside the controlled media directory"}
                continue
            }

            $bytes = (Get-Item -LiteralPath $resolvedMedia).Length
            Remove-Item -LiteralPath $resolvedMedia -Force
            $deleted += @{id=$property.Name; path=$resolvedMedia; bytes=$bytes}
        }
    } catch {
        $skipped += @{state=$stateFile.FullName; reason=$_.Exception.Message}
    }
}

$deletedBytes = 0L
foreach ($entry in $deleted) {
    $deletedBytes += [long]$entry["bytes"]
}
$result = @{
    success = $true
    searched_state_files = $stateFiles.Count
    deleted_count = $deleted.Count
    deleted_bytes = $deletedBytes
    skipped_count = $skipped.Count
    deleted = $deleted
    skipped = $skipped
}
Write-Output ("GPU_WORKFLOW_CLEANUP_RESULT=" + ($result | ConvertTo-Json -Depth 8 -Compress))
