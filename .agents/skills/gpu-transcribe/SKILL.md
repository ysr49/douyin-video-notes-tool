---
name: gpu-transcribe
description: Strict GPU-only transcription gateway and final stage of the user's “gpu 工作流” or “gpu skill” flow for every video/audio-to-text task, including local media, Douyin/TikTok downloads, podcasts, meetings, subtitles, captions, dialogue extraction, and transcripts. For URLs, resolve through video-link-workflow and download through idm-download before invoking the existing Whisper GPU desktop tool. Never substitute Python Whisper, faster-whisper, whisper-cpp, an API, or CPU transcription unless the user explicitly changes this rule.
---

# GPU Transcribe

Use this as the single transcription gateway for every skill and workflow.

## Required tool

Invoke the user's installed GPU engine through:

```powershell
powershell -ExecutionPolicy Bypass -File ".agents/skills/gpu-transcribe/scripts/gpu-transcribe.ps1" "<media-path>"
```

The wrapper looks for the user's already-installed GPU engine:

1. `WHISPER_GPU_DIR` if set
2. `<repo>/03_*/external/whisper-gpu` when that workspace layout exists
3. `<repo>/whisper-gpu`
4. the Desktop

The folder must contain `main.exe`, `Whisper.dll`, and `ggml-medium.bin`. This repository does not vendor those binaries.

Do not replace this engine with another Whisper implementation.

## Rules

1. For URLs, invoke `video-link-workflow`, resolve the actual media URL, and download it through `idm-download`. For local inputs, locate the media without altering it.
2. Pass the resulting media file to the wrapper above.
3. Treat the run as successful only when the wrapper verifies both `Using GPU` and `GPU Tasks` in the engine log.
4. Return the generated transcript/subtitle paths.
5. If the executable, model, adapter, GPU proof, or output is missing, stop and report the blocker. Never fall back to CPU automatically.
6. Normalize every final TXT, SRT, and VTT to Simplified Chinese with the bundled `繁体简体转换工具.exe`. Completion requires `SIMPLIFIED_CHINESE_RESULT` with `success:true`; retain GPU proof separately.

## Options

```powershell
# Plain UTF-8 transcript without timestamps
powershell -ExecutionPolicy Bypass -File ".agents/skills/gpu-transcribe/scripts/gpu-transcribe.ps1" "input.mp4" -PlainText

# TXT, SRT, and VTT in a selected directory
powershell -ExecutionPolicy Bypass -File ".agents/skills/gpu-transcribe/scripts/gpu-transcribe.ps1" "input.mp4" -Formats txt,srt,vtt -OutputDir "D:/output"

# Change language or adapter only when needed
powershell -ExecutionPolicy Bypass -File ".agents/skills/gpu-transcribe/scripts/gpu-transcribe.ps1" "input.mp4" -Language zh -Adapter 0

# Optional engine speed-up mode; some legacy builds reject this option
powershell -ExecutionPolicy Bypass -File ".agents/skills/gpu-transcribe/scripts/gpu-transcribe.ps1" "input.mp4" -SpeedUp

# Override host threads only after measuring the actual machine
powershell -ExecutionPolicy Bypass -File ".agents/skills/gpu-transcribe/scripts/gpu-transcribe.ps1" "input.mp4" -Threads 1
```

Use `-SpeedUp` only as a tested compatibility option. The currently installed legacy engine has returned exit code 10 for this flag, so never depend on it or accept a missing output.

Use the engine default thread count unless a measured performance test supports an override.

The default model is the user's existing multilingual `ggml-medium.bin`; never use an `.en` model for Chinese media.

Batch transcription has no temperature gate or fixed cooldown. Transcribe whole files by default. After an actual whole-file failure, `scripts/gpu-transcribe-chunked.ps1` may be used as a resumable fallback; it requires independent GPU proof for every chunk and merges TXT/SRT/VTT with continuous timestamps. Never delete the source media until final outputs are verified.

A chunk with no recognizable speech may legitimately produce an empty TXT/SRT payload. Accept it only when that chunk still has independent `Using GPU`, `GPU Tasks`, and `gpu_verified:true` proof; record it as `silent:true` and skip its empty text during the merge. The merged final TXT, SRT, and VTT must still all exist and be non-empty.

## Batch command

For a verified local media directory, use the resumable batch wrapper:

```powershell
& ".agents/skills/gpu-transcribe/scripts/gpu-transcribe-batch.ps1" `
  -MediaDir "D:/media" `
  -OutputDir "D:/transcripts" `
  -StatePath "D:/transcription-state.json"
```

Accept completion only when every retained item has `gpu_verified:true` and the final `GPU_BATCH_RESULT` reports success.
