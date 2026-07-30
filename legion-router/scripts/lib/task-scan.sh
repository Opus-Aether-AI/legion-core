#!/usr/bin/env bash
# Shared best-effort dangerous-task classifier for write-capable executors.
#
# This is deliberately a tripwire, not a security boundary. The executor
# sandbox and isolated worktree remain the containment layer. Keep command
# names token-delimited: substring matching previously treated benign words
# such as "truncated", "sync", "pseudo", and "backdrop table" as commands.

# Print a stable rule id and return 0 when task text looks dangerous.
# Return 1 without output when no rule matches.
legion_task_danger_reason() {
  local text="${1:-}" norm=""
  norm="$(printf '%s' "$text" | tr -s '[:space:]' ' ')"

  # Command delimiters are intentionally shell-like. They accept prose such as
  # "run: nc -l" while rejecting matches embedded inside larger identifiers.
  local command_start='(^|[[:space:];|&()])'
  local command_end='($|[[:space:];|&()])'
  local word_start='(^|[^[:alnum:]_])'
  local word_end='($|[^[:alnum:]_])'

  if printf '%s' "$norm" | grep -qiE \
    "${command_start}rm[[:space:]]+(-rf|-fr)${command_end}|${command_start}rm[[:space:]]+-[[:alpha:]]*r[[:alpha:]]*[[:space:]]+/${command_end}"; then
    printf 'destructive-rm\n'
    return 0
  fi
  if printf '%s' "$norm" | grep -qiE \
    "${command_start}git[[:space:]]+push${command_end}|${word_start}force[ -]push${word_end}|(^|[[:space:];|&])--force($|[=[:space:];|&])"; then
    printf 'force-push\n'
    return 0
  fi
  if printf '%s' "$norm" | grep -qiE ':\(\)[[:space:]]*\{'; then
    printf 'shell-fork-bomb\n'
    return 0
  fi
  if printf '%s' "$norm" | grep -qiE \
    "${word_start}/etc/(passwd|shadow)${word_end}|(^|[/~[:space:]])\\.ssh(/|$|[[:space:]])|${word_start}id_rsa${word_end}|(^|[/~[:space:]])\\.aws/|(^|[/~[:space:]])\\.netrc${word_end}"; then
    printf 'credential-path\n'
    return 0
  fi
  if printf '%s' "$norm" | grep -qiE \
    "${word_start}(AWS_SECRET|ANTHROPIC_API_KEY|OPENAI_API_KEY)${word_end}"; then
    printf 'credential-secret\n'
    return 0
  fi
  if printf '%s' "$norm" | grep -qiE \
    "${command_start}(curl|wget|fetch)${word_end}[^|]*\\|[[:space:]]*(ba)?sh${command_end}"; then
    printf 'download-pipe-shell\n'
    return 0
  fi
  if printf '%s' "$norm" | grep -qiE \
    "${command_start}(nc|ncat)${command_end}|${word_start}/dev/tcp${word_end}"; then
    printf 'network-shell\n'
    return 0
  fi
  if printf '%s' "$norm" | grep -qiE \
    "${word_start}DROP[[:space:]]+TABLE${word_end}"; then
    printf 'destructive-sql\n'
    return 0
  fi
  if printf '%s' "$norm" | grep -qiE \
    "${command_start}sudo${command_end}"; then
    printf 'privilege-escalation\n'
    return 0
  fi
  return 1
}

# Call the wrapper's die() with a consistent, explainable refusal.
legion_scan_task_text() {
  local text="${1:-}" reason=""
  [[ "${LEGION_ALLOW_UNSAFE:-0}" == "1" ]] && return 0
  if reason="$(legion_task_danger_reason "$text")"; then
    die "task text matched dangerous/injection rule '$reason'; refusing write delegation. Review the task, or set LEGION_ALLOW_UNSAFE=1 to override."
  fi
}
