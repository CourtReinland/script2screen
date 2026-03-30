"""Shared utilities for ScriptToScreen."""

import base64
import logging
import os
import re
import time
from pathlib import Path
from typing import Optional

logger = logging.getLogger("ScriptToScreen")


def setup_logging(level: int = logging.INFO):
    handler = logging.StreamHandler()
    handler.setFormatter(logging.Formatter(
        "[%(asctime)s] %(name)s %(levelname)s: %(message)s",
        datefmt="%H:%M:%S",
    ))
    logger.addHandler(handler)
    logger.setLevel(level)


def image_to_base64(image_path: str) -> str:
    with open(image_path, "rb") as f:
        return base64.b64encode(f.read()).decode("utf-8")


def save_binary_file(data: bytes, path: str) -> str:
    with open(path, "wb") as f:
        f.write(data)
    return path


def sanitize_filename(name: str) -> str:
    return re.sub(r'[^\w\-.]', '_', name).strip('_')


def ensure_dir(path: str) -> str:
    os.makedirs(path, exist_ok=True)
    return path


def format_duration(seconds: float) -> str:
    mins = int(seconds // 60)
    secs = int(seconds % 60)
    if mins > 0:
        return f"{mins}m {secs}s"
    return f"{secs}s"


class RateLimiter:
    """Simple token-bucket rate limiter."""

    def __init__(self, calls_per_minute: int = 10):
        self.interval = 60.0 / calls_per_minute
        self.last_call = 0.0

    def wait(self):
        now = time.time()
        elapsed = now - self.last_call
        if elapsed < self.interval:
            time.sleep(self.interval - elapsed)
        self.last_call = time.time()


class ProgressTracker:
    """Track progress of multi-step operations."""

    def __init__(self, total: int, callback=None):
        self.total = total
        self.current = 0
        self.callback = callback
        self.errors: list[str] = []

    def advance(self, message: str = ""):
        self.current += 1
        if self.callback:
            self.callback(self.current, self.total, message)

    def error(self, message: str):
        self.errors.append(message)

    @property
    def percent(self) -> float:
        if self.total == 0:
            return 100.0
        return (self.current / self.total) * 100.0

    @property
    def is_complete(self) -> bool:
        return self.current >= self.total
