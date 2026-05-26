from __future__ import annotations

import argparse
import base64
import json
import os
import re
import subprocess
import sys
import urllib.request
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DOWNLOADS = ROOT / "downloads"
SAVETIK_HELPER = ROOT / "tools" / "savetik_fetch.js"
TRANSCRIPTION_APP = ROOT / "video-transcript-capture" / "service"


@dataclass(frozen=True)
class VideoAssets:
    video_id: str
    metadata_path: Path
    video_path: Path | None
    audio_path: Path | None
    transcript_source: str
    transcript_text: str
    duration: str


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Download a Douyin video, extract/transcribe text, and write a structured note."
    )
    parser.add_argument("url", help="Douyin share URL or full video URL")
    parser.add_argument("--out-dir", default=str(DOWNLOADS), help="Output directory")
    parser.add_argument(
        "--transcript-mode",
        choices=["auto", "savetik", "whisper"],
        default="auto",
        help="auto uses SaveTik text when present and falls back to Whisper; whisper forces audio transcription.",
    )
    parser.add_argument(
        "--skip-video",
        action="store_true",
        help="Only download audio and write transcripts/notes.",
    )
    args = parser.parse_args()

    out_dir = Path(args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    metadata_path = out_dir / "douyin_savetik_latest.json"
    run_savetik(args.url, metadata_path)
    metadata = read_json(metadata_path)
    ensure_ok(metadata)

    video_id = detect_video_id(args.url, metadata)
    stable_metadata_path = out_dir / f"douyin_{video_id}_savetik.json"
    stable_metadata_path.write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")

    video_path = None
    audio_path = None

    video_link = choose_link(metadata, "video")
    audio_link = choose_link(metadata, "audio")

    if video_link and not args.skip_video:
        video_path = out_dir / f"douyin_{video_id}_hd.mp4"
        download_file(video_link["href"], video_path)

    if audio_link:
        audio_path = out_dir / f"douyin_{video_id}_audio.mp3"
        download_file(audio_link["href"], audio_path)

    transcript_source = "savetik"
    transcript_text = str(metadata.get("transcript") or "").strip()

    if args.transcript_mode == "whisper" or (args.transcript_mode == "auto" and not transcript_text):
        if audio_path is None:
            raise RuntimeError("No MP3 link was available for Whisper transcription.")
        transcript_source = "whisper"
        transcript_text = transcribe_with_existing_tool(audio_path)

    if not transcript_text:
        raise RuntimeError("No transcript text was produced.")

    assets = VideoAssets(
        video_id=video_id,
        metadata_path=stable_metadata_path,
        video_path=video_path,
        audio_path=audio_path,
        transcript_source=transcript_source,
        transcript_text=normalize_transcript(transcript_text),
        duration=str(metadata.get("duration") or ""),
    )
    write_outputs(args.url, assets, out_dir)

    print("Done")
    print(f"Video ID: {assets.video_id}")
    if assets.video_path:
        print(f"Video: {assets.video_path}")
    if assets.audio_path:
        print(f"Audio: {assets.audio_path}")
    print(f"Transcript source: {assets.transcript_source}")
    print(f"Transcript: {out_dir / f'douyin_{assets.video_id}_transcript.md'}")
    print(f"Note: {out_dir / f'douyin_{assets.video_id}_整理版.md'}")
    return 0


def run_savetik(url: str, output_path: Path) -> None:
    command = ["node", str(SAVETIK_HELPER), url, str(output_path)]
    subprocess.run(command, cwd=str(ROOT), check=True)


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def ensure_ok(metadata: dict) -> None:
    if metadata.get("status") != "ok":
        message = metadata.get("message") or "SaveTik did not return a usable response."
        raise RuntimeError(message)


def detect_video_id(url: str, metadata: dict) -> str:
    haystack = json.dumps(metadata, ensure_ascii=False) + " " + url
    matches = re.findall(r"\b\d{16,22}\b", haystack)
    if matches:
        return matches[0]

    for link in metadata.get("links", []):
        payload = decode_snapcdn_payload(link.get("href", ""))
        filename_match = re.search(r"SaveTik\.co_(\d+)", payload)
        if filename_match:
            return filename_match.group(1)
        payload_matches = re.findall(r"\b\d{16,22}\b", payload)
        if payload_matches:
            return payload_matches[0]

    return "unknown"


def decode_snapcdn_payload(href: str) -> str:
    match = re.search(r"[?&]token=([^&]+)", href)
    if not match:
        return ""

    parts = match.group(1).split(".")
    if len(parts) < 2:
        return ""

    payload = parts[1]
    padding = "=" * (-len(payload) % 4)
    try:
        decoded = base64.urlsafe_b64decode(payload + padding)
    except Exception:
        return ""
    return decoded.decode("utf-8", errors="replace")


def choose_link(metadata: dict, kind: str) -> dict | None:
    links = metadata.get("links") or []
    if kind == "audio":
        return next((link for link in links if "MP3" in link.get("text", "").upper()), None)

    hd = next((link for link in links if "HD" in link.get("text", "").upper()), None)
    if hd:
        return hd
    return next((link for link in links if "MP4" in link.get("text", "").upper()), None)


def download_file(url: str, path: Path) -> None:
    if path.exists() and path.stat().st_size > 0:
        print(f"Reuse existing file: {path}")
        return

    tmp_path = path.with_suffix(path.suffix + ".download")
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": (
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0 Safari/537.36"
            )
        },
    )
    with urllib.request.urlopen(request, timeout=120) as response, tmp_path.open("wb") as handle:
        while True:
            chunk = response.read(1024 * 1024)
            if not chunk:
                break
            handle.write(chunk)
    tmp_path.replace(path)


def transcribe_with_existing_tool(audio_path: Path) -> str:
    sys.path.insert(0, str(TRANSCRIPTION_APP))
    try:
        from app.transcription import FasterWhisperTranscriber
    except ImportError:
        venv_python = TRANSCRIPTION_APP / ".venv" / "Scripts" / "python.exe"
        if not venv_python.exists():
            raise
        code = (
            "import json, sys; "
            f"sys.path.insert(0, {str(TRANSCRIPTION_APP)!r}); "
            "from pathlib import Path; "
            "from app.transcription import FasterWhisperTranscriber; "
            "t=FasterWhisperTranscriber().transcribe(Path(sys.argv[1])); "
            "print(json.dumps({'text': t.text}, ensure_ascii=False))"
        )
        result = subprocess.run(
            [str(venv_python), "-c", code, str(audio_path)],
            check=True,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        return json.loads(result.stdout)["text"]

    model_size = os.getenv("WHISPER_MODEL", "base")
    transcript = FasterWhisperTranscriber(model_size=model_size).transcribe(audio_path)
    return transcript.text


def normalize_transcript(text: str) -> str:
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def write_outputs(source_url: str, assets: VideoAssets, out_dir: Path) -> None:
    stem = f"douyin_{assets.video_id}"
    txt_path = out_dir / f"{stem}_transcript.txt"
    md_path = out_dir / f"{stem}_transcript.md"
    note_path = out_dir / f"{stem}_整理版.md"

    txt_path.write_text(assets.transcript_text + "\n", encoding="utf-8")
    md_path.write_text(render_transcript_markdown(source_url, assets), encoding="utf-8")
    note_path.write_text(render_structured_note(source_url, assets), encoding="utf-8")


def render_transcript_markdown(source_url: str, assets: VideoAssets) -> str:
    return "\n".join(
        [
            "# 抖音视频文字稿",
            "",
            f"来源：{source_url}",
            f"视频 ID：{assets.video_id}",
            f"时长：{assets.duration or '未知'}",
            f"提取方式：{assets.transcript_source}",
            "",
            "## 文字稿",
            "",
            assets.transcript_text,
            "",
        ]
    )


def render_structured_note(source_url: str, assets: VideoAssets) -> str:
    title = first_nonempty_line(assets.transcript_text) or "抖音视频笔记"
    lines = [line.strip() for line in assets.transcript_text.splitlines() if line.strip()]
    headings = extract_headings(lines)
    actions = extract_actions(lines)
    quotes = extract_quotes(lines)

    framework = "\n".join(f"{index}. {item}" for index, item in enumerate(headings[:6], start=1))
    if not framework:
        framework = "1. 先提取原始观点\n2. 再按主题分组\n3. 最后转成可执行动作"

    action_block = "\n".join(f"{index}. {item}" for index, item in enumerate(actions[:8], start=1))
    if not action_block:
        action_block = "1. 重读原始文字稿。\n2. 标出反复出现的关键词。\n3. 把关键词整理成行动清单。"

    quote_block = "\n".join(f"- {item}" for item in quotes[:6])
    if not quote_block:
        quote_block = "- " + title

    return "\n".join(
        [
            f"# {clean_title(title)}：整理版",
            "",
            f"来源：{source_url}",
            f"视频 ID：{assets.video_id}",
            f"时长：{assets.duration or '未知'}",
            f"整理方式：{assets.transcript_source} 文字稿 + 默认结构化笔记模板",
            "",
            "## 一句话总结",
            "",
            summarize_one_sentence(lines),
            "",
            "## 核心框架",
            "",
            framework,
            "",
            "## 分步骤拆解",
            "",
            assets.transcript_text,
            "",
            "## 可执行清单",
            "",
            action_block,
            "",
            "## 金句",
            "",
            quote_block,
            "",
        ]
    )


def first_nonempty_line(text: str) -> str:
    for line in text.splitlines():
        if line.strip():
            return line.strip()
    return ""


def clean_title(value: str) -> str:
    value = re.sub(r"\s+", " ", value).strip()
    return value[:60]


def summarize_one_sentence(lines: list[str]) -> str:
    text = " ".join(lines[:3])
    return clean_title(text) or "本视频围绕一个主题展开，并提供了可复盘的观点和行动步骤。"


def extract_headings(lines: list[str]) -> list[str]:
    patterns = [
        r"^第[一二三四五六七八九十]+步[:：]?\s*(.+)$",
        r"^\d{1,2}[.、]\s*(.+)$",
        r"^(.{2,24})[:：]$",
    ]
    results: list[str] = []
    for line in lines:
        for pattern in patterns:
            match = re.match(pattern, line)
            if match:
                item = match.group(1).strip()
                if item and item not in results:
                    results.append(item)
                break
    return results


def extract_actions(lines: list[str]) -> list[str]:
    keywords = ("做", "找", "看", "用", "画", "讲", "复盘", "分享", "封装", "剥离")
    results: list[str] = []
    for line in lines:
        if any(keyword in line for keyword in keywords) and 6 <= len(line) <= 80:
            if line not in results:
                results.append(line)
    return results


def extract_quotes(lines: list[str]) -> list[str]:
    results: list[str] = []
    for line in lines:
        if "不是" in line or "不要" in line or "比" in line or "？" in line or "?" in line:
            if 6 <= len(line) <= 90 and line not in results:
                results.append(line)
    return results


if __name__ == "__main__":
    raise SystemExit(main())
