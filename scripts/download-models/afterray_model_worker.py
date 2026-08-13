#!/usr/bin/env python3
"""AfterRay-managed local model worker.

Reads one WorkerRequest JSON object from stdin and writes one WorkerResponse to
stdout. OCR is handled by the native Swift worker. This process runs ASR with
mlx-audio (Qwen3-ASR by default, whisper.cpp fallback), embeddings with
llama.cpp, and Gemma 4 with MLX directly. It never contacts an Ollama service.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
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


QWEN_LANGUAGE_NAMES = {
    "zh": "Chinese",
    "zh-cn": "Chinese",
    "zh-hans": "Chinese",
    "cmn": "Chinese",
    "yue": "Cantonese",
    "zh-hk": "Cantonese",
    "zh-yue": "Cantonese",
    "en": "English",
    "ja": "Japanese",
    "jp": "Japanese",
    "ko": "Korean",
    "de": "German",
    "es": "Spanish",
    "fr": "French",
    "it": "Italian",
    "pt": "Portuguese",
    "ru": "Russian",
}


def requested_language(model_input: dict) -> str | None:
    language = model_input.get("language")
    if isinstance(language, str) and language.strip():
        return language.strip()
    return None


def qwen3_language(language: str | None) -> str | None:
    if language is None:
        return None
    return QWEN_LANGUAGE_NAMES.get(language.lower(), language)


def asr_backend() -> str:
    configured = env("AFTERRAY_ASR_BACKEND", "qwen3").strip().lower()
    if configured in {"whisper", "whisper.cpp", "whisper-cpp"}:
        return "whisper"
    return "qwen3"


def qwen3_model_path() -> Path:
    return Path(env("AFTERRAY_ASR_MODEL", ".afterray/models/Qwen3-ASR-1.7B-8bit")).expanduser()


def whisper_model_path() -> Path:
    return Path(env("AFTERRAY_WHISPER_MODEL", "")).expanduser()


def qwen3_model_available(path: Path) -> bool:
    return path.is_dir() and (path / "config.json").is_file()


def extract_whisper_text(document: dict) -> str:
    transcription = document.get("transcription")
    if isinstance(transcription, list):
        parts = [part.get("text", "") for part in transcription if isinstance(part, dict)]
        return sanitize_asr_text(" ".join(part.strip() for part in parts if part.strip()))
    if isinstance(transcription, str):
        return sanitize_asr_text(transcription)
    text = document.get("text")
    if isinstance(text, str):
        return sanitize_asr_text(text)
    raise WorkerError("whisper.cpp JSON did not contain transcription text")


def extract_stt_text(result: object) -> str:
    if isinstance(result, str):
        return sanitize_asr_text(result)
    text = getattr(result, "text", None)
    if isinstance(text, str):
        return sanitize_asr_text(text)
    if isinstance(result, dict) and isinstance(result.get("text"), str):
        return sanitize_asr_text(result["text"])
    segments = getattr(result, "segments", None)
    if segments is None and isinstance(result, dict):
        segments = result.get("segments")
    if isinstance(segments, list):
        parts: list[str] = []
        for segment in segments:
            if isinstance(segment, dict):
                part = segment.get("text", "")
            else:
                part = getattr(segment, "text", "")
            if isinstance(part, str) and part.strip():
                parts.append(part.strip())
        if parts:
            return sanitize_asr_text(" ".join(parts))
    raise WorkerError("ASR model returned no transcription text")


def extract_stt_language(result: object, fallback: str | None) -> str | None:
    language = getattr(result, "language", None)
    if isinstance(language, str) and language.strip():
        return language
    if isinstance(result, dict) and isinstance(result.get("language"), str):
        return result["language"]
    return fallback


def sanitize_asr_text(text: str) -> str:
    cleaned = text.strip()
    words = re.findall(r"[a-z']+", cleaned.lower())
    if len(words) < 4:
        return cleaned
    filler = {"thank", "thanks", "you", "thankyou"}
    if sum(1 for word in words if word in filler) / len(words) >= 0.7:
        return ""
    return cleaned


def normalize_audio(audio_path: Path, directory: Path) -> Path:
    ffmpeg = require_executable("AFTERRAY_FFMPEG_BIN", "ffmpeg")
    wav_path = directory / "normalized.wav"
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
    return wav_path


def run_asr(model_input: dict) -> dict:
    audio_path = Path(model_input["audio_path"])
    if not audio_path.is_file():
        raise WorkerError(f"ASR audio does not exist: {audio_path}")
    language = requested_language(model_input)
    backend = asr_backend()
    qwen_path = qwen3_model_path()
    whisper_path = whisper_model_path()

    if backend == "qwen3":
        if qwen3_model_available(qwen_path):
            return run_qwen3_asr(audio_path, language, qwen_path)
        if whisper_path.is_file():
            print(
                "Qwen3-ASR is missing; falling back to whisper.cpp",
                file=sys.stderr,
            )
            return run_whisper_asr(audio_path, language, whisper_path)
        raise WorkerError(
            "Qwen3-ASR model is missing; set AFTERRAY_ASR_MODEL or run "
            "scripts/download-models/download.sh"
        )

    if not whisper_path.is_file():
        raise WorkerError(
            "whisper.cpp model is missing; set AFTERRAY_WHISPER_MODEL or run "
            "scripts/download-models/download.sh"
        )
    return run_whisper_asr(audio_path, language, whisper_path)


def run_qwen3_asr(audio_path: Path, language: str | None, model_path: Path) -> dict:
    with tempfile.TemporaryDirectory(prefix="afterray-asr-") as temporary:
        wav_path = normalize_audio(audio_path, Path(temporary))
        qwen_language = qwen3_language(language)
        try:
            try:
                from mlx_audio.stt import load as load_stt
            except ImportError:
                load_stt = None
            if load_stt is not None:
                model = load_stt(str(model_path))
                kwargs = {}
                if qwen_language:
                    kwargs["language"] = qwen_language
                result = model.generate(str(wav_path), **kwargs)
            else:
                from mlx_audio.stt.generate import generate_transcription
                from mlx_audio.stt.utils import load_model

                model = load_model(str(model_path))
                kwargs = {"verbose": False}
                if qwen_language:
                    kwargs["language"] = qwen_language
                result = generate_transcription(
                    model=model,
                    audio=str(wav_path),
                    output_path=str(Path(temporary) / "transcript"),
                    format="txt",
                    **kwargs,
                )
        except ImportError as error:
            raise WorkerError(
                "AfterRay's MLX audio runtime is missing; run scripts/download-models/download.sh"
            ) from error
        except WorkerError:
            raise
        except Exception as error:
            raise WorkerError(f"Qwen3-ASR failed: {error}", retryable=True) from error
        return {
            "type": "asr",
            "text": extract_stt_text(result),
            "language": extract_stt_language(result, language),
        }


def run_whisper_asr(audio_path: Path, language: str | None, model: Path) -> dict:
    whisper = require_executable("AFTERRAY_WHISPER_BIN", "whisper-cli")
    with tempfile.TemporaryDirectory(prefix="afterray-asr-") as temporary:
        temporary_path = Path(temporary)
        wav_path = normalize_audio(audio_path, temporary_path)
        output_prefix = temporary_path / "transcript"
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
        if language:
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
            "language": detected_language or language,
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
