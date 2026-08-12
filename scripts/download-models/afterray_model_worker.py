#!/usr/bin/env python3
"""Reference AfterRay V0 model worker.

Reads one WorkerRequest JSON object from stdin and writes one WorkerResponse to
stdout. OCR, embeddings, and LLM generation use the local Ollama API. ASR uses
ffmpeg to normalize audio and whisper.cpp to transcribe it.
"""

from __future__ import annotations

import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

PROTOCOL_VERSION = 1


class WorkerError(Exception):
    def __init__(self, message: str, *, retryable: bool = False) -> None:
        super().__init__(message)
        self.retryable = retryable


def env(name: str, default: str) -> str:
    return os.environ.get(name, default)


def ollama_request(endpoint: str, payload: dict) -> dict:
    base_url = env("AFTERRAY_OLLAMA_URL", "http://127.0.0.1:11434").rstrip("/")
    request = urllib.request.Request(
        f"{base_url}{endpoint}",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=300) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        missing = error.code == 404 or "not found" in body.lower()
        hint = " Run scripts/download-models/download.sh first." if missing else ""
        raise WorkerError(
            f"Ollama returned HTTP {error.code}: {body}.{hint}",
            retryable=not missing,
        ) from error
    except urllib.error.URLError as error:
        raise WorkerError(
            "cannot reach Ollama at "
            f"{base_url}; start `ollama serve` or set AFTERRAY_OLLAMA_URL: {error}",
            retryable=True,
        ) from error


def run_ocr(model_input: dict) -> dict:
    image_path = Path(model_input["image_path"])
    if not image_path.is_file():
        raise WorkerError(f"OCR image does not exist: {image_path}")
    prompt = model_input.get("prompt") or (
        "Transcribe every visible word in this screenshot. Preserve reading "
        "order and line breaks. Return only the transcription."
    )
    result = ollama_request(
        "/api/generate",
        {
            "model": env("AFTERRAY_OCR_MODEL", "qwen2.5vl:3b"),
            "prompt": prompt,
            "images": [base64.b64encode(image_path.read_bytes()).decode("ascii")],
            "stream": False,
        },
    )
    text = result.get("response")
    if not isinstance(text, str):
        raise WorkerError("Ollama OCR response did not contain `response`", retryable=True)
    return {"type": "ocr", "text": text.strip()}


def run_embedding(model_input: dict) -> dict:
    result = ollama_request(
        "/api/embed",
        {
            "model": env("AFTERRAY_EMBEDDING_MODEL", "nomic-embed-text"),
            "input": model_input["text"],
        },
    )
    embeddings = result.get("embeddings")
    if not isinstance(embeddings, list) or not embeddings or not isinstance(embeddings[0], list):
        raise WorkerError("Ollama embedding response was missing `embeddings[0]`", retryable=True)
    return {"type": "embedding", "vector": embeddings[0]}


def run_llm(model_input: dict) -> dict:
    prompt = model_input["prompt"]
    if system := model_input.get("system"):
        prompt = f"System:\n{system}\n\nUser:\n{prompt}"
    result = ollama_request(
        "/api/generate",
        {
            "model": env("AFTERRAY_LLM_MODEL", "gemma4:latest"),
            "prompt": prompt,
            "stream": False,
        },
    )
    text = result.get("response")
    if not isinstance(text, str):
        raise WorkerError("Ollama LLM response did not contain `response`", retryable=True)
    return {"type": "llm", "text": text.strip()}


def require_executable(config_name: str, fallback: str) -> str:
    configured = env(config_name, fallback)
    resolved = shutil.which(configured)
    if resolved is None:
        raise WorkerError(
            f"executable `{configured}` was not found; install it or set {config_name}"
        )
    return resolved


def extract_whisper_text(document: dict) -> str:
    transcription = document.get("transcription")
    if isinstance(transcription, list):
        parts = [part.get("text", "") for part in transcription if isinstance(part, dict)]
        return " ".join(part.strip() for part in parts if part.strip())
    if isinstance(transcription, str):
        return transcription.strip()
    text = document.get("text")
    if isinstance(text, str):
        return text.strip()
    raise WorkerError("whisper.cpp JSON did not contain transcription text")


def run_asr(model_input: dict) -> dict:
    audio_path = Path(model_input["audio_path"])
    if not audio_path.is_file():
        raise WorkerError(f"ASR audio does not exist: {audio_path}")
    ffmpeg = require_executable("AFTERRAY_FFMPEG_BIN", "ffmpeg")
    whisper = require_executable("AFTERRAY_WHISPER_BIN", "whisper-cli")
    model = Path(env("AFTERRAY_WHISPER_MODEL", ""))
    if not model.is_file():
        raise WorkerError(
            "whisper.cpp model is missing; set AFTERRAY_WHISPER_MODEL or run "
            "scripts/download-models/download.sh"
        )

    with tempfile.TemporaryDirectory(prefix="afterray-asr-") as temporary:
        temporary_path = Path(temporary)
        wav_path = temporary_path / "normalized.wav"
        output_prefix = temporary_path / "transcript"
        subprocess.run(
            [
                ffmpeg,
                "-nostdin",
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-i",
                str(audio_path),
                "-ar",
                "16000",
                "-ac",
                "1",
                "-c:a",
                "pcm_s16le",
                str(wav_path),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        command = [
            whisper,
            "-m",
            str(model),
            "-f",
            str(wav_path),
            "-oj",
            "-of",
            str(output_prefix),
        ]
        if language := model_input.get("language"):
            command.extend(["-l", language])
        completed = subprocess.run(command, check=False, capture_output=True, text=True)
        if completed.returncode != 0:
            raise WorkerError(
                f"whisper.cpp exited {completed.returncode}: {completed.stderr[-2000:]}",
                retryable=True,
            )
        output_path = Path(f"{output_prefix}.json")
        if not output_path.is_file():
            raise WorkerError("whisper.cpp did not create its JSON output", retryable=True)
        document = json.loads(output_path.read_text(encoding="utf-8"))
        detected_language = document.get("result", {}).get("language")
        return {
            "type": "asr",
            "text": extract_whisper_text(document),
            "language": detected_language or model_input.get("language"),
        }


def execute(request: dict) -> dict:
    if request.get("protocol_version") != PROTOCOL_VERSION:
        raise WorkerError(
            f"unsupported worker protocol version: {request.get('protocol_version')}"
        )
    capability = request.get("capability")
    model_input = request.get("input")
    if not isinstance(model_input, dict) or model_input.get("type") != capability:
        raise WorkerError("request capability does not match input type")
    handlers = {
        "ocr": run_ocr,
        "asr": run_asr,
        "embedding": run_embedding,
        "llm": run_llm,
    }
    handler = handlers.get(capability)
    if handler is None:
        raise WorkerError(f"unsupported capability: {capability}")
    return handler(model_input)


def main() -> int:
    try:
        request = json.load(sys.stdin)
        response = {
            "protocol_version": PROTOCOL_VERSION,
            "output": execute(request),
            "retryable": False,
        }
    except WorkerError as error:
        response = {
            "protocol_version": PROTOCOL_VERSION,
            "error": str(error),
            "retryable": error.retryable,
        }
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        response = {
            "protocol_version": PROTOCOL_VERSION,
            "error": f"invalid worker request or response: {error}",
            "retryable": False,
        }
    except subprocess.CalledProcessError as error:
        response = {
            "protocol_version": PROTOCOL_VERSION,
            "error": f"audio preprocessing failed: {error.stderr[-2000:]}",
            "retryable": True,
        }
    print(json.dumps(response, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
