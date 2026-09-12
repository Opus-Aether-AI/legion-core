"""Exact metering survives lossy jq-style terminal JSON construction."""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


HELPER = Path(__file__).resolve().parents[2] / "legion-router/scripts/lib/exact-metering.py"
ODD = 9007199254740993


class ExactMeteringTests(unittest.TestCase):
    def invoke(self, *args, stdin=None, source=None):
        command = [sys.executable, str(HELPER), *args]
        if source is not None:
            # Mirror the shell caller's fd 3 redirection. subprocess closes
            # descriptors made in preexec_fn unless they were passed through.
            command = ["bash", "-c", 'exec 3< "$1"; shift; exec "$@"',
                       "bash", source.name, *command]
        return subprocess.run(
            command, input=stdin, text=True, capture_output=True, check=False,
        )

    def test_attempt_terminal_replaces_rounded_usage_and_tokens(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "attempt.json"
            path.write_text(json.dumps({"usage": {"input_tokens": ODD},
                                        "usage_status": "known", "cost_usd": 0,
                                        "cost_status": "known"}))
            rounded = {"usage": {"input_tokens": ODD - 1},
                       "tokens": {"input_tokens": ODD - 1},
                       "usage_status": "known", "cost_status": "known"}
            result = self.invoke("patch-attempt", str(path), stdin=json.dumps(rounded))
            self.assertEqual(result.returncode, 0, result.stderr)
            terminal = json.loads(result.stdout)
            self.assertEqual(terminal["usage"]["input_tokens"], ODD)
            self.assertEqual(terminal["tokens"]["input_tokens"], ODD)

    def test_reconciliation_preserves_partial_lower_bound_and_no_launch_override(self):
        source = {"reconciliation": {"usage": None, "usage_status": "partial",
                   "known_usage": {"input_tokens": ODD}, "known_usage_attempts": 1,
                   "cost_usd": None, "cost_status": "partial",
                   "known_cost_usd": 0.1, "known_cost_attempts": 1,
                   "attempt_count": 2}}
        terminal = {"usage": None, "usage_status": "partial",
                    "known_usage": {"input_tokens": ODD - 1},
                    "cost_usd": None, "cost_status": "partial",
                    "metering_reconciliation": source["reconciliation"]}
        with tempfile.NamedTemporaryFile(mode="w+t") as stream:
            json.dump(source, stream)
            stream.seek(0)
            result = self.invoke("patch-reconciliation", stdin=json.dumps(terminal), source=stream)
        self.assertEqual(result.returncode, 0, result.stderr)
        patched = json.loads(result.stdout)
        self.assertEqual(patched["known_usage"]["input_tokens"], ODD)
        self.assertEqual(patched["metering_reconciliation"]["known_usage"]["input_tokens"], ODD)
        terminal["usage_status"] = "unknown"
        with tempfile.NamedTemporaryFile(mode="w+t") as stream:
            json.dump(source, stream)
            stream.seek(0)
            result = self.invoke("patch-reconciliation", stdin=json.dumps(terminal), source=stream)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["known_usage"]["input_tokens"], ODD - 1)

    def test_refuses_symlink_and_oversized_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "receipt.json"
            path.write_text('{"usage":null}')
            alias = Path(directory) / "alias.json"
            alias.symlink_to(path)
            self.assertNotEqual(self.invoke("get", str(alias), "usage").returncode, 0)
            path.write_text(" " * 65537)
            self.assertNotEqual(self.invoke("get", str(path), "usage").returncode, 0)


if __name__ == "__main__":
    unittest.main()
