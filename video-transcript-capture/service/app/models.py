from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from pathlib import Path
from typing import Any


class JobStatus(str, Enum):
    QUEUED = "queued"
    PROCESSING = "processing"
    DONE = "done"
    FAILED = "failed"


@dataclass(frozen=True)
class CaptureRequest:
    url: str
    page_title: str | None = None
    platform: str | None = None
    browser: str | None = None
    cookies: list[dict[str, Any]] | None = None


@dataclass
class CaptureJob:
    id: str
    request: CaptureRequest
    status: JobStatus = JobStatus.QUEUED
    created_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))
    updated_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))
    message: str = "Queued"
    note_path: Path | None = None
    error: str | None = None


@dataclass(frozen=True)
class ExtractedMedia:
    title: str
    source_url: str
    platform: str
    author: str | None
    duration_seconds: int | None
    transcript_text: str | None
    audio_path: Path | None


@dataclass(frozen=True)
class Transcript:
    text: str
    source: str


@dataclass(frozen=True)
class Summary:
    summary: str
    key_points: list[str]


@dataclass(frozen=True)
class SavedNote:
    title: str
    source_url: str
    platform: str
    author: str | None
    captured_at: datetime
    duration_seconds: int | None
    transcript: Transcript
    summary: Summary | None
    markdown_path: Path
