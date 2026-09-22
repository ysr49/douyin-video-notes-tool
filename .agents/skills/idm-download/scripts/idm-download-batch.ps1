param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,
    [Parameter(Mandatory = $true)]
    [string]$OutputDir,
    [int]$TimeoutSeconds = 1800
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$wrapper = Join-Path $PSScriptRoot "idm-download.ps1"
$data = Get-Content -Raw -Encoding UTF8 -LiteralPath $ManifestPath | ConvertFrom-Json
$items = if ($data -is [Array]) { @($data) } elseif ($data.posts) { @($data.posts) } elseif ($data.items) { @($data.items) } else { @($data) }
$results = @()

foreach ($item in $items) {
    $id = [string]$(if ($item.aweme_id) { $item.aweme_id } elseif ($item.id) { $item.id } else { "" })
    $mediaUrl = [string]$(if ($item.media_url) { $item.media_url } elseif ($item.play_addr) { $item.play_addr } elseif ($item.download_addr) { $item.download_addr } elseif ($item.video.play_addr) { $item.video.play_addr } elseif ($item.video.download_addr) { $item.video.download_addr } else { "" })
    if (-not $mediaUrl) {
        $results += @{id=$id; success=$false; error="missing resolved media URL"}
        continue
    }
    $fileName = [string]$(if ($item.file_name) { $item.file_name } elseif ($id) { "$id.mp4" } else { "media-$($results.Count + 1).mp4" })
    try {
        $output = @(& $wrapper -Url $mediaUrl -OutputDir $OutputDir -FileName $fileName -TimeoutSeconds $TimeoutSeconds 2>&1 | ForEach-Object { $_.ToString() })
        $proof = $output | Where-Object { $_ -like "IDM_DOWNLOAD_RESULT=*" } | Select-Object -Last 1
        if (-not $proof) { throw "IDM result record is missing." }
        $parsed = $proof.Substring("IDM_DOWNLOAD_RESULT=".Length) | ConvertFrom-Json
        if (-not $parsed.success -or -not $parsed.media_verified) { throw "IDM media verification failed." }
        $results += @{id=$id; success=$true; path=$parsed.path; bytes=$parsed.bytes}
    } catch {
        $results += @{id=$id; success=$false; error=$_.Exception.Message}
    }
}

$summary = @{
    success = (@($results | Where-Object { -not $_.success }).Count -eq 0)
    total = $results.Count
    completed = @($results | Where-Object { $_.success }).Count
    failed = @($results | Where-Object { -not $_.success }).Count
    results = $results
}
Write-Output ("IDM_BATCH_RESULT=" + ($summary | ConvertTo-Json -Depth 8 -Compress))
if (-not $summary.success) { exit 1 }

