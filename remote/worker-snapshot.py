#!/usr/bin/env python3
"""Report OpenCode worker state, either as a snapshot or as a live stream.

Two modes, one summarizer, so the dashboard and `ocw attach` never disagree
about what a worker is doing.

  worker-snapshot.py             JSON array of every worker in the state root
  worker-snapshot.py --stream    read OpenCode JSONL on stdin, print one
                                 concise line per event

The launcher writes raw OpenCode JSONL for forensic inspection. This reader
extracts only operational metadata and short progress summaries, so routine
monitoring does not flood an orchestrator's context window with tool payloads.
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
from pathlib import Path
from typing import Any, Iterable

STATE_ROOT = Path(
    os.environ.get("OCW_STATE_ROOT", Path.home() / ".local/state/ocw-workers")
)
MAX_LOG_BYTES = 512 * 1024
MAX_SUMMARY_CHARS = 180

# Redact anything shaped like a credential before it reaches a console or a
# dashboard, because worker text is model-generated and may echo secrets.
SECRET_PATTERN = re.compile(
    r"(?i)\b(token|secret|password|authorization|api[_-]?key)\b"
    r"(\s*[:=]\s*)([^\s,;]+)"
)


def read_text(path: Path, default: str = "") -> str:
    """Read a small metadata file without failing the whole snapshot."""
    try:
        return path.read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        return default


def process_exists(pid_text: str) -> bool:
    """Return whether a worker PID still exists without signalling it."""
    try:
        os.kill(int(pid_text), 0)
        return True
    except (OSError, TypeError, ValueError):
        return False


def clean_summary(value: Any) -> str:
    """Normalize, redact, and bound worker-provided text."""
    text = re.sub(r"\s+", " ", str(value or "")).strip()
    text = SECRET_PATTERN.sub(r"\1\2[redacted]", text)
    if len(text) > MAX_SUMMARY_CHARS:
        return text[: MAX_SUMMARY_CHARS - 1] + "..."
    return text


def summarize_event(event: dict[str, Any]) -> str:
    """Summarize one event without echoing command arguments or file contents."""
    event_type = str(event.get("type", "event"))
    part = event.get("part") if isinstance(event.get("part"), dict) else {}
    if event_type == "text":
        return clean_summary(part.get("text", "response"))
    if event_type == "tool_use":
        tool = clean_summary(part.get("tool", "tool"))
        state = part.get("state") if isinstance(part.get("state"), dict) else {}
        status = clean_summary(state.get("status", "active"))
        return f"{tool} {status}"
    if event_type == "step_finish":
        return f"step {clean_summary(part.get('reason', 'finished'))}"
    if event_type == "step_start":
        return "reasoning"
    return clean_summary(event_type)


def parse_events(data: bytes) -> Iterable[dict[str, Any]]:
    """Yield the JSON objects in a JSONL byte buffer, skipping malformed lines."""
    for line in data.splitlines():
        try:
            event = json.loads(line)
        except (json.JSONDecodeError, UnicodeDecodeError):
            continue
        if isinstance(event, dict):
            yield event


def recent_events(path: Path) -> list[dict[str, Any]]:
    """Parse only the bounded tail of an OpenCode JSONL log."""
    try:
        with path.open("rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            handle.seek(max(0, size - MAX_LOG_BYTES))
            data = handle.read()
    except OSError:
        return []

    if size > MAX_LOG_BYTES:
        # Drop the first, likely partial, line left by the seek.
        _, _, data = data.partition(b"\n")

    return list(parse_events(data))


def worker_snapshot(worker_dir: Path) -> dict[str, Any]:
    """Build one stable monitoring record from worker state and its log tail."""
    pid = read_text(worker_dir / "pid")
    exit_code = read_text(worker_dir / "exit")
    if process_exists(pid):
        state = "RUNNING"
    elif exit_code == "0":
        state = "DONE"
    elif exit_code:
        state = "FAILED"
    else:
        state = "STOPPED"

    try:
        started = int(read_text(worker_dir / "started", "0"))
    except ValueError:
        started = 0

    events = recent_events(worker_dir / "output.log")
    last_event = events[-1] if events else {}
    last_text = next(
        (
            clean_summary(event.get("part", {}).get("text", ""))
            for event in reversed(events)
            if event.get("type") == "text"
            and isinstance(event.get("part"), dict)
            and event["part"].get("text")
        ),
        "",
    )

    timestamp_ms = last_event.get("timestamp")
    try:
        activity_age = max(0, int(time.time() - int(timestamp_ms) / 1000))
    except (TypeError, ValueError):
        activity_age = None

    return {
        "name": worker_dir.name,
        "state": state,
        "elapsedSeconds": max(0, int(time.time()) - started) if started else None,
        "activityAgeSeconds": activity_age,
        "model": read_text(worker_dir / "model"),
        "variant": read_text(worker_dir / "variant"),
        "branch": read_text(worker_dir / "workdir"),
        "title": read_text(worker_dir / "title"),
        "exitCode": int(exit_code) if exit_code.lstrip("-").isdigit() else None,
        "activity": summarize_event(last_event) if last_event else "no events",
        "message": last_text,
    }


def stream() -> int:
    """Render OpenCode JSONL from stdin as one concise line per event."""
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            # A partially written final line is normal while following a live
            # log; skip it rather than emitting a parse error.
            continue
        if not isinstance(event, dict):
            continue
        print(summarize_event(event), flush=True)
    return 0


def snapshot() -> int:
    """Print one JSON array for reliable transport over Codespaces SSH."""
    if not STATE_ROOT.exists():
        print("[]")
        return 0
    snapshots = [
        worker_snapshot(path) for path in sorted(STATE_ROOT.iterdir()) if path.is_dir()
    ]
    json.dump(snapshots, sys.stdout, separators=(",", ":"), ensure_ascii=False)
    print()
    return 0


def main(argv: list[str]) -> int:
    if "--stream" in argv[1:]:
        return stream()
    return snapshot()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
