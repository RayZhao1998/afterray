#!/usr/bin/env python3
"""Download a Hugging Face snapshot using AfterRay's own Python runtime.

This file is invoked by download.sh after that script has installed a
standalone CPython under .afterray/python. It must not be run with the
user's uv/Homebrew interpreter.
"""
from pathlib import Path
import sys

from huggingface_hub import snapshot_download


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: download_huggingface_model.py REPOSITORY DESTINATION", file=sys.stderr)
        return 64
    repository, destination = sys.argv[1:]
    target = Path(destination)
    target.mkdir(parents=True, exist_ok=True)
    snapshot_download(
        repo_id=repository,
        local_dir=target,
        local_dir_use_symlinks=False,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
