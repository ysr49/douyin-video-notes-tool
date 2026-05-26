# Douyin Video Notes

One-command local workflow for Douyin links:

1. Fetch video/audio download links.
2. Download HD MP4 and MP3.
3. Extract text from SaveTik or transcribe audio with the existing Faster Whisper tool.
4. Produce raw transcript files and a structured Chinese note.

## Install

From `D:/CC_test`:

```powershell
powershell -ExecutionPolicy Bypass -File tools/install-douyin-video-notes.ps1
```

## Run

```powershell
powershell -ExecutionPolicy Bypass -File tools/douyin-video-notes.ps1 "https://v.douyin.com/xxxx/"
```

Force Whisper transcription:

```powershell
powershell -ExecutionPolicy Bypass -File tools/douyin-video-notes.ps1 "https://v.douyin.com/xxxx/" --transcript-mode whisper
```

Skip MP4 download and only produce transcript/note assets:

```powershell
powershell -ExecutionPolicy Bypass -File tools/douyin-video-notes.ps1 "https://v.douyin.com/xxxx/" --skip-video
```
