---
name: video-link-workflow
description: Unified IDM-to-GPU workflow for any user-provided video URL, including Douyin/TikTok, Bilibili, YouTube, ordinary webpages, playlists, and direct media links. Use whenever the user drops a video link and asks to download, save, extract audio, transcribe, create subtitles, summarize, analyze, or make notes, and whenever the user says “gpu 工作流” or “gpu skill”. Resolve webpage streams first, download resolved media through idm-download, verify it, and route speech-to-text through gpu-transcribe.
---

# Video Link Workflow

Treat this as the single user-facing gateway for video links.

## Route

1. Infer the requested action: `download`, `transcript`, or `both`. If the user merely provides a video link in a transcription/analysis context, use `both`.
2. For a single Douyin or TikTok video, invoke the local Douyin detail resolver, then download its resolved media URL through `idm-download`. For a creator homepage, invoke `gpu-workflow` and export the complete works manifest through the authorized Browser session before downloading.
3. For a resolved direct media URL, invoke `idm-download`. Wait for its verified result before continuing.
4. For Bilibili, YouTube, or another webpage URL, use `yt-dlp` to resolve and download the best permitted video plus audio. IDM is not a webpage parser. Use a browser session only when the site requires the user's legitimate login state and command-line cookie extraction fails.
5. Verify every downloaded file with `ffprobe`. Do not claim success for an IDM queue entry, HTML error page, missing audio track, or corrupt container.
6. For transcripts, subtitles, notes, or content analysis, invoke `gpu-transcribe` on the verified local media. Accept success only when that skill reports `gpu_verified:true` and proves both `Using GPU` and `GPU Tasks`.
7. Read and analyze the transcript, not the full media, unless visual inspection is necessary.

## Long-video thermal policy

- Transcribe a verified video in one pass by default.
- Use chunked, resumable GPU transcription only after measured sustained overheating, a failed whole-file run, or an explicit user request.
- Keep the same GPU engine and verification rules for every chunk; chunking never authorizes CPU fallback.
- Prefer fewer, larger chunks that remain within the measured temperature limit. Do not create tiny chunks without evidence that they are needed.
- Merge chunks back into one time-ordered UTF-8 transcript, verify every retained chunk, then delete task-specific chunk audio, logs, and runner files.
- The user-facing result is the single merged transcript; internal chunk files are recovery artifacts, not the deliverable.

## Command

Use the bundled orchestrator for supported non-interactive paths:

```powershell
powershell -ExecutionPolicy Bypass -File ".agents/skills/video-link-workflow/scripts/video-link-workflow.ps1" "<url>" -Action both
```

Useful variants:

```powershell
# Download only
powershell -ExecutionPolicy Bypass -File ".agents/skills/video-link-workflow/scripts/video-link-workflow.ps1" "<url>" -Action download

# Use an authenticated browser profile with yt-dlp
powershell -ExecutionPolicy Bypass -File ".agents/skills/video-link-workflow/scripts/video-link-workflow.ps1" "<url>" -Action both -Browser edge

# Download an explicitly requested playlist/series
powershell -ExecutionPolicy Bypass -File ".agents/skills/video-link-workflow/scripts/video-link-workflow.ps1" "<url>" -Action download -Playlist

# Check local dependencies without downloading
powershell -ExecutionPolicy Bypass -File ".agents/skills/video-link-workflow/scripts/video-link-workflow.ps1" -Probe
```

The script prints a final `VIDEO_LINK_WORKFLOW_RESULT=<json>` record. Treat the operation as complete only when the record says `success:true`.

## Hard rules

- Never use Python Whisper, faster-whisper, whisper-cpp, an API, or CPU transcription as an automatic fallback.
- Never use IDM alone for a webpage that still needs media URL extraction, cookies, request headers, DASH selection, or audio/video merging.
- Never bypass DRM, payment, membership, or access controls. Use only media the user can legitimately access.
- Do not expose browser cookies or signed media URLs in the response or logs.
- Keep downloaded video when the user asks to save it. For transcript-only work, delete it only after verified transcript outputs exist and the relevant platform adapter permits cleanup.
- Do not redownload an existing verified file unless the user asks for replacement or the file is incomplete.

## Failure handling

- If a site rejects public extraction, retry with the user's already-authorized browser session when available.
- If Chrome/Edge cookie decryption fails, use a controllable browser session and extract permitted media data from the page; do not print credentials.
- If IDM cannot finish or needs headers it cannot receive through its CLI, re-resolve the media URL through the platform adapter or authenticated browser. Keep GPU transcription unchanged.
- If GPU proof is missing, stop and report the blocker. Never silently finish with CPU output.
