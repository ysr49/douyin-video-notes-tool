# Douyin Video Notes Tool

把一条视频链接变成 **GPU 校验过的简体中文文字稿**（TXT / SRT / VTT）。

这不是云端 Whisper API，也不是 Python Faster-Whisper。默认路径是：

**解析真实媒体地址 → IDM 下载 → ffprobe 校验 → 本机 GPU Whisper 转写 → 繁体转简体 → 可选删视频。**

旧的 SaveTik + Faster Whisper 流程还留在 `tools/douyin_video_to_note.py`，需要时加 `-Legacy`。

## 它是怎么跑的

```
视频链接
    │
    ▼
video-link-workflow          总入口，判断平台
    │
    ├─ 抖音/TikTok ────────► Playwright 打开分享页
    │                         读取页面自己的 aweme/detail
    │                         取出 play_addr / download_addr
    │                              │
    │                              ▼
    │                         idm-download
    │                         IDM 下 mp4，ffprobe 验时长和音视频流
    │
    ├─ 直接媒体 URL ───────► idm-download
    │
    └─ B 站 / YouTube 等 ──► yt-dlp + ffmpeg
                                   │
                                   ▼
                            gpu-transcribe
                            本机 GPU Whisper medium
                            必须日志里同时出现 Using GPU 和 GPU Tasks
                            再跑繁体简体转换工具
                                   │
                                   ▼
                            downloads/<id>.txt
                            downloads/<id>.srt
                            downloads/<id>.vtt
```

给 Agent 用时，把 `.agents/skills/` 拷进对方的 skills 目录。四个子 skill：

| skill | 干什么 |
| --- | --- |
| `video-link-workflow` | 链接总入口 |
| `idm-download` | 只负责已经解析好的 HTTP 媒体地址 |
| `gpu-transcribe` | 只接受本地文件，禁止自动落到 CPU |
| `gpu-workflow` | 博主主页批量：每次 4 条，转完就删 mp4 |

`douyin-video-notes` 是给用户口令用的外壳，内部还是上面这条链。

## 别人机器上还要自备什么

这个仓库 **不上传** IDM、Whisper 执行文件、ggml 模型、cookie、视频。

对方需要：

1. Windows
2. Node.js
3. Google Chrome（或设 `CHROME_PATH`）
4. [Internet Download Manager](https://www.internetdownloadmanager.com/)
5. ffmpeg / ffprobe 在 PATH 里
6. 本机「音频视频转文字 GPU」工具目录，里面至少有：
   - `main.exe`
   - `Whisper.dll`
   - `ggml-medium.bin`
   - 繁体简体转换工具.exe

找不到引擎时设环境变量：

```powershell
$env:WHISPER_GPU_DIR = "C:\path\to\whisper-gpu-folder"
```

只处理自己有权下载、转写的内容。

## 安装

```powershell
powershell -ExecutionPolicy Bypass -File tools/install-douyin-video-notes.ps1
```

安装脚本会 `npm install`（只要 `playwright-core`），并在能找到的 Agent skills 目录里复制 skill：

- `%USERPROFILE%\.agents\skills`
- `%USERPROFILE%\.codex\skills`
- `%CODEX_HOME%\skills` 或 `D:\CodexHome\skills`

## 用法

```powershell
# 先看本机缺什么
powershell -ExecutionPolicy Bypass -File tools/douyin-video-notes.ps1 -Probe

# 抖音分享链接：下载 + GPU 转写（默认转完删 mp4）
powershell -ExecutionPolicy Bypass -File tools/douyin-video-notes.ps1 "https://v.douyin.com/xxxx/"

# 只下载
powershell -ExecutionPolicy Bypass -File tools/douyin-video-notes.ps1 "https://v.douyin.com/xxxx/" -Action download

# 留下视频
powershell -ExecutionPolicy Bypass -File tools/douyin-video-notes.ps1 "https://v.douyin.com/xxxx/" -KeepVideo
```

成功时脚本会打印：

- `DOUYIN_IDM_SINGLE_RESULT=...`
- `GPU_TRANSCRIBE_RESULT=...` 且 `"gpu_verified":true`
- `VIDEO_LINK_WORKFLOW_RESULT=...` 且 `"success":true`

没有 GPU 证明就视为失败，不会悄悄用 CPU 凑一篇稿。

## 博主主页批量

先自己导出作品清单（登录态、滚动完整页，这个仓库不内置偷 cookie）。清单校验：

```powershell
node .agents/skills/gpu-workflow/scripts/validate-douyin-manifest.js manifest.json 217
```

再跑：

```powershell
powershell -ExecutionPolicy Bypass -File .agents/skills/gpu-workflow/scripts/douyin-author-gpu-pipeline.ps1 `
  -ManifestPath ".\manifest.json" `
  -WorkflowRoot ".\work\author" `
  -BatchSize 4
```

## 旧流程

```powershell
powershell -ExecutionPolicy Bypass -File tools/douyin-video-notes.ps1 "https://v.douyin.com/xxxx/" -Legacy
```

那条路走 SaveTik 网页文本，没有文本才用 Faster Whisper。新默认不再走它。
