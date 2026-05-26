---
name: douyin-video-notes
description: Download Douyin videos, extract or transcribe audio, and produce structured Chinese notes. Use when: the user gives a Douyin/TikTok short video link and asks to download, transcribe, summarize, 整理, 提取文字稿, or make notes.
---

# Douyin Video Notes

Use this workflow when the user gives a Douyin video link and wants the video, transcript, and a structured note.

## Default Command

From `D:/CC_test`:

```powershell
powershell -ExecutionPolicy Bypass -File tools/douyin-video-notes.ps1 "https://v.douyin.com/xxxx/"
```

The command writes files under `D:/CC_test/downloads`.

## Outputs

For a detected video id `<id>`, expect:

- `downloads/douyin_<id>_hd.mp4`
- `downloads/douyin_<id>_audio.mp3`
- `downloads/douyin_<id>_savetik.json`
- `downloads/douyin_<id>_transcript.txt`
- `downloads/douyin_<id>_transcript.md`
- `downloads/douyin_<id>_整理版.md`

## Workflow

1. Run `tools/douyin-video-notes.ps1` with the user-provided URL.
2. The script uses SaveTik through `tools/savetik_fetch.js` to retrieve download links and page text.
3. The script downloads MP4 HD and MP3 when available.
4. By default, it uses SaveTik text if present. If no text is present, it calls the existing `video-transcript-capture` Faster Whisper transcriber.
5. If the user specifically wants audio transcription, pass `--transcript-mode whisper`.
6. After the command completes, read `downloads/douyin_<id>_整理版.md`.
7. If the generated note is too mechanical, improve it manually in the same default style:
   - 一句话总结
   - 核心框架
   - 分步骤拆解
   - 可执行清单
   - 金句

## Install

Run once from `D:/CC_test`:

```powershell
powershell -ExecutionPolicy Bypass -File tools/install-douyin-video-notes.ps1
```

This installs Node dependencies, Python transcription dependencies, and copies this skill to `D:/CodexHome/skills/douyin-video-notes`.

## Failure Handling

- If Chrome is not installed in the default path, set `CHROME_PATH`.
- If SaveTik fails, report the error and do not pretend the video was processed.
- If Whisper is requested and dependencies are missing, run the installer again.
- If the generated note has mojibake, reread/write files explicitly as UTF-8.
