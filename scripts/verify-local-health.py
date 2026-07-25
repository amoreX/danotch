#!/usr/bin/env python3
"""Verify the authenticated loopback daemon health endpoint without logging secrets."""

from __future__ import annotations

import json
import stat
import sys
import urllib.error
import urllib.request
from pathlib import Path


def fail(message: str) -> int:
    print(f"health check failed: {message}", file=sys.stderr)
    return 1


def main() -> int:
    if len(sys.argv) != 2:
        return fail("expected one discovery-file path")

    path = Path(sys.argv[1])
    try:
        mode = stat.S_IMODE(path.stat().st_mode)
        if mode & 0o077:
            return fail("discovery file must not be accessible by group or other users")
        data = json.loads(path.read_text(encoding="utf-8"))
        port = data["port"]
        protocol = data["protocolVersion"]
        instance_id = data["instanceId"]
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError):
        return fail("discovery file is missing required valid fields")

    if not isinstance(port, int) or not 1 <= port <= 65535:
        return fail("invalid loopback port")
    if not isinstance(protocol, int) or protocol < 1:
        return fail("invalid protocol version")
    if not isinstance(instance_id, str) or not instance_id:
        return fail("invalid daemon instance identifier")

    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/health/ready",
        headers={"Accept": "application/json", "Origin": "perch://app"},
    )
    try:
        with urllib.request.urlopen(request, timeout=2) as response:
            payload = json.load(response)
            if response.status != 200 or payload.get("status") != "ready":
                return fail("daemon is not ready")
    except (OSError, urllib.error.URLError, ValueError, json.JSONDecodeError):
        return fail("loopback readiness request was unsuccessful")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
