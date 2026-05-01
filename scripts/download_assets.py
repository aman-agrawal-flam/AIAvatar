#!/usr/bin/env python3
"""Prefetch Wav2Lip checkpoint and avatar archives from config.yml (Hugging Face).

Used by setup_aiavt.sh on GPU hosts where ./models/ is not rsync'd.
Safe to re-run: skips paths that already exist.

Usage:
  python scripts/download_assets.py              # models + all avatars in config
  python scripts/download_assets.py --models-only
"""
from __future__ import annotations

import argparse
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _rel(p: str) -> str:
    return os.path.normpath(os.path.join(ROOT, p.lstrip("./")))


def main() -> None:
    os.chdir(ROOT)
    sys.path.insert(0, ROOT)

    parser = argparse.ArgumentParser(description="Download wav2lip.pth and avatar zips per config.yml")
    parser.add_argument("--models-only", action="store_true", help="Only fetch MODELS (wav2lip.pth), not avatar zips")
    args = parser.parse_args()

    from src.config import get_avatar_download_config, get_model_download_config
    from src.get_file import http_get
    from src.log import logger

    data_dir = os.path.join(ROOT, "data")
    os.makedirs(data_dir, exist_ok=True)
    os.makedirs(os.path.join(ROOT, "models"), exist_ok=True)

    logger.info("=== Prefetch models / avatars (Hugging Face) ===")

    for model_name, cfg in get_model_download_config().items():
        path = _rel(cfg["path"])
        if os.path.exists(path):
            logger.info(f"✓ model {model_name} already at {path}")
            continue
        logger.info(f"Downloading {model_name} ({cfg.get('size', '?')}) …")
        http_get(cfg["url"], path, extract=False)
        logger.info(f"✓ {model_name} done")

    if args.models_only:
        logger.info("=== models-only: skipping avatars ===")
        logger.info("=== Prefetch finished ===")
        return

    for avatar_name, cfg in get_avatar_download_config().items():
        avatar_dir = os.path.join(data_dir, avatar_name)
        if os.path.isdir(avatar_dir):
            logger.info(f"✓ avatar {avatar_name} already present")
            continue
        zip_path = _rel(cfg["path"])
        logger.info(f"Downloading avatar {avatar_name} ({cfg.get('size', '?')}) …")
        http_get(cfg["url"], zip_path, extract=True)
        if os.path.exists(zip_path):
            os.remove(zip_path)
            logger.info(f"Removed temp zip {zip_path}")
        logger.info(f"✓ avatar {avatar_name} done")

    logger.info("=== Prefetch finished ===")


if __name__ == "__main__":
    main()
