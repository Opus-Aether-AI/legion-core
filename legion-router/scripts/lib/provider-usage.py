#!/usr/bin/env python3
"""Extract provider token counters without jq's floating-point arithmetic."""

import json
import sys


FIELDS = (
    "input_tokens",
    "output_tokens",
    "reasoning_output_tokens",
    "cache_read_input_tokens",
    "cache_creation_input_tokens",
)


def counter(value):
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise ValueError("invalid token counter")
    return value


def usage_from_receipts(receipts):
    result = dict.fromkeys(FIELDS, 0)
    for receipt in receipts:
        usage = receipt.get("usage", receipt)
        if not isinstance(usage, dict):
            raise ValueError("invalid usage object")
        reasoning = counter(usage.get("reasoning", 0))
        output = counter(usage["output"])
        if reasoning > output:
            raise ValueError("reasoning exceeds output")
        result["input_tokens"] += counter(usage["input"])
        result["output_tokens"] += output - reasoning
        result["reasoning_output_tokens"] += reasoning
        result["cache_read_input_tokens"] += counter(usage["cacheRead"])
        result["cache_creation_input_tokens"] += counter(usage["cacheWrite"])
    result["cached_input_tokens"] = result.pop("cache_read_input_tokens")
    return result


def opencode_usage(path):
    messages = {}
    steps = {}
    with open(path, encoding="utf-8") as stream:
        for line in stream:
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(event, dict):
                continue
            part = event.get("part") or {}
            if event.get("type") == "step_finish" and isinstance(part, dict) and part.get("type") == "step-finish":
                steps[part.get("id")] = part
                continue
            properties = event.get("properties") or {}
            if not isinstance(properties, dict):
                continue
            info = properties.get("info") or {}
            if event.get("type") == "message.updated" and isinstance(info, dict) and info.get("role") == "assistant":
                messages[info.get("id")] = info
    result = dict.fromkeys(FIELDS, 0)
    for item in (*messages.values(), *steps.values()):
        tokens = item.get("tokens") or {}
        if not isinstance(tokens, dict):
            raise ValueError("invalid token object")
        cache = tokens.get("cache") or {}
        if not isinstance(cache, dict):
            raise ValueError("invalid cache object")
        for field, value in (
            ("input_tokens", tokens.get("input", 0)),
            ("output_tokens", tokens.get("output", 0)),
            ("reasoning_output_tokens", tokens.get("reasoning", 0)),
            ("cache_read_input_tokens", cache.get("read", 0)),
            ("cache_creation_input_tokens", cache.get("write", 0)),
        ):
            result[field] += counter(value)
    return result


def pi_receipts(path):
    receipts = []
    with open(path, encoding="utf-8") as stream:
        for line in stream:
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(event, dict):
                continue
            if event.get("type") == "message_end":
                message = event.get("message") or {}
                if isinstance(message, dict) and message.get("role") == "assistant":
                    receipts.append(message)
            elif event.get("type") == "compaction_end" and event.get("aborted") is False:
                result = event.get("result") or {}
                if isinstance(result, dict) and result.get("usage") is not None:
                    receipts.append(result["usage"])
    return receipts


def pi_usage(path):
    return usage_from_receipts(pi_receipts(path))


def pi_totals_valid(path):
    for receipt in pi_receipts(path):
        usage = receipt.get("usage", receipt)
        if not isinstance(usage, dict):
            raise ValueError("invalid Pi usage object")
        expected = sum(counter(usage[key]) for key in ("input", "output", "cacheRead", "cacheWrite"))
        if counter(usage["totalTokens"]) != expected:
            raise ValueError("invalid Pi totalTokens")


def hermes_usage(path):
    with open(path, encoding="utf-8") as stream:
        usage = json.load(stream)
    if not isinstance(usage, dict):
        raise ValueError("invalid Hermes usage object")
    output = counter(usage["output_tokens"])
    reasoning = counter(usage["reasoning_tokens"])
    if reasoning > output:
        raise ValueError("reasoning exceeds output")
    return {
        "input_tokens": counter(usage["input_tokens"]),
        "output_tokens": output - reasoning,
        "reasoning_output_tokens": reasoning,
        "cached_input_tokens": counter(usage["cache_read_tokens"]),
        "cache_creation_input_tokens": counter(usage["cache_write_tokens"]),
    }


def hermes_totals_valid(path):
    with open(path, encoding="utf-8") as stream:
        usage = json.load(stream)
    if not isinstance(usage, dict):
        raise ValueError("invalid Hermes usage object")
    expected = sum(counter(usage[key]) for key in (
        "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens"
    ))
    if counter(usage["total_tokens"]) != expected:
        raise ValueError("invalid Hermes total_tokens")


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: provider-usage.py opencode|pi|hermes|pi-total|hermes-total FILE")
    if sys.argv[1] in ("pi-total", "hermes-total"):
        try:
            {"pi-total": pi_totals_valid, "hermes-total": hermes_totals_valid}[sys.argv[1]](sys.argv[2])
        except (KeyError, OSError, TypeError, ValueError):
            raise SystemExit(1)
        return
    try:
        usage = {"opencode": opencode_usage, "pi": pi_usage, "hermes": hermes_usage}[sys.argv[1]](sys.argv[2])
    except (KeyError, OSError, TypeError, ValueError):
        # A present but invalid counter must fail canonical receipt validation,
        # not silently become a measured zero-token run.
        usage = {"input_tokens": -1}
    print(json.dumps(usage, separators=(",", ":")))


if __name__ == "__main__":
    main()
