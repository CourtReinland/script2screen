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
) -> dict:
    """
    Poll an async task until it completes, fails, or times out.

    Args:
        task_id: The task identifier to poll.
        check_fn: Callable that takes task_id and returns dict with at least 'status' key.
        timeout: Maximum seconds to wait.
        interval: Seconds between polls.
        progress_callback: Optional callback(task_id, status) for UI updates.

    Returns:
        The final response dict from check_fn.

    Raises:
        GenerationError: If the task reports failure.
        TimeoutError: If polling exceeds timeout.
    """
    start = time.time()
    last_status = ""

    while True:
        elapsed = time.time() - start
        if elapsed > timeout:
            raise TimeoutError(
                f"Task {task_id} timed out after {timeout}s (last status: {last_status})"
            )

        try:
            result = check_fn(task_id)
        except Exception as e:
            logger.warning(f"Poll error for {task_id}: {e}")
            time.sleep(interval)
            continue

        status = result.get("status", "UNKNOWN")
        last_status = status

        if progress_callback:
            progress_callback(task_id, status)

        if status in ("COMPLETED", "completed", "Done", "DONE"):
            logger.info(f"Task {task_id} completed in {elapsed:.1f}s")
            return result

        if status in ("FAILED", "failed", "Canceled", "ERROR"):
            error_msg = result.get("error", result.get("message", "Unknown error"))
            raise GenerationError(f"Task {task_id} failed: {error_msg}")

        logger.debug(f"Task {task_id}: {status} ({elapsed:.0f}s elapsed)")
        time.sleep(interval)


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
