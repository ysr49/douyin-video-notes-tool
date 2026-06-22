# VideoKB Douyin MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the frozen VideoKB foundation and a safe, resumable Douyin end-to-end adapter that produces zero-Token transcript and knowledge-base deliverables.

**Architecture:** A Python core owns schemas, SQLite state, downloading, transcription, deterministic exports, CLI, and orchestration. Platform-specific discovery is isolated behind an adapter contract; the Douyin adapter calls a small Node/Playwright bridge for authenticated pagination, then returns normalized items to the Python core. Existing single-video scripts remain available until the compatibility task verifies the new pipeline.

**Tech Stack:** Python 3.11+, stdlib `argparse/sqlite3/urllib`, Faster-Whisper, pytest, Node.js, Playwright Core, PowerShell.

---

## File Map

| Path | Responsibility |
|---|---|
| `pyproject.toml` | Python package, CLI entry point, pytest configuration |
| `src/videokb/models.py` | Frozen platform-neutral data contracts and statuses |
| `src/videokb/adapters/base.py` | Adapter protocol and errors |
| `src/videokb/adapters/registry.py` | Platform detection and `available/planned/disabled` registry |
| `src/videokb/adapters/douyin.py` | Douyin bridge invocation and normalization |
| `src/videokb/adapters/douyin_bridge.mjs` | Safe Playwright login, pagination, response capture |
| `src/videokb/db.py` | SQLite schema, idempotency and state transitions |
| `src/videokb/workspace.py` | Stable creator workspace layout and atomic writes |
| `src/videokb/downloader.py` | Cookie-free media download and retention |
| `src/videokb/transcriber.py` | Faster-Whisper segment transcription |
| `src/videokb/exporters.py` | JSON, Markdown, TXT, SRT, CSV, JSONL and anthology exports |
| `src/videokb/safety.py` | Conservative limits and block conditions |
| `src/videokb/orchestrator.py` | Resume-safe end-to-end sync pipeline |
| `src/videokb/cli.py` | Six frozen CLI commands and compact JSON output |
| `tools/videokb.ps1` | Windows entry wrapper |
| `.agents/skills/videokb/SKILL.md` | Natural-language-to-CLI Codex skill |
| `tests/fixtures/douyin/*.json` | Sanitized recorded platform responses |
| `tests/` | Unit, contract, recovery, safety and end-to-end tests |

The existing `tools/douyin_video_to_note.py` and related SaveTik files are not deleted in this plan.

### Task 1: Package Scaffold and Frozen CLI Surface

**Files:**
- Create: `pyproject.toml`
- Create: `src/videokb/__init__.py`
- Create: `src/videokb/cli.py`
- Create: `tests/test_cli.py`

- [ ] **Step 1: Write the failing CLI smoke tests**

```python
from videokb.cli import build_parser


def test_frozen_commands_are_registered():
    parser = build_parser()
    for command in ("sync", "status", "retry", "export", "ai", "platforms"):
        args = parser.parse_args([command] + (["https://example.com"] if command == "sync" else []))
        assert args.command == command


def test_sync_defaults_to_zero_ai_and_delete_audio():
    args = build_parser().parse_args(["sync", "https://example.com"])
    assert args.ai == "off"
    assert args.keep_audio is False
```

- [ ] **Step 2: Run the tests and verify the package is absent**

Run: `python -m pytest tests/test_cli.py -v`

Expected: FAIL with `ModuleNotFoundError: No module named 'videokb'`.

- [ ] **Step 3: Add package metadata and the minimal parser**

```toml
[build-system]
requires = ["setuptools>=69"]
build-backend = "setuptools.build_meta"

[project]
name = "videokb"
version = "0.1.0"
requires-python = ">=3.11"

[project.scripts]
videokb = "videokb.cli:main"

[tool.setuptools.packages.find]
where = ["src"]

[tool.pytest.ini_options]
pythonpath = ["src"]
testpaths = ["tests"]
```

```python
# src/videokb/cli.py
import argparse


COMMANDS = ("sync", "status", "retry", "export", "ai", "platforms")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="videokb")
    sub = parser.add_subparsers(dest="command", required=True)
    sync = sub.add_parser("sync")
    sync.add_argument("url")
    sync.add_argument("--ai", choices=("off", "local", "cloud"), default="off")
    sync.add_argument("--keep-audio", action="store_true")
    for name in COMMANDS[1:]:
        sub.add_parser(name)
    return parser


def main() -> int:
    build_parser().parse_args()
    return 0
```

- [ ] **Step 4: Install editable package and run tests**

Run: `python -m pip install -e . && python -m pytest tests/test_cli.py -v`

Expected: 2 tests PASS.

- [ ] **Step 5: Commit the scaffold**

```powershell
git add pyproject.toml src/videokb tests/test_cli.py
git commit -m "feat: scaffold VideoKB CLI"
```

### Task 2: Platform-Neutral Models and Adapter Registry

**Files:**
- Create: `src/videokb/models.py`
- Create: `src/videokb/adapters/__init__.py`
- Create: `src/videokb/adapters/base.py`
- Create: `src/videokb/adapters/registry.py`
- Create: `tests/test_registry.py`

- [ ] **Step 1: Write registry and model contract tests**

```python
from videokb.adapters.registry import AdapterRegistry, PlatformState
from videokb.models import MediaCandidate, VideoItem


def test_registry_detects_douyin_and_reports_planned_platforms():
    registry = AdapterRegistry.default()
    assert registry.detect("https://www.douyin.com/user/abc").adapter_id == "douyin"
    assert registry.states()["bilibili"] == PlatformState.PLANNED
    assert registry.states()["youtube"] == PlatformState.PLANNED


def test_video_identity_is_platform_plus_video_id():
    item = VideoItem(
        platform="douyin", creator_id="c1", creator_name="A", video_id="v1",
        title="T", source_url="https://example.com/v1", published_at=None,
        duration_ms=1000, media_candidates=(MediaCandidate("audio", "https://cdn/a"),),
    )
    assert item.identity == "douyin:v1"
```

- [ ] **Step 2: Verify tests fail**

Run: `python -m pytest tests/test_registry.py -v`

Expected: FAIL because models and registry do not exist.

- [ ] **Step 3: Implement frozen contracts and registry states**

```python
# src/videokb/models.py
from dataclasses import dataclass
from datetime import datetime
from enum import StrEnum


class ItemStatus(StrEnum):
    DISCOVERED = "discovered"
    DOWNLOADED = "downloaded"
    TRANSCRIBED = "transcribed"
    EXPORTED = "exported"
    AI_PROCESSED = "ai_processed"
    FAILED = "failed"
    BLOCKED = "blocked"


@dataclass(frozen=True)
class MediaCandidate:
    kind: str
    url: str
    expires_at: datetime | None = None


@dataclass(frozen=True)
class VideoItem:
    platform: str
    creator_id: str
    creator_name: str
    video_id: str
    title: str
    source_url: str
    published_at: datetime | None
    duration_ms: int | None
    media_candidates: tuple[MediaCandidate, ...]

    @property
    def identity(self) -> str:
        return f"{self.platform}:{self.video_id}"
```

```python
# src/videokb/adapters/registry.py
from dataclasses import dataclass
from enum import StrEnum


class PlatformState(StrEnum):
    AVAILABLE = "available"
    PLANNED = "planned"
    DISABLED = "disabled"


@dataclass(frozen=True)
class AdapterInfo:
    adapter_id: str
    domains: tuple[str, ...]
    state: PlatformState


class AdapterRegistry:
    def __init__(self, adapters: tuple[AdapterInfo, ...]):
        self.adapters = adapters

    @classmethod
    def default(cls):
        return cls((
            AdapterInfo("douyin", ("douyin.com", "v.douyin.com"), PlatformState.AVAILABLE),
            AdapterInfo("bilibili", ("bilibili.com", "b23.tv"), PlatformState.PLANNED),
            AdapterInfo("xiaohongshu", ("xiaohongshu.com", "xhslink.com"), PlatformState.PLANNED),
            AdapterInfo("wechat_channels", (), PlatformState.PLANNED),
            AdapterInfo("youtube", ("youtube.com", "youtu.be"), PlatformState.PLANNED),
            AdapterInfo("kuaishou", ("kuaishou.com",), PlatformState.PLANNED),
            AdapterInfo("tiktok", ("tiktok.com",), PlatformState.PLANNED),
        ))

    def detect(self, url: str) -> AdapterInfo:
        for adapter in self.adapters:
            if any(domain in url.lower() for domain in adapter.domains):
                return adapter
        raise ValueError("unsupported platform URL")

    def states(self) -> dict[str, PlatformState]:
        return {adapter.adapter_id: adapter.state for adapter in self.adapters}
```

- [ ] **Step 4: Run contract tests**

Run: `python -m pytest tests/test_registry.py -v`

Expected: 2 tests PASS.

- [ ] **Step 5: Commit contracts**

```powershell
git add src/videokb/models.py src/videokb/adapters tests/test_registry.py
git commit -m "feat: define adapter contracts"
```

### Task 3: SQLite State, Idempotency, and Resume

**Files:**
- Create: `src/videokb/db.py`
- Create: `tests/test_db.py`

- [ ] **Step 1: Write state transition and resume tests**

```python
from videokb.db import StateDB
from videokb.models import ItemStatus


def test_upsert_is_idempotent_and_preserves_completed_status(tmp_path):
    db = StateDB(tmp_path / "project.db")
    db.upsert_item("douyin", "v1", "c1", "Title", "https://x/v1")
    db.set_status("douyin", "v1", ItemStatus.EXPORTED)
    db.upsert_item("douyin", "v1", "c1", "Updated", "https://x/v1")
    row = db.get_item("douyin", "v1")
    assert row["status"] == "exported"
    assert row["title"] == "Updated"


def test_pending_returns_only_unfinished_items(tmp_path):
    db = StateDB(tmp_path / "project.db")
    db.upsert_item("douyin", "v1", "c1", "A", "https://x/1")
    db.upsert_item("douyin", "v2", "c1", "B", "https://x/2")
    db.set_status("douyin", "v1", ItemStatus.EXPORTED)
    assert [row["video_id"] for row in db.pending()] == ["v2"]
```

- [ ] **Step 2: Verify tests fail**

Run: `python -m pytest tests/test_db.py -v`

Expected: FAIL because `StateDB` is absent.

- [ ] **Step 3: Implement SQLite schema and guarded upsert**

```python
# src/videokb/db.py
import sqlite3
from pathlib import Path
from videokb.models import ItemStatus


SCHEMA = """
CREATE TABLE IF NOT EXISTS items (
  platform TEXT NOT NULL,
  video_id TEXT NOT NULL,
  creator_id TEXT NOT NULL,
  title TEXT NOT NULL,
  source_url TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'discovered',
  content_hash TEXT,
  retry_count INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY(platform, video_id)
);
"""


class StateDB:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.connection = sqlite3.connect(path)
        self.connection.row_factory = sqlite3.Row
        self.connection.executescript(SCHEMA)

    def upsert_item(self, platform, video_id, creator_id, title, source_url):
        self.connection.execute(
            """INSERT INTO items(platform,video_id,creator_id,title,source_url)
               VALUES(?,?,?,?,?) ON CONFLICT(platform,video_id) DO UPDATE SET
               creator_id=excluded.creator_id,title=excluded.title,
               source_url=excluded.source_url,updated_at=CURRENT_TIMESTAMP""",
            (platform, video_id, creator_id, title, source_url),
        )
        self.connection.commit()

    def set_status(self, platform, video_id, status: ItemStatus, error=None):
        self.connection.execute(
            "UPDATE items SET status=?,last_error=?,updated_at=CURRENT_TIMESTAMP WHERE platform=? AND video_id=?",
            (status.value, error, platform, video_id),
        )
        self.connection.commit()

    def get_item(self, platform, video_id):
        row = self.connection.execute(
            "SELECT * FROM items WHERE platform=? AND video_id=?", (platform, video_id)
        ).fetchone()
        return dict(row) if row else None

    def pending(self):
        rows = self.connection.execute(
            "SELECT * FROM items WHERE status NOT IN ('exported','ai_processed') ORDER BY rowid"
        ).fetchall()
        return [dict(row) for row in rows]
```

- [ ] **Step 4: Run database tests**

Run: `python -m pytest tests/test_db.py -v`

Expected: 2 tests PASS.

- [ ] **Step 5: Commit state storage**

```powershell
git add src/videokb/db.py tests/test_db.py
git commit -m "feat: add resumable SQLite state"
```

### Task 4: Stable Workspace and Atomic Deliverables

**Files:**
- Create: `src/videokb/workspace.py`
- Create: `tests/test_workspace.py`

- [ ] **Step 1: Write layout and atomic-write tests**

```python
from videokb.workspace import CreatorWorkspace


def test_creator_workspace_matches_frozen_layout(tmp_path):
    ws = CreatorWorkspace(tmp_path, "douyin", "creator-1")
    ws.ensure()
    assert ws.db_path == tmp_path / "douyin" / "creator-1" / "project.db"
    assert ws.originals.is_dir()
    assert ws.knowledge.is_dir()
    assert ws.ai.is_dir()
    assert ws.audio.is_dir()


def test_atomic_text_replaces_target(tmp_path):
    ws = CreatorWorkspace(tmp_path, "douyin", "c")
    ws.ensure()
    target = ws.originals / "v1.txt"
    ws.write_text(target, "完整文字")
    assert target.read_text(encoding="utf-8") == "完整文字"
    assert not target.with_suffix(".tmp").exists()
```

- [ ] **Step 2: Verify tests fail**

Run: `python -m pytest tests/test_workspace.py -v`

Expected: FAIL because `CreatorWorkspace` is absent.

- [ ] **Step 3: Implement the frozen layout**

```python
# src/videokb/workspace.py
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class CreatorWorkspace:
    root: Path
    platform: str
    creator_id: str

    @property
    def base(self): return self.root / self.platform / self.creator_id
    @property
    def db_path(self): return self.base / "project.db"
    @property
    def originals(self): return self.base / "originals"
    @property
    def knowledge(self): return self.base / "knowledge"
    @property
    def ai(self): return self.base / "ai"
    @property
    def audio(self): return self.base / "audio"

    def ensure(self):
        for directory in (self.originals, self.knowledge, self.ai, self.audio):
            directory.mkdir(parents=True, exist_ok=True)

    def write_text(self, target: Path, value: str):
        temporary = target.with_suffix(".tmp")
        temporary.write_text(value, encoding="utf-8")
        temporary.replace(target)
```

- [ ] **Step 4: Run workspace tests**

Run: `python -m pytest tests/test_workspace.py -v`

Expected: 2 tests PASS.

- [ ] **Step 5: Commit workspace layout**

```powershell
git add src/videokb/workspace.py tests/test_workspace.py
git commit -m "feat: add stable creator workspace"
```

### Task 5: Timestamped Transcription Contract

**Files:**
- Modify: `video-transcript-capture/service/app/transcription.py`
- Create: `src/videokb/transcriber.py`
- Create: `tests/test_transcriber.py`

- [ ] **Step 1: Write segment normalization test with a fake engine**

```python
from videokb.transcriber import SegmentTranscriber


class FakeModel:
    def transcribe(self, _path):
        segments = [type("S", (), {"start": 0.0, "end": 1.25, "text": " 第一段 "})()]
        return segments, None


def test_transcriber_preserves_millisecond_timestamps(tmp_path):
    audio = tmp_path / "a.mp3"
    audio.write_bytes(b"audio")
    result = SegmentTranscriber(model=FakeModel()).transcribe(audio)
    assert result.full_text == "第一段"
    assert result.segments[0].start_ms == 0
    assert result.segments[0].end_ms == 1250
```

- [ ] **Step 2: Verify test fails**

Run: `python -m pytest tests/test_transcriber.py -v`

Expected: FAIL because `SegmentTranscriber` is absent.

- [ ] **Step 3: Implement platform-neutral transcript segments**

```python
# src/videokb/transcriber.py
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class TranscriptSegment:
    start_ms: int
    end_ms: int
    text: str


@dataclass(frozen=True)
class TranscriptDocument:
    full_text: str
    segments: tuple[TranscriptSegment, ...]
    engine: str = "faster-whisper"
    model: str = "base"


class SegmentTranscriber:
    def __init__(self, model):
        self.model = model

    def transcribe(self, audio_path: Path) -> TranscriptDocument:
        raw_segments, _ = self.model.transcribe(str(audio_path))
        segments = tuple(
            TranscriptSegment(round(s.start * 1000), round(s.end * 1000), s.text.strip())
            for s in raw_segments if s.text.strip()
        )
        return TranscriptDocument(" ".join(s.text for s in segments), segments)
```

Update the legacy transcriber to expose segment data without changing its existing `Transcript.text` behavior; add a new method rather than breaking callers.

- [ ] **Step 4: Run transcription contract tests**

Run: `python -m pytest tests/test_transcriber.py -v`

Expected: 1 test PASS.

- [ ] **Step 5: Commit timestamp support**

```powershell
git add src/videokb/transcriber.py tests/test_transcriber.py video-transcript-capture/service/app/transcription.py
git commit -m "feat: preserve transcript timestamps"
```

### Task 6: Deterministic Exporters and Zero-Token Knowledge Material

**Files:**
- Create: `src/videokb/exporters.py`
- Create: `tests/test_exporters.py`

- [ ] **Step 1: Write exact export tests**

```python
import json
from videokb.exporters import render_srt, knowledge_rows
from videokb.transcriber import TranscriptDocument, TranscriptSegment


def document():
    return TranscriptDocument("你好 世界", (
        TranscriptSegment(0, 1250, "你好"),
        TranscriptSegment(1500, 3000, "世界"),
    ))


def test_srt_has_stable_timestamps():
    assert render_srt(document()).startswith("1\n00:00:00,000 --> 00:00:01,250\n你好")


def test_knowledge_rows_are_traceable_without_ai():
    rows = knowledge_rows("douyin", "v1", "https://x/v1", document())
    assert rows[0] == {
        "platform": "douyin", "video_id": "v1", "source_url": "https://x/v1",
        "start_ms": 0, "end_ms": 1250, "text": "你好"
    }
```

- [ ] **Step 2: Verify exporter tests fail**

Run: `python -m pytest tests/test_exporters.py -v`

Expected: FAIL because exporter functions are absent.

- [ ] **Step 3: Implement deterministic rendering**

```python
# src/videokb/exporters.py
def _stamp(ms: int) -> str:
    hours, rem = divmod(ms, 3_600_000)
    minutes, rem = divmod(rem, 60_000)
    seconds, millis = divmod(rem, 1000)
    return f"{hours:02}:{minutes:02}:{seconds:02},{millis:03}"


def render_srt(document) -> str:
    blocks = []
    for index, segment in enumerate(document.segments, 1):
        blocks.append(
            f"{index}\n{_stamp(segment.start_ms)} --> {_stamp(segment.end_ms)}\n{segment.text}"
        )
    return "\n\n".join(blocks) + "\n"


def knowledge_rows(platform, video_id, source_url, document):
    return [{
        "platform": platform, "video_id": video_id, "source_url": source_url,
        "start_ms": s.start_ms, "end_ms": s.end_ms, "text": s.text,
    } for s in document.segments]
```

Add JSON, Markdown, TXT, CSV, JSONL and anthology writers using `CreatorWorkspace.write_text`; all files must use UTF-8 and stable key ordering where applicable.

- [ ] **Step 4: Run exporter tests**

Run: `python -m pytest tests/test_exporters.py -v`

Expected: 2 tests PASS.

- [ ] **Step 5: Commit deterministic exports**

```powershell
git add src/videokb/exporters.py tests/test_exporters.py
git commit -m "feat: add zero-token knowledge exports"
```

### Task 7: Cookie-Free Downloader and Retention

**Files:**
- Create: `src/videokb/downloader.py`
- Create: `tests/test_downloader.py`

- [ ] **Step 1: Write reuse and retention tests**

```python
from videokb.downloader import remove_after_success, select_audio_url
from videokb.models import MediaCandidate


def test_select_audio_prefers_audio_candidate():
    items = (MediaCandidate("video", "v"), MediaCandidate("audio", "a"))
    assert select_audio_url(items) == "a"


def test_success_deletes_audio_unless_keep_requested(tmp_path):
    audio = tmp_path / "a.mp3"
    audio.write_bytes(b"x")
    remove_after_success(audio, keep_audio=False)
    assert not audio.exists()
```

- [ ] **Step 2: Verify tests fail**

Run: `python -m pytest tests/test_downloader.py -v`

Expected: FAIL because downloader functions are absent.

- [ ] **Step 3: Implement atomic cookie-free download**

```python
# src/videokb/downloader.py
from pathlib import Path
from urllib.request import Request, urlopen


def select_audio_url(candidates):
    chosen = next((c for c in candidates if c.kind == "audio"), None)
    if chosen is None:
        chosen = next((c for c in candidates if c.kind == "video"), None)
    if chosen is None:
        raise ValueError("no downloadable media candidate")
    return chosen.url


def download(url: str, target: Path):
    if target.exists() and target.stat().st_size:
        return target
    temporary = target.with_suffix(target.suffix + ".download")
    request = Request(url, headers={"User-Agent": "Mozilla/5.0", "Referer": "https://www.douyin.com/"})
    with urlopen(request, timeout=120) as response, temporary.open("wb") as handle:
        while chunk := response.read(1024 * 1024):
            handle.write(chunk)
    temporary.replace(target)
    return target


def remove_after_success(audio: Path, keep_audio: bool):
    if not keep_audio and audio.exists():
        audio.unlink()
```

No cookie parameter is accepted by this module.

- [ ] **Step 4: Run downloader tests**

Run: `python -m pytest tests/test_downloader.py -v`

Expected: 2 tests PASS.

- [ ] **Step 5: Commit downloader**

```powershell
git add src/videokb/downloader.py tests/test_downloader.py
git commit -m "feat: add cookie-free media downloader"
```

### Task 8: Safety Policy and Immediate Blocking

**Files:**
- Create: `src/videokb/safety.py`
- Create: `tests/test_safety.py`

- [ ] **Step 1: Write block-condition tests**

```python
import pytest
from videokb.safety import PlatformBlocked, SafetyPolicy


@pytest.mark.parametrize("status", [403, 429])
def test_platform_safety_statuses_block_immediately(status):
    with pytest.raises(PlatformBlocked):
        SafetyPolicy().check_response(status, "")


def test_captcha_and_empty_api_block_immediately():
    policy = SafetyPolicy()
    with pytest.raises(PlatformBlocked):
        policy.check_response(200, "验证码")
    with pytest.raises(PlatformBlocked):
        policy.check_response(200, "")
```

- [ ] **Step 2: Verify tests fail**

Run: `python -m pytest tests/test_safety.py -v`

Expected: FAIL because safety types are absent.

- [ ] **Step 3: Implement conservative policy**

```python
# src/videokb/safety.py
from dataclasses import dataclass


class PlatformBlocked(RuntimeError):
    pass


@dataclass(frozen=True)
class SafetyPolicy:
    page_delay_min_seconds: float = 1.5
    page_delay_max_seconds: float = 3.5
    media_concurrency: int = 2
    creator_concurrency: int = 1
    max_pages_per_creator_per_run: int = 100

    def check_response(self, status: int, body: str):
        if status in (403, 429):
            raise PlatformBlocked(f"platform returned HTTP {status}")
        if not body.strip() or "验证码" in body or "captcha" in body.lower():
            raise PlatformBlocked("platform verification or abnormal empty response")
```

- [ ] **Step 4: Run safety tests**

Run: `python -m pytest tests/test_safety.py -v`

Expected: 3 tests PASS.

- [ ] **Step 5: Commit safety controls**

```powershell
git add src/videokb/safety.py tests/test_safety.py
git commit -m "feat: enforce platform safety baseline"
```

### Task 9: Douyin Adapter with Recorded Contract Fixtures

**Files:**
- Create: `src/videokb/adapters/douyin.py`
- Create: `src/videokb/adapters/douyin_bridge.mjs`
- Create: `tests/fixtures/douyin/page_1.json`
- Create: `tests/fixtures/douyin/page_2.json`
- Create: `tests/test_douyin_adapter.py`

- [ ] **Step 1: Add sanitized fixture fields and normalization test**

Fixture items retain only `aweme_id`, `desc`, `create_time`, minimal `author`, `duration`, `music.play_url.url_list`, `video.play_addr.url_list`, `max_cursor`, `has_more`, and `status_code`.

```python
import json
from pathlib import Path
from videokb.adapters.douyin import normalize_pages


def test_recorded_pages_normalize_and_deduplicate():
    fixture = Path("tests/fixtures/douyin")
    pages = [json.loads((fixture / name).read_text(encoding="utf-8")) for name in ("page_1.json", "page_2.json")]
    items = normalize_pages(pages)
    assert len({item.video_id for item in items}) == len(items)
    assert all(item.platform == "douyin" for item in items)
    assert all(item.media_candidates for item in items)
```

- [ ] **Step 2: Verify test fails**

Run: `python -m pytest tests/test_douyin_adapter.py -v`

Expected: FAIL because the Douyin adapter is absent.

- [ ] **Step 3: Implement Python normalization and bridge invocation**

```python
# src/videokb/adapters/douyin.py
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from videokb.models import MediaCandidate, VideoItem


def normalize_pages(pages):
    unique = {}
    for page in pages:
        for raw in page.get("aweme_list", []):
            video_id = str(raw["aweme_id"])
            author = raw.get("author", {})
            audio = raw.get("music", {}).get("play_url", {}).get("url_list", [])
            video = raw.get("video", {}).get("play_addr", {}).get("url_list", [])
            candidates = tuple(MediaCandidate("audio", url) for url in audio)
            candidates += tuple(MediaCandidate("video", url) for url in video)
            unique[video_id] = VideoItem(
                "douyin", str(author.get("sec_uid") or author.get("uid") or "unknown"),
                str(author.get("nickname") or "unknown"), video_id, str(raw.get("desc") or ""),
                f"https://www.douyin.com/video/{video_id}",
                datetime.fromtimestamp(raw["create_time"], timezone.utc) if raw.get("create_time") else None,
                raw.get("duration"), candidates,
            )
    return list(unique.values())


def discover(url: str, bridge: Path, output: Path):
    subprocess.run(["node", str(bridge), url, str(output)], check=True)
    return normalize_pages(json.loads(output.read_text(encoding="utf-8")))
```

- [ ] **Step 4: Implement the Node bridge safety behavior**

The bridge must use a persistent platform-specific profile, open a visible official login page only when anonymous pagination reports a login gate, capture `/aweme/v1/web/aweme/post/` JSON responses, scroll one creator at a time with 1.5–3.5 second jitter, stop on `has_more=0`, and exit non-zero on CAPTCHA, 403, 429 or abnormal empty responses. It writes normalized raw pages to the requested output path and prints only progress counts, never cookies or response bodies.

- [ ] **Step 5: Run fixture tests without platform access**

Run: `python -m pytest tests/test_douyin_adapter.py -v`

Expected: 1 test PASS with no network access.

- [ ] **Step 6: Commit Douyin adapter**

```powershell
git add src/videokb/adapters/douyin.py src/videokb/adapters/douyin_bridge.mjs tests/fixtures/douyin tests/test_douyin_adapter.py
git commit -m "feat: add safe Douyin adapter"
```

### Task 10: Resume-Safe Orchestrator

**Files:**
- Create: `src/videokb/orchestrator.py`
- Create: `tests/test_orchestrator.py`

- [ ] **Step 1: Write an end-to-end fake-adapter test**

```python
from videokb.orchestrator import SyncOrchestrator


def test_second_sync_skips_exported_item(fake_components, tmp_path):
    orchestrator = SyncOrchestrator(workspace_root=tmp_path, **fake_components)
    first = orchestrator.sync("https://www.douyin.com/user/x")
    second = orchestrator.sync("https://www.douyin.com/user/x")
    assert first == {"discovered": 1, "processed": 1, "skipped": 0, "failed": 0, "blocked": 0}
    assert second == {"discovered": 1, "processed": 0, "skipped": 1, "failed": 0, "blocked": 0}
    assert fake_components["transcriber"].calls == 1
```

- [ ] **Step 2: Verify test fails**

Run: `python -m pytest tests/test_orchestrator.py -v`

Expected: FAIL because `SyncOrchestrator` is absent.

- [ ] **Step 3: Implement the state-driven pipeline**

`SyncOrchestrator.sync()` must perform these exact guarded transitions per item:

```text
discover → DB upsert → skip exported hash match
→ download → downloaded
→ transcribe segments → transcribed
→ write original JSON/MD/TXT/SRT → exported
→ append deterministic knowledge JSONL
→ delete audio unless keep_audio
```

Wrap each item independently. Network failures increment `retry_count` and set `failed`; `PlatformBlocked` marks the platform task blocked and stops further platform requests. Return only the compact count dictionary asserted above.

- [ ] **Step 4: Run orchestrator and recovery tests**

Run: `python -m pytest tests/test_orchestrator.py -v`

Expected: fake-adapter sync and repeat-sync tests PASS.

- [ ] **Step 5: Commit orchestration**

```powershell
git add src/videokb/orchestrator.py tests/test_orchestrator.py
git commit -m "feat: add resumable sync orchestration"
```

### Task 11: Wire Frozen CLI Commands and Compact JSON Results

**Files:**
- Modify: `src/videokb/cli.py`
- Create: `tests/test_cli_output.py`
- Create: `tools/videokb.ps1`

- [ ] **Step 1: Write output-boundary tests**

```python
import json
from videokb.cli import main


def test_sync_prints_one_compact_json_object(monkeypatch, capsys):
    monkeypatch.setattr("videokb.cli.run_sync", lambda _args: {"processed": 2, "failed": 0})
    assert main(["sync", "https://www.douyin.com/user/x"]) == 0
    output = capsys.readouterr().out.strip()
    assert json.loads(output) == {"processed": 2, "failed": 0}
    assert len(output.splitlines()) == 1
```

- [ ] **Step 2: Verify test fails**

Run: `python -m pytest tests/test_cli_output.py -v`

Expected: FAIL because `main` does not accept argv or dispatch.

- [ ] **Step 3: Wire command handlers**

`sync`, `status`, `retry`, `export`, `ai`, and `platforms` each return JSON-serializable dictionaries. `ai` returns an explicit `not_configured` result until a Provider is configured; it never runs during `sync` when `--ai off` is in effect. The CLI prints exactly one final JSON line to stdout; detailed logs go to a workspace log file.

```powershell
# tools/videokb.ps1
$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
$Python = Join-Path $Root "video-transcript-capture\service\.venv\Scripts\python.exe"
if (-not (Test-Path $Python)) { $Python = "python" }
& $Python -m videokb @args
exit $LASTEXITCODE
```

- [ ] **Step 4: Run CLI tests**

Run: `python -m pytest tests/test_cli.py tests/test_cli_output.py -v`

Expected: all CLI tests PASS.

- [ ] **Step 5: Commit CLI wiring**

```powershell
git add src/videokb/cli.py tests/test_cli_output.py tools/videokb.ps1
git commit -m "feat: wire VideoKB commands"
```

### Task 12: Installer, Skill, Documentation, and Compatibility

**Files:**
- Create: `.agents/skills/videokb/SKILL.md`
- Modify: `tools/install-douyin-video-notes.ps1`
- Modify: `README.md`
- Modify: `.gitignore`
- Create: `tests/test_skill_contract.py`

- [ ] **Step 1: Write skill contract test**

```python
from pathlib import Path


def test_skill_uses_compact_cli_and_never_reads_transcript_body():
    text = Path(".agents/skills/videokb/SKILL.md").read_text(encoding="utf-8")
    assert "videokb sync" in text
    assert "最终 JSON 摘要" in text
    assert "不要读取完整文字稿" in text
```

- [ ] **Step 2: Verify test fails**

Run: `python -m pytest tests/test_skill_contract.py -v`

Expected: FAIL because the VideoKB skill is absent.

- [ ] **Step 3: Add the Skill and installation behavior**

The Skill routes natural language to one CLI invocation, reports the final JSON summary and output directory, pauses for visible login when requested, and explicitly avoids reading transcript bodies unless the user asks for analysis. The installer installs the editable Python package, Node dependencies and Faster-Whisper environment, then copies `.agents/skills/videokb` to `D:\CodexHome\skills\videokb`.

- [ ] **Step 4: Update documentation and ignore rules**

README must show installation, `videokb sync`, incremental behavior, safety pause, zero-Token default, `--keep-audio`, and output structure. Ignore `workspace/`, `*.db`, browser profiles, audio, temporary downloads and model caches. Keep legacy single-video commands documented as compatibility-only during the MVP transition.

- [ ] **Step 5: Run documentation contract test**

Run: `python -m pytest tests/test_skill_contract.py -v`

Expected: PASS.

- [ ] **Step 6: Commit installation and Skill**

```powershell
git add .agents/skills/videokb tools/install-douyin-video-notes.ps1 README.md .gitignore tests/test_skill_contract.py
git commit -m "docs: add VideoKB installation and skill"
```

### Task 13: Full Verification and Real Douyin Canary

**Files:**
- Create: `tests/test_e2e_fixture.py`
- Create: `docs/verification/douyin-canary.md`

- [ ] **Step 1: Add fixture-only end-to-end test**

The test uses recorded Douyin pages, a fake downloader and fake timestamped transcriber, then asserts creation of `project.db`, four original formats, `chunks.jsonl`, `manifest.csv`, `manifest.json`, `complete-transcripts.md`, and empty `failures.json` without network or AI calls.

- [ ] **Step 2: Run the complete automated suite**

Run: `python -m pytest -v`

Expected: all tests PASS; no real platform requests occur.

- [ ] **Step 3: Run formatting and syntax checks**

Run: `python -m compileall src tests && node --check src/videokb/adapters/douyin_bridge.mjs && git diff --check`

Expected: all commands exit 0.

- [ ] **Step 4: Run one authorized live canary**

Run:

```powershell
powershell -ExecutionPolicy Bypass -File tools/videokb.ps1 sync "https://www.douyin.com/user/MS4wLjABAAAArYIb9WtHse-NtHgxkBhWanrG99dV92_VMizrUb7H2zE?from_tab_name=main"
```

Expected: visible official login only if required; compact final JSON; all accessible works enumerated; no cookies printed or persisted outside the isolated browser profile; successful audio removed; second identical run reports every unchanged item as skipped.

- [ ] **Step 5: Record measured evidence**

Write `docs/verification/douyin-canary.md` with date, anonymized creator ID, discovered/processed/skipped/failed/blocked counts, wall time, second-run wall time, and output file inventory. Do not include cookies, signed URLs or transcript bodies.

- [ ] **Step 6: Commit verification**

```powershell
git add tests/test_e2e_fixture.py docs/verification/douyin-canary.md
git commit -m "test: verify VideoKB Douyin MVP"
```

## Deferred Beyond This Plan

- Functional Bilibili, Xiaohongshu, WeChat Channels, YouTube, Kuaishou and TikTok adapters.
- Local or cloud AI Provider implementations.
- GUI, cloud service and built-in RAG/chat interface.
- Proxy pools, account rotation, CAPTCHA solving or any anti-bot bypass.

These are excluded from the MVP while their extension points remain frozen by the foundation design.
