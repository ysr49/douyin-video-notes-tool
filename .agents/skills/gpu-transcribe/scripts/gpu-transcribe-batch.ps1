param(
    [Parameter(Mandatory = $true)]
    [string]$MediaDir,
    [Parameter(Mandatory = $true)]
    [string]$OutputDir,
    [Parameter(Mandatory = $true)]
    [string]$StatePath,
    [string]$Language = "zh",
    [int]$MaxItems = 0
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$wrapper = Join-Path $PSScriptRoot "gpu-transcribe.ps1"
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$media = @(Get-ChildItem -LiteralPath $MediaDir -File | Where-Object { $_.Extension -in @(".mp4", ".m4a", ".mp3", ".wav", ".mov", ".mkv", ".webm") } | Sort-Object Name)

$state = @{started_at=(Get-Date).ToUniversalTime().ToString("o"); items=@{}}
if (Test-Path -LiteralPath $StatePath) {
    $parsedState = Get-Content -Raw -Encoding UTF8 -LiteralPath $StatePath | ConvertFrom-Json
    foreach ($property in $parsedState.PSObject.Properties) {
        if ($property.Name -ne "items") { $state[$property.Name] = $property.Value }
    }
    $state.items = @{}
    if ($parsedState.items) {
        foreach ($property in $parsedState.items.PSObject.Properties) {
            $state.items[$property.Name] = $property.Value
        }
    }
}
if ($MaxItems -gt 0 -and $media.Count -gt $MaxItems) {
    $media = @($media | Select-Object -First $MaxItems)
}
$state.current_media_count = $media.Count
$state.media_dir = (Resolve-Path -LiteralPath $MediaDir).Path
$state.output_dir = (Resolve-Path -LiteralPath $OutputDir).Path

function Save-State {
    $state.updated_at = (Get-Date).ToUniversalTime().ToString("o")
    $temporary = "$StatePath.tmp"
    $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $StatePath -Force
}

for ($index = 0; $index -lt $media.Count; $index++) {
    $item = $media[$index]
    $key = $item.BaseName
    $previous = $state.items[$key]
    $validPreviousOutputs = @()
    if ($previous -and $previous.outputs) {
        $validPreviousOutputs = @($previous.outputs | Where-Object {
            (Test-Path -LiteralPath $_ -PathType Leaf) -and (Get-Item -LiteralPath $_).Length -gt 0
        })
    }
    if ($previous -and $previous.gpu_verified -and
        @(".txt", ".srt", ".vtt" | Where-Object {
            $extension = $_
            -not ($validPreviousOutputs | Where-Object { [IO.Path]::GetExtension([string]$_).ToLowerInvariant() -eq $extension })
        }).Count -eq 0) {
        Write-Output "[$($index + 1)/$($media.Count)] $key reused"
        continue
    }
    try {
        $output = @(& $wrapper $item.FullName -Language $Language -Formats @("txt", "srt", "vtt") -OutputDir $OutputDir 2>&1 | ForEach-Object { $_.ToString() })
        $output | ForEach-Object { Write-Output $_ }
        $proofLine = $output | Where-Object { $_ -like "GPU_TRANSCRIBE_RESULT=*" } | Select-Object -Last 1
        if (-not $proofLine) { throw "GPU result record is missing." }
        $proof = $proofLine.Substring("GPU_TRANSCRIBE_RESULT=".Length) | ConvertFrom-Json
        if (-not $proof.gpu_verified) { throw "GPU verification failed." }
        $state.items[$key] = @{
            gpu_verified = $true
            media = $item.FullName
            outputs = @($proof.outputs)
            completed_at = (Get-Date).ToUniversalTime().ToString("o")
        }
        Write-Output "[$($index + 1)/$($media.Count)] $key ok"
    } catch {
        $state.items[$key] = @{
            gpu_verified = $false
            media = $item.FullName
            error = $_.Exception.Message
            failed_at = (Get-Date).ToUniversalTime().ToString("o")
        }
        Write-Error "[$($index + 1)/$($media.Count)] $key failed: $($_.Exception.Message)" -ErrorAction Continue
    }
    $state.completed = @($state.items.Values | Where-Object { $_.gpu_verified }).Count
    $state.failed = @($state.items.Values | Where-Object { -not $_.gpu_verified }).Count
    Save-State
}

$state.completed = @($state.items.Values | Where-Object { $_.gpu_verified }).Count
$state.failed = @($state.items.Values | Where-Object { -not $_.gpu_verified }).Count
$state.finished_at = (Get-Date).ToUniversalTime().ToString("o")
Save-State
$currentKeys = @($media | ForEach-Object { $_.BaseName })
$currentCompleted = @($currentKeys | Where-Object {
    $entry = $state.items[$_]
    $entry -and $entry.gpu_verified
}).Count
$currentFailed = @($currentKeys | Where-Object {
    $entry = $state.items[$_]
    $entry -and -not $entry.gpu_verified
}).Count
$result = @{
    success = ($currentFailed -eq 0 -and $currentCompleted -eq $media.Count)
    total = $media.Count
    completed = $currentCompleted
    failed = $currentFailed
    cumulative_completed = $state.completed
    cumulative_failed = $state.failed
    state = $StatePath
}
Write-Output ("GPU_BATCH_RESULT=" + ($result | ConvertTo-Json -Compress))
if (-not $result.success) { exit 1 }
