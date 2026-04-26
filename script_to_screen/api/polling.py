"""Async polling utilities for long-running API tasks."""

import time
import logging
from typing import Callable, Optional

logger = logging.getLogger("ScriptToScreen")


class GenerationError(Exception):
    """Raised when an API generation task fails."""
    pass


class TimeoutError(Exception):
    """Raised when polling exceeds timeout."""
    pass


def poll_until_complete(
    task_id: str,
    check_fn: Callable[[str], dict],
    timeout: int = 600,
    interval: int = 5,
    progress_callback: Optional[Callable[[str, str], None]] = None,
    label: str = "",
    max_consecutive_errors: int = 5,
) -> dict:
    """
    Poll an async task until it completes, fails, or times out.

    Designed to be diagnostic-friendly: every poll iteration prints to
    stdout (visible live in the Resolve Console), consecutive failures
    abort instead of silently looping forever, and an unfamiliar response
    shape gets dumped on the first occurrence so we can see what fields
    are actually present.

    Args:
        task_id: The task identifier to poll.
        check_fn: Callable that takes task_id and returns dict with at
            least a "status" key.
        timeout: Maximum seconds to wait.
        interval: Seconds between polls.
        progress_callback: Optional callback(task_id, status) for UI updates.
        label: Optional human-friendly tag for log lines (e.g. shot_key).
        max_consecutive_errors: Abort with GenerationError after this many
            check_fn calls throw in a row. Prevents the poll loop from
            spinning silently when an endpoint is consistently 4xx-ing.

    Returns:
        The final response dict from check_fn.

    Raises:
        GenerationError: If the task reports failure or too many polls fail.
        TimeoutError: If polling exceeds timeout.
    """
    tag = f"[{label}] " if label else ""
    start = time.time()
    last_status = ""
    poll_n = 0
    consecutive_errors = 0
    unknown_dumped = False  # Only dump full response the first time

    print(f"{tag}poll start: task={task_id} timeout={timeout}s interval={interval}s", flush=True)

    while True:
        elapsed = time.time() - start
        if elapsed > timeout:
            raise TimeoutError(
                f"{tag}Task {task_id} timed out after {timeout}s (last status: {last_status})"
            )

        try:
            result = check_fn(task_id)
            consecutive_errors = 0
        except Exception as e:
            consecutive_errors += 1
            print(
                f"{tag}poll #{poll_n} ERROR ({consecutive_errors}/{max_consecutive_errors}): "
                f"{type(e).__name__}: {e}",
                flush=True,
            )
            logger.warning(f"{tag}Poll error for {task_id}: {e}")
            if consecutive_errors >= max_consecutive_errors:
                raise GenerationError(
                    f"{tag}Task {task_id} aborted after {consecutive_errors} consecutive "
                    f"polling errors. Last error: {type(e).__name__}: {e}"
                )
            time.sleep(interval)
            poll_n += 1
            continue

        status = result.get("status", "UNKNOWN")
        last_status = status

        if progress_callback:
            try:
                progress_callback(task_id, status)
            except Exception:
                pass

        print(
            f"{tag}poll #{poll_n}: status={status} elapsed={elapsed:.0f}s",
            flush=True,
        )

        if status in ("COMPLETED", "completed", "Done", "DONE", "FINISHED", "finished",
                      "SUCCESS", "success", "READY", "ready"):
            print(f"{tag}COMPLETED in {elapsed:.1f}s after {poll_n + 1} polls", flush=True)
            logger.info(f"Task {task_id} completed in {elapsed:.1f}s")
            return result

        if status in ("FAILED", "failed", "Canceled", "CANCELED", "ERROR", "error"):
            error_msg = result.get("error", result.get("message", "Unknown error"))
            print(f"{tag}FAILED after {elapsed:.1f}s: {error_msg}", flush=True)
            raise GenerationError(f"{tag}Task {task_id} failed: {error_msg}")

        # If status is UNKNOWN, the response shape probably doesn't match
        # what we expect. Dump it once so we can debug from logs.
        if status == "UNKNOWN" and not unknown_dumped:
            unknown_dumped = True
            print(
                f"{tag}WARNING: status field missing — keys={list(result.keys())} "
                f"sample={str(result)[:400]}",
                flush=True,
            )
            logger.warning(f"{tag}Response shape unexpected: {result}")

        time.sleep(interval)
        poll_n += 1


def poll_batch(
    tasks: list[tuple[str, Callable]],
    timeout: int = 600,
    interval: int = 5,
    progress_callback: Optional[Callable[[int, int], None]] = None,
) -> list[dict]:
    """
    Poll multiple tasks, returning results as they complete.

    Args:
        tasks: List of (task_id, check_fn) tuples.
        timeout: Max seconds to wait for all tasks.
        interval: Seconds between poll cycles.
        progress_callback: Optional callback(completed_count, total_count).

    Returns:
        List of result dicts in same order as input tasks.
    """
    start = time.time()
    results = [None] * len(tasks)
    completed = set()

    while len(completed) < len(tasks):
        elapsed = time.time() - start
        if elapsed > timeout:
            incomplete = [tid for i, (tid, _) in enumerate(tasks) if i not in completed]
            raise TimeoutError(
                f"Batch timed out after {timeout}s. Incomplete: {incomplete}"
            )

        for i, (task_id, check_fn) in enumerate(tasks):
            if i in completed:
                continue

            try:
                result = check_fn(task_id)
                status = result.get("status", "UNKNOWN")

                if status in ("COMPLETED", "completed", "Done", "DONE"):
                    results[i] = result
                    completed.add(i)
                    if progress_callback:
                        progress_callback(len(completed), len(tasks))

                elif status in ("FAILED", "failed", "Canceled", "ERROR"):
                    error_msg = result.get("error", "Unknown error")
                    results[i] = {"status": "FAILED", "error": error_msg, "task_id": task_id}
                    completed.add(i)
                    if progress_callback:
                        progress_callback(len(completed), len(tasks))

            except Exception as e:
                logger.warning(f"Poll error for task {task_id}: {e}")

        if len(completed) < len(tasks):
            time.sleep(interval)

    return results
