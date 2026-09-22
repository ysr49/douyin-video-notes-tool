function Get-SkillRepoRoot {
    return (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..\..\..")).Path
}

function Get-DefaultDownloadsDir {
    $repoRoot = Get-SkillRepoRoot
    $resourceRoot = Get-ChildItem -LiteralPath $repoRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -like "03_*" -and
            (Test-Path -LiteralPath (Join-Path $_.FullName "downloads") -PathType Container)
        } |
        Select-Object -First 1
    if ($resourceRoot) {
        return Join-Path $resourceRoot.FullName "downloads"
    }
    return Join-Path $repoRoot "downloads"
}

function Get-WhisperGpuDir {
    $searchRoots = @()
    if ($env:WHISPER_GPU_DIR) { $searchRoots += $env:WHISPER_GPU_DIR }
    $repoRoot = Get-SkillRepoRoot
    $resourceRoot = Get-ChildItem -LiteralPath $repoRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "03_*" } |
        Select-Object -First 1
    if ($resourceRoot) {
        $searchRoots += Join-Path $resourceRoot.FullName "external\whisper-gpu"
    }
    $searchRoots += @(
        (Join-Path $repoRoot "whisper-gpu"),
        (Join-Path $env:USERPROFILE "Desktop")
    )
    foreach ($searchRoot in $searchRoots) {
        if (-not $searchRoot -or -not (Test-Path -LiteralPath $searchRoot)) { continue }
        $hit = Get-ChildItem -LiteralPath $searchRoot -Recurse -Filter "main.exe" -File -ErrorAction SilentlyContinue |
            Where-Object {
                (Test-Path -LiteralPath (Join-Path $_.DirectoryName "Whisper.dll")) -and
                (Test-Path -LiteralPath (Join-Path $_.DirectoryName "ggml-medium.bin"))
            } |
            Select-Object -First 1
        if ($hit) { return $hit.DirectoryName }
    }
    return $null
}

function Get-ChineseSubtitleConverter {
    $toolDir = Get-WhisperGpuDir
    if (-not $toolDir) { return $null }
    return Get-ChildItem -LiteralPath $toolDir -Recurse -Filter "*.exe" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.VersionInfo.FileDescription -eq "Chinese Subtitle Conversion Tool" } |
        Select-Object -First 1
}
