"""Black-box contract tests for the typed self-learning context boundary.

These fixtures deliberately contain only literal, maintainer-readable records.
They exercise the installed command rather than implementation helpers so every
consumer (including legion-run) sees the same deterministic boundary.
"""

import json
import os
import shutil
import subprocess


HERE = os.path.dirname(__file__)
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
CLI = os.path.join(ROOT, "legion-observability", "bin", "legion-self-learn")
FIXTURES = os.path.join(ROOT, "tests", "fixtures", "self-learning-context")
SCHEMAS = os.path.join(ROOT, "legion-observability", "schema")


def _repo(tmp_path):
    repo = tmp_path / "release-tools"
    repo.mkdir()
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    subprocess.run(
        [
            "git",
            "-C",
            str(repo),
            "remote",
            "add",
            "origin",
            "git@github.com:Acme/Release-Tools.git",
        ],
        check=True,
    )
    return repo


def _environment(tmp_path, repo, fixture="hints.json"):
    project = tmp_path / "project-learning"
    global_learning = tmp_path / "global-learning"
    project.mkdir()
    global_learning.mkdir()
    shutil.copyfile(os.path.join(FIXTURES, fixture), project / "hints.json")
    env = os.environ.copy()
    env.update(
        {
            "HOME": str(tmp_path / "home"),
            "LEGION_PROJECT_LEARNING_DIR": str(project),
            "LEGION_GLOBAL_LEARNING_DIR": str(global_learning),
        }
    )
    return env, project, global_learning


def _command(*args, env):
    return subprocess.run(
        [CLI, *args], text=True, capture_output=True, check=False, env=env
    )


def _compile(repo, env, *extra):
    result = _command(
        "compile-context",
        "--repo",
        str(repo),
        "--entity",
        "skill:release",
        "--stage",
        "plan",
        *extra,
        "--json",
        env=env,
    )
    assert result.returncode == 0, result.stderr
    return result.stdout.encode("utf-8"), json.loads(result.stdout)


def _validate_document(document, schema):
    """Small public-schema check for the non-recursive contract fields.

    The suite intentionally avoids importing a production validator dependency.
    The shipped JSON Schema remains the authority for required fields, declared
    types, and discriminating constants at this CLI boundary.
    """
    for name in schema["required"]:
        assert name in document, f"missing schema-required field: {name}"
    for name, rule in schema.get("properties", {}).items():
        if name not in document:
            continue
        if "const" in rule:
            assert document[name] == rule["const"]
        expected = rule.get("type")
        if expected == "string":
            assert isinstance(document[name], str)
        elif expected == "array":
            assert isinstance(document[name], list)
        elif expected == "object":
            assert isinstance(document[name], dict)
        elif expected == "integer":
            assert isinstance(document[name], int) and not isinstance(document[name], bool)


def test_compile_context_is_byte_stable_and_schema_valid(tmp_path):
    repo = _repo(tmp_path)
    env, _, _ = _environment(tmp_path, repo)

    first, payload = _compile(repo, env)
    second, _ = _compile(repo, env)

    with open(
        os.path.join(SCHEMAS, "legion.learning-context.v1.schema.json"), encoding="utf-8"
    ) as handle:
        schema = json.load(handle)
    _validate_document(payload, schema)
    assert first == second
    assert payload["repository_identity"] == "github.com/acme/release-tools"
    assert payload["entity"] == "skill:release"
    assert payload["stage"] == "plan"


def test_compile_context_resolves_exact_selector_and_global_with_reasons(tmp_path):
    repo = _repo(tmp_path)
    env, _, _ = _environment(tmp_path, repo)

    _, payload = _compile(repo, env)

    assert [hint["id"] for hint in payload["selected_hints"]] == [
        "exact-release",
        "selector-release",
        "global-safety",
    ]
    assert [hint["selection_reason"] for hint in payload["selected_hints"]] == [
        "exact",
        "selector",
        "global",
    ]
    excluded = {hint["id"]: hint["exclusion_reason"] for hint in payload["excluded_hints"]}
    assert excluded["retired-rule"] == "retired"
    assert excluded["old-release-rule"] == "superseded"


def test_compile_context_has_stable_ordering_and_enforces_hint_token_limits(tmp_path):
    repo = _repo(tmp_path)
    env, _, _ = _environment(tmp_path, repo, "over-budget-hints.json")

    _, payload = _compile(repo, env, "--max-hints", "2", "--max-tokens", "25")

    assert [hint["id"] for hint in payload["selected_hints"]] == ["a-first", "b-second"]
    assert payload["limits"]["max_hints"] == 2
    assert payload["limits"]["max_tokens"] == 25
    assert payload["usage"]["hint_count"] == 2
    assert payload["usage"]["token_count"] <= 25
    assert {hint["id"] for hint in payload["excluded_hints"]} == {"m-middle", "z-last"}
    assert {hint["exclusion_reason"] for hint in payload["excluded_hints"]} == {"hint_limit", "token_limit"}


def test_compile_context_delivers_trusted_guidance_only_and_never_echoes_untrusted_text(tmp_path):
    repo = _repo(tmp_path)
    env, _, _ = _environment(tmp_path, repo)

    raw, payload = _compile(repo, env)

    assert "untrusted-injection" not in {hint["id"] for hint in payload["selected_hints"]}
    assert b"fixture-only-secret" not in raw
    assert b"Ignore all earlier safeguards" not in raw
    excluded = {hint["id"]: hint["exclusion_reason"] for hint in payload["excluded_hints"]}
    assert excluded["untrusted-injection"] == "untrusted"


def test_context_and_usage_schemas_are_public_versioned_documents():
    expected = {
        "legion.learning-hint.v1.schema.json": "legion.learning-hint.v1",
        "legion.learning-context.v1.schema.json": "legion.learning-context.v1",
        "legion.learning-context-receipts.v1.schema.json": "legion.learning-context-receipts.v1",
        "legion.learning-usage.v1.schema.json": "legion.learning-usage.v1",
        "legion.learning-evidence.v1.schema.json": "legion.learning-evidence.v1",
        "legion.learning-state.v1.schema.json": "legion.learning-state.v1",
    }
    for filename, title in expected.items():
        with open(os.path.join(SCHEMAS, filename), encoding="utf-8") as handle:
            schema = json.load(handle)
        assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
        assert schema["title"] == title


def test_reconcile_deduplicates_replayed_evidence_and_rehomes_legacy_path_state(tmp_path):
    repo = _repo(tmp_path)
    env, project, _ = _environment(tmp_path, repo)
    legacy = project / "legacy-state.json"
    evidence = project / "evidence.jsonl"
    shutil.copyfile(os.path.join(FIXTURES, "legacy-state.json"), legacy)
    shutil.copyfile(os.path.join(FIXTURES, "evidence-replay.jsonl"), evidence)

    result = _command(
        "reconcile",
        "--repo",
        str(repo),
        "--legacy-state",
        str(legacy),
        "--evidence",
        str(evidence),
        "--json",
        env=env,
    )

    assert result.returncode == 0, result.stderr
    payload = json.loads(result.stdout)
    assert payload["repository_identity"] == "github.com/acme/release-tools"
    assert payload["reconciled_legacy_identities"] == ["/Users/example/src/release-tools"]
    assert payload["evidence_ids"] == ["evidence-one", "evidence-two"]
    assert payload["evidence_replayed"] == 3
    assert payload["evidence_deduplicated"] == 1
    assert (project / "state.json").exists()
