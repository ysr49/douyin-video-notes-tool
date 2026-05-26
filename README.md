# Douyin Video Notes Tool

One-command Windows workflow for turning a Douyin link into:

- HD MP4 video
- MP3 audio
- raw transcript
- Markdown transcript
- structured Chinese notes
- a Codex skill that tells Codex how to run the workflow

## Requirements

- Windows PowerShell
- Python 3.11+
- Node.js
- Google Chrome at the default path, or set `CHROME_PATH`

## Install

Run once from this repository root:

```powershell
powershell -ExecutionPolicy Bypass -File tools/install-douyin-video-notes.ps1
```

The installer:

1. Installs Node dependencies.
2. Creates `video-transcript-capture/service/.venv`.
3. Installs Faster Whisper and related transcription dependencies.
4. Copies the Codex skill to `D:\CodexHome\skills\douyin-video-notes`.

## Usage

```powershell
powershell -ExecutionPolicy Bypass -File tools/douyin-video-notes.ps1 "https://v.douyin.com/xxxx/"
```

Outputs are written to `downloads/`.

## Force Whisper Transcription

By default, the tool uses SaveTik page text when available and falls back to Faster Whisper when needed.

To force audio transcription:

```powershell
powershell -ExecutionPolicy Bypass -File tools/douyin-video-notes.ps1 "https://v.douyin.com/xxxx/" --transcript-mode whisper
```

The default Whisper runtime is CPU/int8 for broad Windows compatibility. To use another setup:

```powershell
$env:WHISPER_MODEL="base"
$env:WHISPER_DEVICE="cpu"
$env:WHISPER_COMPUTE_TYPE="int8"
```

## Skip Video Download

Useful for quick tests:

```powershell
powershell -ExecutionPolicy Bypass -File tools/douyin-video-notes.ps1 "https://v.douyin.com/xxxx/" --skip-video
```

## Notes

- The SaveTik helper uses Playwright with your local Chrome to pass the webpage challenge and retrieve download links.
- Do not commit downloaded videos, audio, transcripts, virtual environments, or cache folders.
- Use this only for content you are allowed to download and process.
