param(
    [string[]]$Path = @(),
    [switch]$Probe
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

. (Join-Path $PSScriptRoot "Find-WhisperGpuDir.ps1")
$converterExe = Get-ChineseSubtitleConverter
if (-not $converterExe) { throw "Bundled Traditional-to-Simplified converter was not found. Set WHISPER_GPU_DIR to the Whisper GPU tool folder." }

$assembly = [Reflection.Assembly]::LoadFile($converterExe.FullName)
$formType = $assembly.GetType("ChineseSubtitleConversionTool.FormMain", $true)
$method = $formType.GetMethod("StringToSimlified", [Reflection.BindingFlags]"Public,Instance")
if (-not $method) { throw "Bundled converter method StringToSimlified is unavailable." }
$converter = [Activator]::CreateInstance($formType)

try {
    if ($Probe) {
        $traditional = (@(0x5B78,0x7FD2,0x7E41,0x9AD4,0x4E2D,0x6587,0xFF0C,0x88E1,0x9762) |
            ForEach-Object { [char]$_ }) -join ""
        $expected = (@(0x5B66,0x4E60,0x7E41,0x4F53,0x4E2D,0x6587,0xFF0C,0x91CC,0x9762) |
            ForEach-Object { [char]$_ }) -join ""
        $sample = [string]$method.Invoke($converter, @($traditional, $false))
        $success = $sample -eq $expected
        Write-Output ("SIMPLIFIED_CHINESE_PROBE=" + (@{
            success = $success
            tool = $converterExe.FullName
            sample = $sample
        } | ConvertTo-Json -Compress))
        if (-not $success) { exit 1 }
        exit 0
    }

    if ($Path.Count -eq 0) { throw "At least one transcript path is required." }
    $results = @()
    foreach ($item in $Path) {
        $resolved = (Resolve-Path -LiteralPath $item -ErrorAction Stop).Path
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "Transcript file is missing: $item"
        }
        $beforeHash = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash
        $source = [IO.File]::ReadAllText($resolved, [Text.Encoding]::UTF8)
        $simplified = [string]$method.Invoke($converter, @($source, $false))
        if ($null -eq $simplified) { throw "Converter returned null: $resolved" }
        $temporary = "$resolved.simplified.tmp"
        [IO.File]::WriteAllText($temporary, $simplified, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $resolved -Force
        $afterHash = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash
        $results += @{
            path = $resolved
            changed = $beforeHash -ne $afterHash
            before_sha256 = $beforeHash
            after_sha256 = $afterHash
            bytes = (Get-Item -LiteralPath $resolved).Length
        }
    }
    Write-Output ("SIMPLIFIED_CHINESE_RESULT=" + (@{
        success = $true
        tool = $converterExe.FullName
        files = $results
    } | ConvertTo-Json -Depth 6 -Compress))
} finally {
    if ($converter -and $converter -is [IDisposable]) { $converter.Dispose() }
}
