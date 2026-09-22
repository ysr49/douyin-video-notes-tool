---
name: gpu-workflow
description: Unified “GPU工作流” for downloading and transcribing video or audio with verified local tools. Use whenever the user says GPU工作流, gpu workflow, gpu skill, 抖音下载视频转写文字, 抖音视频转文字, 下载视频转文字, 视频转写, 视频提取文字, 博主全部视频转写, 把这个博主所有视频转成文字, or provides a Douyin/TikTok/video URL or creator homepage and asks for transcripts, subtitles, captions, notes, or dialogue extraction. Resolve platform URLs, download through IDM, verify media with ffprobe, transcribe only through gpu-transcribe, and clean verified temporary media.
---

# GPU工作流

Use this as the only top-level video/audio transcription workflow.

## Route

1. For a local media file or directory, invoke `gpu-transcribe`.
2. For a single URL, resolve it through `video-link-workflow`, download through `idm-download`, and transcribe through `gpu-transcribe`.
3. For a Douyin creator homepage:
   - Open the authorized page through the Browser skill.
   - Scroll the works container until the unique exported work count equals the visible `作品 N` count.
   - Export `video`, `note`, and `article` links separately and remove unrelated footer recommendations.
   - Validate the exported manifest against the visible count with `validate-douyin-manifest.js`; stop if the count, URL uniqueness, ID uniqueness, or item types do not match.
   - Run `douyin-author-gpu-pipeline.ps1` with the manifest and a workflow root.
   - Download and transcribe bounded batches so the media directory does not grow without limit. The default batch size is four.
   - Transcribe each verified media file in one pass. Use `gpu-transcribe-chunked.ps1` only to resume a file after the whole-file GPU run actually fails or when the user explicitly requests chunking.
4. Never treat captions, page summaries, descriptions, or `章节要点` as GPU transcripts.

## Acceptance

- Accept a download only with `IDM_DOWNLOAD_RESULT` containing `success:true` and `media_verified:true`.
- Accept a transcript only with `GPU_TRANSCRIBE_RESULT` containing `gpu_verified:true` and engine proof containing both `Using GPU` and `GPU Tasks`.
- Accept user-facing TXT/SRT/VTT only after the bundled Traditional-to-Simplified tool reports `SIMPLIFIED_CHINESE_RESULT` with `success:true`.
- Require non-empty TXT, SRT, and VTT outputs for batch cleanup.
- Keep failed or unverified media for retry.
- Do not gate work on GPU temperature and do not insert fixed cooldown waits.
- After a GPU-driver crash, preserve state and retry only the failed file. Use `gpu-transcribe-chunked.ps1` as a resumable fallback; every retained chunk still requires `Using GPU`, `GPU Tasks`, and `gpu_verified:true`, and merged subtitles must have continuous timestamps.

## Temporary media cleanup

Install the local five-minute cleanup task once:

```powershell
& ".agents/skills/gpu-workflow/scripts/install-cleanup-task.ps1"
```

The task consumes no model quota. It deletes media only when the matching transcription state says `gpu_verified:true`, TXT/SRT/VTT all exist and are non-empty, and the media is inside that workflow's `media` directory.

The separate two-hour progress-monitor automation is not part of this cleanup task and must remain independent.

Validate a creator manifest:

```powershell
node ".agents/skills/gpu-workflow/scripts/validate-douyin-manifest.js" `
  "D:/path/to/manifest.json" 217
```

Run cleanup manually:

```powershell
& ".agents/skills/gpu-workflow/scripts/cleanup-verified-media.ps1" `
  -SearchRoot "downloads"
```

## Commands

Probe the complete workflow:

```powershell
& ".agents/skills/gpu-workflow/scripts/gpu-workflow.ps1" -Probe
```

Transcribe a local media directory:

```powershell
& ".agents/skills/gpu-workflow/scripts/gpu-workflow.ps1" `
  -MediaDir "D:/media" `
  -OutputDir "D:/transcripts"
```

Run a resumable Douyin creator pipeline:

```powershell
& ".agents/skills/gpu-workflow/scripts/douyin-author-gpu-pipeline.ps1" `
  -ManifestPath "D:/path/to/manifest.json" `
  -WorkflowRoot "D:/path/to/workflow" `
  -BatchSize 4
```

The pipeline writes `GPU_AUTHOR_PIPELINE_RESULT=<json>` only after every manifest video has a GPU-verified TXT/SRT/VTT set. The five-minute cleanup task is a safety net; the pipeline also cleans immediately after every verified batch.
