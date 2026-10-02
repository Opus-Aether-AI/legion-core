import json
import subprocess
from pathlib import Path


HELPER = Path(__file__).parents[2] / "legion-router/scripts/lib/provider-usage.py"


def parse(tmp_path, mode, records):
    source = tmp_path / "provider.jsonl"
    source.write_text("\n".join(json.dumps(item) for item in records) + "\n", encoding="utf-8")
    completed = subprocess.run(
        ["python3", str(HELPER), mode, str(source)],
        check=True, capture_output=True, text=True,
    )
    return json.loads(completed.stdout)


def test_opencode_preserves_exact_counters_after_last_update_and_step(tmp_path):
    huge = 10**1000
    records = [
        {"type": "message.updated", "properties": {"info": {
            "id": "a", "role": "assistant", "tokens": {"input": 1}}}},
        {"type": "message.updated", "properties": {"info": {
            "id": "a", "role": "assistant", "tokens": {
                "input": huge, "output": 9, "reasoning": 2,
                "cache": {"read": 3, "write": 4}}}}},
        {"type": "step_finish", "part": {"id": "s", "type": "step-finish",
            "tokens": {"input": 7, "output": 5, "reasoning": 1,
                       "cache": {"read": 6, "write": 8}}}, "properties": {}},
    ]
    assert parse(tmp_path, "opencode", records) == {
        "input_tokens": huge + 7, "output_tokens": 14,
        "reasoning_output_tokens": 3, "cache_read_input_tokens": 9,
        "cache_creation_input_tokens": 12,
    }


def test_pi_preserves_exact_sum_and_reasoning_subtraction(tmp_path):
    huge = 10**1000
    usage = {"input": huge, "output": huge + 3, "reasoning": huge,
             "cacheRead": 4, "cacheWrite": 5}
    records = [
        {"type": "message_end", "message": {"role": "assistant", "usage": usage}},
        {"type": "compaction_end", "aborted": False,
         "result": {"usage": {"input": 7, "output": 9, "reasoning": 2,
                              "cacheRead": 1, "cacheWrite": 3}}},
    ]
    assert parse(tmp_path, "pi", records) == {
        "input_tokens": huge + 7, "output_tokens": 10,
        "reasoning_output_tokens": huge + 2, "cached_input_tokens": 5,
        "cache_creation_input_tokens": 8,
    }


def test_hermes_preserves_exact_reasoning_subtraction(tmp_path):
    huge = 10**1000
    assert parse(tmp_path, "hermes", [{
        "input_tokens": huge, "output_tokens": huge + 17,
        "reasoning_tokens": huge, "cache_read_tokens": 4,
        "cache_write_tokens": 5,
    }]) == {
        "input_tokens": huge, "output_tokens": 17,
        "reasoning_output_tokens": huge, "cached_input_tokens": 4,
        "cache_creation_input_tokens": 5,
    }


def test_invalid_provider_counter_does_not_become_known_zero(tmp_path):
    assert parse(tmp_path, "opencode", [{
        "type": "message.updated", "properties": {"info": {
            "id": "a", "role": "assistant", "tokens": {"input": -1}}},
    }]) == {"input_tokens": -1}


def test_exact_total_validation_rejects_mismatches(tmp_path):
    huge = 9007199254740993
    source = tmp_path / "totals.jsonl"
    pi_record = {"type": "message_end", "message": {"role": "assistant", "usage": {
        "input": huge, "output": 1, "cacheRead": 0, "cacheWrite": 0,
        "totalTokens": huge + 1,
    }}}
    source.write_text(json.dumps(pi_record) + "\n", encoding="utf-8")
    command = ["python3", str(HELPER), "pi-total", str(source)]
    assert subprocess.run(command, check=False).returncode == 0
    pi_record["message"]["usage"]["totalTokens"] += 1
    source.write_text(json.dumps(pi_record) + "\n", encoding="utf-8")
    assert subprocess.run(command, check=False).returncode == 1

    hermes_usage = {
        "input_tokens": 0, "output_tokens": huge,
        "cache_read_tokens": 1, "cache_write_tokens": 0,
        "total_tokens": huge + 1,
    }
    source.write_text(json.dumps(hermes_usage), encoding="utf-8")
    command = ["python3", str(HELPER), "hermes-total", str(source)]
    assert subprocess.run(command, check=False).returncode == 0
    hermes_usage["total_tokens"] += 1
    source.write_text(json.dumps(hermes_usage), encoding="utf-8")
    assert subprocess.run(command, check=False).returncode == 1
