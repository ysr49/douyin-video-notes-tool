param(
    [string]$MediaPath = "",
    [string]$OutputDir = "",
    [string]$Language = "zh",
    [string[]]$Formats = @("txt", "srt", "vtt"),
    [int]$ChunkSeconds = 300,
    [switch]$Probe
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$standardWrapper = Join-Path $PSScriptRoot "gpu-transcribe.ps1"
$ffmpegCommand = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
if (-not $ffmpegCommand) { $ffmpegCommand = Get-Command ffmpeg -ErrorAction SilentlyContinue }

if ($Probe) {
    $probeResult = @{
        success = [bool]($ffmpegCommand -and (Test-Path -LiteralPath $standardWrapper -PathType Leaf))
        ffmpeg = if ($ffmpegCommand) { $ffmpegCommand.Source } else { $null }
        gpu_wrapper = $standardWrapper
    }
    Write-Output ("CHUNKED_GPU_TRANSCRIBE_PROBE=" + ($probeResult | ConvertTo-Json -Compress))
    if (-not $probeResult.success) { exit 1 }
    exit 0
}

if ([string]::IsNullOrWhiteSpace($MediaPath) -or
    -not (Test-Path -LiteralPath $MediaPath -PathType Leaf)) {
    throw "MediaPath is missing or invalid: $MediaPath"
}
if ([string]::IsNullOrWhiteSpace($OutputDir)) { throw "OutputDir is required." }
if (@("txt", "srt", "vtt" | Where-Object { $_ -notin $Formats }).Count -gt 0) {
    throw "Chunked GPU transcription requires txt, srt, and vtt formats."
}
if (-not $ffmpegCommand) { throw "ffmpeg is unavailable." }
if (-not (Test-Path -LiteralPath $standardWrapper -PathType Leaf)) {
    throw "GPU wrapper is missing: $standardWrapper"
}
if ($ChunkSeconds -lt 15) { throw "ChunkSeconds must be at least 15." }

$resolvedMedia = (Resolve-Path -LiteralPath $MediaPath).Path
$baseName = [IO.Path]::GetFileNameWithoutExtension($resolvedMedia)
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$resolvedOutput = (Resolve-Path -LiteralPath $OutputDir).Path
$chunkRoot = Join-Path $resolvedOutput ".gpu-chunks\$baseName"
$proofRoot = Join-Path $resolvedOutput "gpu-proofs\$baseName"
$chunkOutputRoot = Join-Path $proofRoot "chunk-outputs"
$statePath = Join-Path $proofRoot "chunk-state.json"
New-Item -ItemType Directory -Force -Path $chunkRoot, $proofRoot, $chunkOutputRoot | Out-Null

function Save-JsonAtomic {
    param([string]$Path, [object]$Value)
    $temporary = "$Path.tmp"
    $Value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Convert-CueTimeToMilliseconds {
    param([string]$Value)
    if ($Value -notmatch '^(\d{2}):(\d{2}):(\d{2})[,.](\d{3})$') {
        throw "Invalid subtitle timestamp: $Value"
    }
    return (((([int64]$Matches[1] * 60) + [int64]$Matches[2]) * 60 + [int64]$Matches[3]) * 1000 +
        [int64]$Matches[4])
}

function Format-CueTime {
    param([int64]$Milliseconds, [string]$Separator)
    if ($Milliseconds -lt 0) { $Milliseconds = 0 }
    $hours = [int64][math]::Floor($Milliseconds / 3600000)
    $remaining = $Milliseconds % 3600000
    $minutes = [int64][math]::Floor($remaining / 60000)
    $remaining = $remaining % 60000
    $seconds = [int64][math]::Floor($remaining / 1000)
    $millis = [int64]($remaining % 1000)
    return ("{0:D2}:{1:D2}:{2:D2}{3}{4:D3}" -f $hours, $minutes, $seconds, $Separator, $millis)
}

function Get-SubtitleCues {
    param([string]$Path)
    $content = [string](Get-Content -LiteralPath $Path -Raw -Encoding UTF8)
    if ([string]::IsNullOrWhiteSpace($content)) { return @() }
    $pattern = '(?ms)^\s*(?:\d+\s*\r?\n)?(?<start>\d{2}:\d{2}:\d{2}[,.]\d{3})\s+-->\s+(?<end>\d{2}:\d{2}:\d{2}[,.]\d{3})[^\r\n]*\r?\n(?<text>.*?)(?=(?:\r?\n){2,}|\z)'
    $result = @()
    foreach ($match in [regex]::Matches($content, $pattern)) {
        $text = $match.Groups["text"].Value.Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $result += @{
            start_ms = Convert-CueTimeToMilliseconds $match.Groups["start"].Value
            end_ms = Convert-CueTimeToMilliseconds $match.Groups["end"].Value
            text = $text
        }
    }
    return @($result)
}

function Normalize-CueTimeline {
    param([object[]]$Cues)
    [int64]$previousEnd = 0
    foreach ($cue in $Cues) {
        if ([int64]$cue.start_ms -lt $previousEnd) { $cue.start_ms = $previousEnd }
        if ([int64]$cue.end_ms -lt [int64]$cue.start_ms) { $cue.end_ms = $cue.start_ms }
        $previousEnd = [int64]$cue.end_ms
    }
    return @($Cues)
}

$state = @{media=$resolvedMedia; chunk_seconds=$ChunkSeconds; items=@{}}
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    $parsed = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $state = @{media=$resolvedMedia; chunk_seconds=$ChunkSeconds; items=@{}}
    foreach ($property in $parsed.PSObject.Properties) {
        if ($property.Name -ne "items") { $state[$property.Name] = $property.Value }
    }
    foreach ($property in @($parsed.items.PSObject.Properties)) {
        $state.items[$property.Name] = $property.Value
    }
}

$existingChunks = @(Get-ChildItem -LiteralPath $chunkRoot -Filter "chunk-*.wav" -File -ErrorAction SilentlyContinue |
    Sort-Object Name)
if ($existingChunks.Count -eq 0) {
    $chunkPattern = Join-Path $chunkRoot "chunk-%06d.wav"
    & $ffmpegCommand.Source -hide_banner -loglevel error -y -i $resolvedMedia -vn -ac 1 -ar 16000 `
        -c:a pcm_s16le -f segment -segment_time $ChunkSeconds -reset_timestamps 1 $chunkPattern
    if ($LASTEXITCODE -ne 0) { throw "ffmpeg failed to split media into chunks." }
    $existingChunks = @(Get-ChildItem -LiteralPath $chunkRoot -Filter "chunk-*.wav" -File | Sort-Object Name)
}
if ($existingChunks.Count -eq 0) { throw "No audio chunks were created." }

for ($index = 0; $index -lt $existingChunks.Count; $index++) {
    $chunk = $existingChunks[$index]
    $key = $chunk.BaseName
    $previous = $state.items[$key]
    $validPrevious = $false
    if ($previous -and $previous.gpu_verified -and $previous.using_gpu -and $previous.gpu_tasks) {
        $validPrevious = @(".txt", ".srt", ".vtt" | Where-Object {
            $extension = $_
            -not (@($previous.outputs) | Where-Object {
                [IO.Path]::GetExtension([string]$_).ToLowerInvariant() -eq $extension -and
                (Test-Path -LiteralPath $_ -PathType Leaf) -and
                ((Get-Item -LiteralPath $_).Length -gt 0 -or $previous.silent)
            })
        }).Count -eq 0
    }
    if ($validPrevious) {
        Write-Output "GPU_CHUNK [$($index + 1)/$($existingChunks.Count)] $key reused"
        continue
    }

    $chunkOutput = Join-Path $chunkOutputRoot $key
    New-Item -ItemType Directory -Force -Path $chunkOutput | Out-Null
    $engineOutput = @(& $standardWrapper $chunk.FullName -Language $Language `
        -Formats @("txt", "srt", "vtt") -OutputDir $chunkOutput 2>&1 |
        ForEach-Object { $_.ToString() })
    $logPath = Join-Path $proofRoot "$key.engine.log"
    $engineOutput | Set-Content -LiteralPath $logPath -Encoding UTF8
    $proofLine = $engineOutput | Where-Object { $_ -like "GPU_TRANSCRIBE_RESULT=*" } | Select-Object -Last 1
    $usingGpu = [bool]($engineOutput | Where-Object { $_ -match "Using GPU" } | Select-Object -First 1)
    $gpuTasks = [bool]($engineOutput | Where-Object { $_ -match "GPU Tasks" } | Select-Object -First 1)
    if (-not $proofLine) { throw "GPU result proof is missing for $key." }
    $proof = $proofLine.Substring("GPU_TRANSCRIBE_RESULT=".Length) | ConvertFrom-Json
    if (-not $proof.gpu_verified -or -not $usingGpu -or -not $gpuTasks) {
        throw "GPU verification failed for $key."
    }
    $verifiedChunkOutputs = @{}
    foreach ($extension in @(".txt", ".srt", ".vtt")) {
        $candidate = @($proof.outputs) | Where-Object {
            [IO.Path]::GetExtension([string]$_).ToLowerInvariant() -eq $extension
        } | Select-Object -First 1
        if (-not $candidate -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "Verified chunk output is missing: $key $extension"
        }
        $verifiedChunkOutputs[$extension] = $candidate
    }
    $chunkText = [string](Get-Content -LiteralPath $verifiedChunkOutputs[".txt"] -Raw -Encoding UTF8)
    $silentChunk = [string]::IsNullOrWhiteSpace($chunkText)
    $state.items[$key] = @{
        gpu_verified = $true
        using_gpu = $usingGpu
        gpu_tasks = $gpuTasks
        silent = $silentChunk
        outputs = @($proof.outputs)
        engine_log = $logPath
        start_seconds = $index * $ChunkSeconds
        completed_at = (Get-Date).ToUniversalTime().ToString("o")
    }
    $state.completed = @($state.items.Values | Where-Object { $_.gpu_verified }).Count
    Save-JsonAtomic -Path $statePath -Value $state
    Write-Output "GPU_CHUNK [$($index + 1)/$($existingChunks.Count)] $key ok"
}

$txtParts = @()
$srtCues = @()
$vttCues = @()
for ($index = 0; $index -lt $existingChunks.Count; $index++) {
    $key = $existingChunks[$index].BaseName
    $entry = $state.items[$key]
    if (-not $entry -or -not $entry.gpu_verified -or -not $entry.using_gpu -or -not $entry.gpu_tasks) {
        throw "Chunk proof is incomplete: $key"
    }
    $offsetMs = [int64]$entry.start_seconds * 1000
    $txtPath = @($entry.outputs) | Where-Object { [IO.Path]::GetExtension([string]$_) -eq ".txt" } | Select-Object -First 1
    $srtPath = @($entry.outputs) | Where-Object { [IO.Path]::GetExtension([string]$_) -eq ".srt" } | Select-Object -First 1
    $vttPath = @($entry.outputs) | Where-Object { [IO.Path]::GetExtension([string]$_) -eq ".vtt" } | Select-Object -First 1
    $txtPart = [string](Get-Content -LiteralPath $txtPath -Raw -Encoding UTF8)
    if (-not [string]::IsNullOrWhiteSpace($txtPart)) {
        $txtParts += $txtPart.Trim()
    }
    foreach ($cue in @(Get-SubtitleCues $srtPath)) {
        $srtCues += @{start_ms=[int64]$cue.start_ms + $offsetMs;end_ms=[int64]$cue.end_ms + $offsetMs;text=$cue.text}
    }
    foreach ($cue in @(Get-SubtitleCues $vttPath)) {
        $vttCues += @{start_ms=[int64]$cue.start_ms + $offsetMs;end_ms=[int64]$cue.end_ms + $offsetMs;text=$cue.text}
    }
}
$srtCues = @(Normalize-CueTimeline $srtCues)
$vttCues = @(Normalize-CueTimeline $vttCues)

$finalTxt = Join-Path $resolvedOutput "$baseName.txt"
$finalSrt = Join-Path $resolvedOutput "$baseName.srt"
$finalVtt = Join-Path $resolvedOutput "$baseName.vtt"
$txtContent = (@($txtParts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine).Trim()
$srtBlocks = for ($index = 0; $index -lt $srtCues.Count; $index++) {
    $cue = $srtCues[$index]
    "$($index + 1)`r`n$(Format-CueTime $cue.start_ms ',') --> $(Format-CueTime $cue.end_ms ',')`r`n$($cue.text)"
}
$vttBlocks = for ($index = 0; $index -lt $vttCues.Count; $index++) {
    $cue = $vttCues[$index]
    "$(Format-CueTime $cue.start_ms '.') --> $(Format-CueTime $cue.end_ms '.')`r`n$($cue.text)"
}
$finalValues = @{
    $finalTxt = "$txtContent`r`n"
    $finalSrt = (($srtBlocks -join "`r`n`r`n") + "`r`n")
    $finalVtt = ("WEBVTT`r`n`r`n" + ($vttBlocks -join "`r`n`r`n") + "`r`n")
}
foreach ($path in $finalValues.Keys) {
    $temporary = "$path.tmp"
    [IO.File]::WriteAllText($temporary, $finalValues[$path], [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $path -Force
    if ((Get-Item -LiteralPath $path).Length -le 0) { throw "Final output is empty: $path" }
}

$simplifier = Join-Path $PSScriptRoot "convert-to-simplified.ps1"
$simplifiedOutput = @(& $simplifier -Path @($finalTxt, $finalSrt, $finalVtt) 2>&1 |
    ForEach-Object { $_.ToString() })
$simplifiedProofLine = $simplifiedOutput | Where-Object { $_ -like "SIMPLIFIED_CHINESE_RESULT=*" } |
    Select-Object -Last 1
if (-not $simplifiedProofLine) { throw "Simplified-Chinese normalization proof is missing." }
$simplifiedProof = $simplifiedProofLine.Substring("SIMPLIFIED_CHINESE_RESULT=".Length) | ConvertFrom-Json
if (-not $simplifiedProof.success) { throw "Simplified-Chinese normalization failed." }

Remove-Item -LiteralPath $chunkRoot -Recurse -Force
$state.finished_at = (Get-Date).ToUniversalTime().ToString("o")
$state.final_outputs = @($finalTxt, $finalSrt, $finalVtt)
$state.gpu_verified = $true
Save-JsonAtomic -Path $statePath -Value $state
$result = @{
    engine = "chunked-gpu-wrapper"
    media = $resolvedMedia
    outputs = @($finalTxt, $finalSrt, $finalVtt)
    chunks = $existingChunks.Count
    gpu_verified = $true
    simplified_verified = $true
    simplified_tool = $simplifiedProof.tool
    proof_state = $statePath
    proof_logs = $proofRoot
}
Write-Output ("CHUNKED_GPU_TRANSCRIBE_RESULT=" + ($result | ConvertTo-Json -Compress))
Write-Output ("GPU_TRANSCRIBE_RESULT=" + ($result | ConvertTo-Json -Compress))
