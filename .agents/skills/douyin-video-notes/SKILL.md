---
name: douyin-video-notes
description: Download Douyin videos, extract or transcribe audio, and produce GPU-verified Chinese transcripts. Use when the user gives a Douyin/TikTok or other video link and asks to download, transcribe, summarize, 整理, 提取文字稿, or make notes.
---

# Douyin Video Notes

This skill is the user-facing entry for the GPU workflow. It does not transcribe in Python. It routes to `video-link-workflow` → `idm-download` → `gpu-transcribe`.

## Default command

From this repository root:

```powershell
powershell -ExecutionPolicy Bypass -File tools/douyin-video-notes.ps1 "https://v.douyin.com/xxxx/"
```

Equivalent orchestrator:

```powershell
powershell -ExecutionPolicy Bypass -File .agents/skills/video-link-workflow/scripts/video-link-workflow.ps1 "https://v.douyin.com/xxxx/" -Action both
```

Outputs land in `downloads/` unless `-OutputDir` is passed.

## What a single Douyin link does

1. Open the share page in local Chrome through Playwright.
2. Read the page's own `aweme/detail` response and take a media URL.
3. Download that URL with Internet Download Manager.
4. Verify the file with `ffprobe`.
5. Transcribe on the local NVIDIA/AMD/Intel GPU Whisper desktop engine.
6. Convert the TXT/SRT/VTT to Simplified Chinese.
7. Delete the mp4 after verified transcripts exist, unless `-KeepVideo` is passed.

## Required local software

This repo ships scripts only. The other person still needs:

- Windows + Node.js + Chrome
- Internet Download Manager (`IDMan.exe`)
- ffmpeg / ffprobe on PATH
- The Whisper GPU desktop folder (`main.exe`, `Whisper.dll`, `ggml-medium.bin`, plus the bundled 繁体简体转换工具)

Set `WHISPER_GPU_DIR` if the engine is not on the Desktop and not under `03_*/external/whisper-gpu`.

## Related skills

- `video-link-workflow` — URL gateway (Douyin, Bilibili, YouTube, direct media)
- `idm-download` — IDM download + ffprobe verify
- `gpu-transcribe` — GPU-only transcription
- `gpu-workflow` — creator-homepage batch pipeline
