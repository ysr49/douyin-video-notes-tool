from __future__ import annotations

import os
from pathlib import Path

from app.models import Transcript


class FasterWhisperTranscriber:
    def __init__(self, model_size: str | None = None) -> None:
        self.model_size = model_size or os.getenv("WHISPER_MODEL", "base")
        self.device = os.getenv("WHISPER_DEVICE", "cpu")
        self.compute_type = os.getenv("WHISPER_COMPUTE_TYPE", "int8")
        self._model = None

    def transcribe(self, audio_path: Path) -> Transcript:
        model = self._get_model()
        segments, _info = model.transcribe(str(audio_path))
        text = " ".join(segment.text.strip() for segment in segments if segment.text.strip())
        return Transcript(text=text, source="whisper")

    def _get_model(self):
        if self._model is not None:
            return self._model

        try:
            from faster_whisper import WhisperModel
        except ImportError as exc:
            raise RuntimeError(
                "faster-whisper is required to transcribe audio when subtitles are missing. "
                "Install it in the service environment before capturing videos without subtitles."
            ) from exc

        self._model = WhisperModel(
            self.model_size,
            device=self.device,
            compute_type=self.compute_type,
        )
        return self._model
