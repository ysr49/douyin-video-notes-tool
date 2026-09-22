param(
    [string]$SearchRoot = "",
    [string]$TaskName = "GPUWorkflow-Cleanup-Every-5-Minutes"
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$cleanupScript = Join-Path $PSScriptRoot "cleanup-verified-media.ps1"
$hiddenRunner = Join-Path $PSScriptRoot "run-cleanup-hidden.vbs"
if (-not (Test-Path -LiteralPath $cleanupScript -PathType Leaf)) {
    throw "Cleanup script is missing: $cleanupScript"
}
if (-not (Test-Path -LiteralPath $hiddenRunner -PathType Leaf)) {
    throw "Hidden cleanup runner is missing: $hiddenRunner"
}

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
    throw "Cleanup search root is missing: $SearchRoot"
}

$actionText = "wscript.exe //B //NoLogo `"$hiddenRunner`" `"$cleanupScript`" `"$SearchRoot`""
& schtasks.exe /Create /F /SC MINUTE /MO 5 /TN $TaskName /TR $actionText | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Failed to register cleanup task: $TaskName"
}

& schtasks.exe /Query /TN $TaskName /FO LIST | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Cleanup task was created but could not be queried."
}

Write-Output ("GPU_WORKFLOW_CLEANUP_TASK_RESULT=" + (@{
    success = $true
    task_name = $TaskName
    interval_minutes = 5
    cleanup_script = $cleanupScript
    hidden_runner = $hiddenRunner
    search_root = $SearchRoot
} | ConvertTo-Json -Compress))
