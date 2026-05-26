$ErrorActionPreference = "Stop"

$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
$VenvPython = Join-Path $Root "video-transcript-capture\service\.venv\Scripts\python.exe"
$Script = Join-Path $Root "tools\douyin_video_to_note.py"

if (Test-Path $VenvPython) {
    & $VenvPython $Script @args
} else {
    python $Script @args
}
