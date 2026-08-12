#!/usr/bin/env python3
"""AfterRay-managed local model worker.

Reads one WorkerRequest JSON object from stdin and writes one WorkerResponse to
stdout. OCR is handled by the native Swift worker. This process runs ASR with
whisper.cpp, embeddings with llama.cpp, and Gemma 4 with MLX directly. It never
contacts an Ollama service.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

PROTOCOL_VERSION = 1


class WorkerError(Exception):
    def __init__(self, message: str, *, retryable: bool = False) -> None:
        super().__init__(message)
        self.retryable = retryable


def env(name: str, default: str) -> str:
    return os.environ.get(name, default)


def run_ocr(model_input: dict) -> dict:
    raise WorkerError(
        "OCR must be routed to afterray-native-model-worker; check "
        "AFTERRAY_NATIVE_MODEL_WORKER"
    )


def run_embedding(model_input: dict) -> dict:
    executable = require_executable("AFTERRAY_EMBEDDING_BIN", "llama-embedding")
    model = required_model(
        "AFTERRAY_EMBEDDING_MODEL",
        ".afterray/models/nomic-embed-text-v1.5.Q4_K_M.gguf",
    )
    completed = subprocess.run(
        [
            executable,
            "-m",
            str(model),
            "-p",
            model_input["text"],
            "--embd-output-format",
            "json",
            "-ngl",
            "99",
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise WorkerError(
            f"llama-embedding exited {completed.returncode}: {completed.stderr[-2000:]}",
            retryable=True,
        )
    try:
        document = json.loads(completed.stdout)
        vector = document["data"][0]["embedding"]
    except (json.JSONDecodeError, KeyError, IndexError, TypeError) as error:
        raise WorkerError(f"llama-embedding returned invalid JSON: {error}", retryable=True) from error
    return {"type": "embedding", "vector": vector}


def run_llm(model_input: dict) -> dict:
    prompt = model_input["prompt"]
    if system := model_input.get("system"):
        prompt = f"System:\n{system}\n\nUser:\n{prompt}"
    model_path = required_model(
        "AFTERRAY_LLM_MODEL",
        ".afterray/models/gemma-4-26b-a4b-it-4bit",
    )
    try:
        from mlx_vlm import generate, load
        from mlx_vlm.prompt_utils import apply_chat_template
        from mlx_vlm.utils import load_config
    except ImportError as error:
        raise WorkerError(
            "AfterRay's MLX runtime is missing; run scripts/download-models/download.sh"
        ) from error

    model, processor = load(str(model_path))
    config = load_config(str(model_path))
    formatted = apply_chat_template(processor, config, prompt, num_images=0)
    result = generate(
        model,
        processor,
        formatted,
        [],
        max_tokens=int(env("AFTERRAY_LLM_MAX_TOKENS", "512")),
        temperature=0.0,
        verbose=False,
    )
    text = result if isinstance(result, str) else getattr(result, "text", None)
    if not isinstance(text, str):
        raise WorkerError("MLX returned no generated text", retryable=True)
    return {"type": "llm", "text": text.strip()}


def require_executable(config_name: str, fallback: str) -> str:
    configured = env(config_name, fallback)
    resolved = shutil.which(configured)
    if resolved is None:
        raise WorkerError(
            f"executable `{configured}` was not found; install it or set {config_name}"
        )
    return resolved


def required_model(config_name: str, fallback: str) -> Path:
    model = Path(env(config_name, fallback)).expanduser()
    if not model.exists():
        raise WorkerError(
            f"model asset `{model}` is missing; run scripts/download-models/download.sh"
        )
    return model


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
