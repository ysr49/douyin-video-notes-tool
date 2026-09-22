param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$MediaPath,
    [string]$OutputDir,
    [ValidateSet("txt", "srt", "vtt")]
    [string[]]$Formats = @("txt"),
    [string]$Language = "zh",
    [int]$Adapter = 0,
    [ValidateRange(0, 64)]
    [int]$Threads = 0,
    [switch]$PlainText,
    [switch]$SpeedUp,
    [string]$ToolDir,
    [string]$ModelPath
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

if (-not $ToolDir) {
    . (Join-Path $PSScriptRoot "Find-WhisperGpuDir.ps1")
    $ToolDir = Get-WhisperGpuDir
    if (-not $ToolDir) {
        throw "GPU transcription tool was not found. Set WHISPER_GPU_DIR to the folder that contains main.exe, Whisper.dll, and ggml-medium.bin, or pass -ToolDir."
    }
}

$exe = Join-Path $ToolDir "main.exe"
if (-not $ModelPath) {
    $ModelPath = Join-Path $ToolDir "ggml-medium.bin"
}

$resolvedMedia = (Resolve-Path -LiteralPath $MediaPath).Path
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    throw "GPU transcription executable not found: $exe"
}
if (-not (Test-Path -LiteralPath $ModelPath -PathType Leaf)) {
    throw "GPU transcription model not found: $ModelPath"
}

$adapterOutput = (& $exe --list-adapters 2>&1 | Out-String)
$adapterLines = @($adapterOutput -split "`r?`n" | Where-Object { $_ -match '^".+"$' })
if ($Adapter -lt 0 -or $Adapter -ge $adapterLines.Count) {
    throw "GPU adapter index $Adapter is unavailable. Detected adapters: $($adapterLines -join ', ')"
}
if ($adapterLines[$Adapter] -notmatch "NVIDIA|AMD|Intel") {
    throw "Selected adapter is not a hardware GPU: $($adapterLines[$Adapter])"
}

$arguments = @(
    "--use-gpu", "$Adapter",
    "--model", $ModelPath,
    "--file", $resolvedMedia,
    "--language", $Language,
    "--no-colors"
)

foreach ($format in ($Formats | Select-Object -Unique)) {
    switch ($format) {
        "txt" { $arguments += "--output-txt" }
        "srt" { $arguments += "--output-srt" }
        "vtt" { $arguments += "--output-vtt" }
    }
}
if ($PlainText -and $Formats -contains "txt") {
    $arguments += "--no-timestamps"
}
if ($SpeedUp) {
    $arguments += "--speed-up"
}
if ($Threads -gt 0) {
    $arguments += @("--threads", "$Threads")
}

$tempBase = [System.IO.Path]::GetTempFileName()
$stdoutPath = "$tempBase.stdout"
$stderrPath = "$tempBase.stderr"
Remove-Item -LiteralPath $tempBase -Force
try {
    $process = Start-Process -FilePath $exe -ArgumentList $arguments -WorkingDirectory $ToolDir -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    # Some builds of the desktop engine return from Start-Process -Wait before
    # PowerShell has refreshed the native process handle, leaving ExitCode at
    # the sentinel value -1. Explicitly wait and refresh before reading it.
    $process.WaitForExit()
    $process.Refresh()
    $exitCode = $process.ExitCode
    $stdoutText = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -Raw -LiteralPath $stdoutPath } else { "" }
    $stderrText = if (Test-Path -LiteralPath $stderrPath) { Get-Content -Raw -LiteralPath $stderrPath } else { "" }
    $logText = "$stdoutText`n$stderrText"
} finally {
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
}

if ($exitCode -ne 0) {
    throw "GPU transcription failed with exit code $exitCode."
}
if ($logText -notmatch 'Using GPU\s+"' -or $logText -notmatch "GPU Tasks") {
    throw "Transcription returned without verifiable GPU execution. CPU fallback is forbidden."
}
Write-Output (($logText -split "`r?`n" | Where-Object { $_ -match 'Using GPU|Loaded model from|GPU Tasks|Total\s' }) -join "`n")

$sourceBase = [System.IO.Path]::Combine(
    [System.IO.Path]::GetDirectoryName($resolvedMedia),
    [System.IO.Path]::GetFileNameWithoutExtension($resolvedMedia)
)
$outputs = @()
foreach ($format in ($Formats | Select-Object -Unique)) {
    $sourceOutput = "$sourceBase.$format"
    if (-not (Test-Path -LiteralPath $sourceOutput -PathType Leaf)) {
        throw "GPU engine completed but expected output is missing: $sourceOutput"
    }

    $finalOutput = $sourceOutput
    if ($OutputDir) {
        $resolvedOutputDir = [System.IO.Path]::GetFullPath($OutputDir)
        New-Item -ItemType Directory -Force -Path $resolvedOutputDir | Out-Null
        $finalOutput = Join-Path $resolvedOutputDir ([System.IO.Path]::GetFileName($sourceOutput))
        if ($finalOutput -ne $sourceOutput) {
            Copy-Item -LiteralPath $sourceOutput -Destination $finalOutput -Force
        }
    }
    $outputs += $finalOutput
}

$simplifier = Join-Path $PSScriptRoot "convert-to-simplified.ps1"
if (-not (Test-Path -LiteralPath $simplifier -PathType Leaf)) {
    throw "Simplified-Chinese normalization step is missing: $simplifier"
}
$simplifiedOutput = @(& $simplifier -Path $outputs 2>&1 | ForEach-Object { $_.ToString() })
$simplifiedOutput | ForEach-Object { Write-Output $_ }
$simplifiedProofLine = $simplifiedOutput | Where-Object { $_ -like "SIMPLIFIED_CHINESE_RESULT=*" } |
    Select-Object -Last 1
if (-not $simplifiedProofLine) { throw "Simplified-Chinese normalization proof is missing." }
$simplifiedProof = $simplifiedProofLine.Substring("SIMPLIFIED_CHINESE_RESULT=".Length) | ConvertFrom-Json
if (-not $simplifiedProof.success) { throw "Simplified-Chinese normalization failed." }

$result = [ordered]@{
    engine = $exe
    model = $ModelPath
    adapter = $adapterLines[$Adapter].Trim('"')
    gpu_verified = $true
    simplified_verified = $true
    simplified_tool = $simplifiedProof.tool
    media = $resolvedMedia
    outputs = $outputs
}
Write-Output ("GPU_TRANSCRIBE_RESULT=" + ($result | ConvertTo-Json -Compress))
