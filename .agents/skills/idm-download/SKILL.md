---
name: idm-download
description: Download resolved HTTP/HTTPS media URLs with the user's installed Internet Download Manager (IDM), wait for a complete stable file, and verify it with ffprobe. Use for direct video or audio URLs, resolved Douyin/TikTok play_addr or download_addr values, and whenever the user says IDM download, gpu workflow, or gpu skill as the download stage before GPU transcription. Do not pass ordinary webpage URLs to IDM without first resolving the actual media URL.
---

# IDM Download

Use IDM only after a platform adapter, browser, or extractor has resolved the actual media URL.

## Command

```powershell
& ".agents/skills/idm-download/scripts/idm-download.ps1" `
  -Url "<resolved-media-url>" `
  -OutputDir "D:/output" `
  -FileName "video-id.mp4"
```

Probe dependencies without downloading:

```powershell
& ".agents/skills/idm-download/scripts/idm-download.ps1" -Probe
```

For a JSON manifest containing `media_url`, `play_addr`, or `download_addr`:

```powershell
& ".agents/skills/idm-download/scripts/idm-download-batch.ps1" `
  -ManifestPath "D:/input/manifest.json" `
  -OutputDir "D:/output"
```

## Acceptance rules

1. Require a resolved HTTP/HTTPS media URL. IDM is a downloader, not a Douyin webpage parser.
2. Wait for the target file to become stable; do not treat an IDM queue entry as success.
3. Require `ffprobe` to report positive duration and at least one audio or video stream.
4. Accept success only when the wrapper prints `IDM_DOWNLOAD_RESULT` with `"success":true` and `"media_verified":true`.
5. Never expose signed media URLs in logs or user-facing output.
6. Reuse an existing target only after the same media verification succeeds.

## GPU workflow

For “gpu 工作流” or “gpu skill”:

1. Resolve the platform URL through `video-link-workflow` and its platform adapter.
2. Download each resolved media URL through this skill.
3. Verify the media through this skill and `ffprobe`.
4. Pass only verified local media to `gpu-transcribe`.
5. Accept transcription only with `gpu_verified:true`, `Using GPU`, and `GPU Tasks`.

