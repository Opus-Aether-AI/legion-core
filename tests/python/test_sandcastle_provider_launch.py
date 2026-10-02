import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys

import pytest


ROOT = Path(__file__).parents[2]
LAUNCHER = ROOT / "legion-router/scripts/lib/sandcastle-provider-launch.py"
EXEC_GATE = ROOT / "legion-router/scripts/lib/child-exec-gate.py"


@pytest.mark.parametrize("replace_before_launch", (False, True))
def test_sandcastle_provider_launch_binds_digest_and_keeps_token_out_of_argv(
    tmp_path: Path, replace_before_launch: bool,
) -> None:
    marker = tmp_path / "provider-marker.json"
    token_path = tmp_path / "launch.token"
    provider = tmp_path / "provider"
    output = tmp_path / "provider-ran"
    admitted = f"#!/bin/sh\nprintf original > {output}\n"
    provider.write_text(admitted, encoding="utf-8")
    provider.chmod(0o700)
    expected = hashlib.sha256(admitted.encode()).hexdigest()
    if replace_before_launch:
        replacement = tmp_path / "replacement"
        replacement.write_text(f"#!/bin/sh\nprintf unadmitted > {output}\n", encoding="utf-8")
        replacement.chmod(0o700)
        os.replace(replacement, provider)
    token = secrets.token_hex(24)
    token_path.write_text(token + "\n", encoding="ascii")
    token_path.chmod(0o600)
    command = [sys.executable, str(LAUNCHER), str(marker), str(token_path),
               str(EXEC_GATE), expected, str(provider)]
    assert token not in " ".join(command)

    process = subprocess.run(command, capture_output=True, timeout=8)

    payload = json.loads(marker.read_text(encoding="utf-8"))
    assert "token" not in payload
    assert payload["schema"] == "legion.sandcastle-provider-launch.v2"
    assert not token_path.exists()
    if replace_before_launch:
        assert process.returncode != 0
        assert payload["status"] == "not-started"
        assert not output.exists()
    else:
        assert process.returncode == 0
        assert payload["status"] == "started"
        assert output.read_text(encoding="utf-8") == "original"
    verification = subprocess.run(
        [sys.executable, str(LAUNCHER), "--verify", str(marker)],
        input=token, text=True, capture_output=True, timeout=4,
    )
    assert verification.stdout == payload["status"]
    forged = {**payload, "status": "pending" if replace_before_launch else "not-started"}
    marker.write_text(json.dumps(forged), encoding="utf-8")
    verification = subprocess.run(
        [sys.executable, str(LAUNCHER), "--verify", str(marker)],
        input=token, text=True, capture_output=True, timeout=4,
    )
    assert verification.stdout == "malformed"
