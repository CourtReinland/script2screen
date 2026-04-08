"""Per-shot audio merger — concatenates multiple dialogue lines into one file.

When a shot has multiple dialogue lines (e.g. AIDEN speaks, then ALIYAH),
each line is generated as a separate audio file.  This module merges them
in script order (using the _L{N}_ line-index in the filename) with an
optional silence gap between lines, producing a single audio file per shot
suitable for lip-sync.

Requires ffmpeg on the system (used via subprocess).
"""

import logging
import os
import re
import shutil
import subprocess
import tempfile
from typing import Optional

logger = logging.getLogger("ScriptToScreen")

# Common ffmpeg locations on macOS
_FFMPEG_SEARCH_PATHS = [
    "/opt/homebrew/bin/ffmpeg",
    "/usr/local/bin/ffmpeg",
    "/usr/bin/ffmpeg",
]


def _find_ffmpeg() -> Optional[str]:
    """Locate the ffmpeg binary."""
    # Check PATH first
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg:
        return ffmpeg
    # Check common macOS locations
    for path in _FFMPEG_SEARCH_PATHS:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None


def _generate_silence(ffmpeg: str, duration_ms: int, output_path: str,
                      sample_rate: int = 44100) -> bool:
    """Generate a silent audio file of the given duration."""
    duration_s = duration_ms / 1000.0
    cmd = [
        ffmpeg, "-y",
        "-f", "lavfi",
        "-i", f"anullsrc=r={sample_rate}:cl=mono",
        "-t", str(duration_s),
        "-c:a", "libmp3lame",
        "-q:a", "5",
        output_path,
    ]
    result = subprocess.run(cmd, capture_output=True, timeout=15)
    return result.returncode == 0


def merge_shot_audio(
    audio_dir: str,
    output_dir: Optional[str] = None,
    silence_gap_ms: int = 300,
) -> dict[str, str]:
    """Merge per-line audio files into one file per shot.

    Scans *audio_dir* for files matching the pattern
    ``s{N}_sh{N}_L{N}_*.{mp3,wav,m4a}`` (the ``_L{N}_`` line-index is used
    for ordering).  Also handles legacy files without line-index
    (``s{N}_sh{N}_*.{mp3,wav}``).

    For shots with a single audio file the file is copied as-is.
    For shots with multiple files they are concatenated in line-index order
    with *silence_gap_ms* milliseconds of silence between them.

    Args:
        audio_dir: Directory containing per-line dialogue audio files.
        output_dir: Where to write merged files.  Defaults to a ``merged/``
                    subdirectory next to *audio_dir*.
        silence_gap_ms: Silence gap (ms) between dialogue lines.  0 = none.

    Returns:
        Dict mapping shot_key (``"s0_sh2"``) → merged audio file path.
    """
    if output_dir is None:
        output_dir = os.path.join(os.path.dirname(audio_dir), "merged")
    os.makedirs(output_dir, exist_ok=True)

    ffmpeg = _find_ffmpeg()
    if not ffmpeg:
        logger.error("ffmpeg not found — cannot merge audio files")
        return {}

    # -- Collect audio files grouped by shot key --------------------------
    # Pattern: s0_sh2_L0_abc123.mp3  or legacy  s0_sh2_abc123.mp3
    LINE_RE = re.compile(
        r"^(s\d+_sh\d+)_L(\d+)_[0-9a-f]+\.(mp3|wav|m4a)$", re.IGNORECASE
    )
    LEGACY_RE = re.compile(
        r"^(s\d+_sh\d+)_[0-9a-f]+\.(mp3|wav|m4a)$", re.IGNORECASE
    )

    # shot_key -> [(sort_key, file_path)]
    # sort_key is line_index for _L{N}_ files, or mtime for legacy files
    shots: dict[str, list[tuple[float, str]]] = {}
    has_line_index: dict[str, bool] = {}  # track whether shot uses _L{N}_

    for fname in sorted(os.listdir(audio_dir)):
        fpath = os.path.join(audio_dir, fname)
        if not os.path.isfile(fpath):
            continue

        m = LINE_RE.match(fname)
        if m:
            shot_key = m.group(1)
            line_idx = int(m.group(2))
            shots.setdefault(shot_key, []).append((float(line_idx), fpath))
            has_line_index[shot_key] = True
            continue

        # Fall back to legacy naming (no line index)
        m = LEGACY_RE.match(fname)
        if m:
            shot_key = m.group(1)
            # Use file modification time to preserve generation order
            mtime = os.path.getmtime(fpath)
            shots.setdefault(shot_key, []).append((mtime, fpath))
            has_line_index.setdefault(shot_key, False)

    if not shots:
        logger.info("No dialogue audio files found to merge")
        return {}

    results: dict[str, str] = {}

    for shot_key in sorted(shots):
        files = shots[shot_key]
        # Sort by line index, then by filename for stability
        files.sort(key=lambda t: (t[0], os.path.basename(t[1])))
        paths = [p for _, p in files]

        if len(paths) == 1:
            # Single file — copy to output dir
            ext = os.path.splitext(paths[0])[1]
            dest = os.path.join(output_dir, f"{shot_key}_combined{ext}")
            shutil.copy2(paths[0], dest)
            results[shot_key] = dest
            logger.info(f"[merge] {shot_key}: single file → {os.path.basename(dest)}")
            continue

        # Multiple files — concatenate with ffmpeg
        logger.info(
            f"[merge] {shot_key}: merging {len(paths)} audio files "
            f"(gap={silence_gap_ms}ms)"
        )

        ext = os.path.splitext(paths[0])[1]  # use first file's extension
        dest = os.path.join(output_dir, f"{shot_key}_combined{ext}")

        try:
            _concat_with_ffmpeg(ffmpeg, paths, dest, silence_gap_ms)
            results[shot_key] = dest
            logger.info(f"[merge] {shot_key}: merged → {os.path.basename(dest)}")
        except Exception as e:
            logger.error(f"[merge] {shot_key}: merge failed: {e}")
            # Fallback: use the first file
            shutil.copy2(paths[0], dest)
            results[shot_key] = dest

    return results


def _concat_with_ffmpeg(
    ffmpeg: str,
    input_paths: list[str],
    output_path: str,
    silence_gap_ms: int,
) -> None:
    """Concatenate audio files using ffmpeg, with optional silence gaps.

    Strategy: re-encode all inputs to a common format (mp3, 44100 Hz, mono)
    then concatenate.  This handles mixed formats and sample rates.
    """
    tmpdir = tempfile.mkdtemp(prefix="sts_merge_")
    try:
        normalized: list[str] = []

        # Normalize each input to consistent format
        for i, path in enumerate(input_paths):
            norm_path = os.path.join(tmpdir, f"part_{i:03d}.mp3")
            cmd = [
                ffmpeg, "-y", "-i", path,
                "-ar", "44100", "-ac", "1",
                "-c:a", "libmp3lame", "-q:a", "2",
                norm_path,
            ]
            r = subprocess.run(cmd, capture_output=True, timeout=30)
            if r.returncode != 0:
                raise RuntimeError(
                    f"ffmpeg normalize failed for {os.path.basename(path)}: "
                    f"{r.stderr.decode('utf-8', errors='replace')[:200]}"
                )
            normalized.append(norm_path)

        # Generate silence segment if needed
        silence_path = None
        if silence_gap_ms > 0:
            silence_path = os.path.join(tmpdir, "silence.mp3")
            if not _generate_silence(ffmpeg, silence_gap_ms, silence_path):
                logger.warning("Could not generate silence; concatenating without gaps")
                silence_path = None

        # Build concat list interleaving silence
        concat_list = os.path.join(tmpdir, "concat.txt")
        with open(concat_list, "w") as f:
            for i, npath in enumerate(normalized):
                f.write(f"file '{npath}'\n")
                if silence_path and i < len(normalized) - 1:
                    f.write(f"file '{silence_path}'\n")

        # Run concat
        cmd = [
            ffmpeg, "-y",
            "-f", "concat", "-safe", "0",
            "-i", concat_list,
            "-c", "copy",
            output_path,
        ]
        r = subprocess.run(cmd, capture_output=True, timeout=60)
        if r.returncode != 0:
            raise RuntimeError(
                f"ffmpeg concat failed: "
                f"{r.stderr.decode('utf-8', errors='replace')[:300]}"
            )
    finally:
        # Clean up temp dir
        shutil.rmtree(tmpdir, ignore_errors=True)
