"""A Pier agent that puts LEGION under test, not the CLI underneath it.

Pier ships agents for `codex`, `claude-code`, `opencode` and friends, each of
which drives one vendor CLI directly. Benchmarking Legion with those measures
the executor Legion happens to route to, which is the one thing Legion is not.
This agent runs `legion-delegate` inside the sandbox instead, so a DeepSWE score
reflects routing, isolation, the review gate and the apply step -- the whole
orchestration -- against the same tasks the public leaderboard uses.

Point Pier at it with:

    pier run -p deep-swe/tasks \
      --agent-import-path legion_agent:LegionAgent \
      -m gpt-5.6-terra

Auth: Codex runs from the host's ~/.codex/auth.json, uploaded into the sandbox,
so a ChatGPT-plan account works without an API key -- the same route Pier's own
codex agent takes under CODEX_FORCE_AUTH_JSON.
"""

from __future__ import annotations

import json
import os
import shlex
import subprocess
import tempfile
from pathlib import Path, PurePosixPath

from pier.agents.installed.base import BaseInstalledAgent
from pier.agents.network import allowlist_from_urls
from pier.environments.base import BaseEnvironment
from pier.models.agent.context import AgentContext
from pier.models.agent.install import AgentInstallSpec, InstallStep
from pier.models.agent.network import NetworkAllowlist
from pier.models.trial.paths import EnvironmentPaths

# The repo under test. DeepSWE's collect hook diffs base_commit..HEAD here, so
# whatever Legion produces has to end up COMMITTED in this tree -- a diff left
# in a worktree scores zero however good it is.
REPO = PurePosixPath("/app")

# Where a locally packed legion tarball lands inside the sandbox.
_LOCAL_TARBALL = "/tmp/legion-local.tgz"

_ALLOWLIST = [
    "https://registry.npmjs.org",            # installing codex + legion
    "https://raw.githubusercontent.com",     # nvm bootstrap
    "https://nodejs.org",                    # the node tarball nvm fetches
    "https://api.openai.com",                # API-key auth
    # ChatGPT-plan auth talks to chatgpt.com, NOT api.openai.com. Pier's own
    # codex agent allowlists only the latter, which is why a subscription
    # account fails there with "Connection failed: error sending request" --
    # the proxy silently drops every call and it reads as a network outage.
    "https://chatgpt.com",
    "https://auth.openai.com",
]


class LegionAgent(BaseInstalledAgent):
    """Run a Legion delegation against the task repo and commit the result."""

    SUPPORTS_ATIF = False
    _CODEX_HOME = PurePosixPath("/tmp/codex-home")
    _SECRETS = PurePosixPath("/tmp/legion-secrets")
    _TASK_FILE = PurePosixPath("/tmp/legion-task.txt")

    def __init__(self, *args, legion_source: str | None = None,
                 legion_version: str = "latest", **kwargs):
        super().__init__(*args, **kwargs)
        self._last_receipt: dict | None = None
        self._exit_code: int | None = None
        source = legion_source or os.environ.get("LEGION_SOURCE") or ""
        self._legion_source = Path(source).expanduser().resolve() if source else None
        self._legion_version = legion_version

    @staticmethod
    def name() -> str:
        return "legion"

    def get_version_command(self) -> str | None:
        return "legion-delegate --version 2>/dev/null || echo unknown"

    def parse_version(self, stdout: str) -> str:
        lines = (stdout or "").strip().splitlines()
        return lines[-1].strip() if lines else "unknown"

    def network_allowlist(self) -> NetworkAllowlist:
        return allowlist_from_urls(_ALLOWLIST)

    def install_spec(self) -> AgentInstallSpec:
        # Legion is bash-first: it needs git, jq and a POSIX shell as much as it
        # needs node. A missing jq is the failure that looks like a routing bug.
        #
        # These are 91 language-specific images and most carry no node at all,
        # so node comes from nvm rather than the image's package manager --
        # apt-get simply fails with exit 100 where `nodejs` is not in the
        # sources, which takes the whole build down before the agent ever runs.
        # This mirrors what Pier's own codex agent does, for the same reason.
        #
        # Each package manager branch is tolerant: a missing `ripgrep` must not
        # fail a build over a convenience, but a missing git or jq will surface
        # in the verification command below.
        root_run = (
            "if command -v apt-get >/dev/null 2>&1; then "
            "  apt-get update || true; "
            "  apt-get install -y curl git jq ca-certificates bash || true; "
            "  apt-get install -y ripgrep || true; "
            "elif command -v apk >/dev/null 2>&1; then "
            "  apk add --no-cache curl git jq bash nodejs npm || true; "
            "  apk add --no-cache ripgrep || true; "
            "elif command -v yum >/dev/null 2>&1; then "
            "  yum install -y curl git jq bash || true; "
            "fi; "
            "exit 0"
        )
        # Which Legion is under test? The IMAGE always installs the PUBLISHED
        # package -- that is what users get, so it is the honest number for a
        # public score, and it guarantees node, npm and the CLIs exist.
        #
        # LEGION_SOURCE overlays a locally packed build on top, at SETUP rather
        # than here: install steps become Docker build layers, and a build cannot
        # see a file uploaded to a container that does not exist yet. A lane that
        # could only ever measure the released version would not be able to
        # validate a fix before it ships, and the first bug this lane found was
        # in unreleased code.
        legion_pkg = f"@opus-aether-ai/legion-core@{self._legion_version}"
        agent_run = (
            "set -eu; "
            'if ! command -v npm >/dev/null 2>&1 && [ ! -s "$HOME/.nvm/nvm.sh" ]; then '
            "  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.2/install.sh "
            "    | bash; "
            'fi; '
            'if [ -s "$HOME/.nvm/nvm.sh" ]; then '
            '  . "$HOME/.nvm/nvm.sh"; '
            "  command -v node >/dev/null 2>&1 || nvm install --lts; "
            "fi; "
            f"npm install -g @openai/codex@latest {shlex.quote(legion_pkg)}"
        )
        return AgentInstallSpec(
            agent_name=self.name(),
            version=self._version,
            steps=[
                InstallStep(run=root_run, user="root"),
                InstallStep(run=agent_run, user="agent"),
            ],
            verification_command=(
                'if [ -s "$HOME/.nvm/nvm.sh" ]; then . "$HOME/.nvm/nvm.sh"; fi; '
                "command -v legion-delegate && command -v codex"
            ),
            # Keyed on the published version only, deliberately: the image
            # contains nothing else. A LEGION_SOURCE build is overlaid after the
            # image is up, so it never lands in a cached layer and cannot go
            # stale there.
            cache_key=f"legion-npm-{self._legion_version}",
        )

    async def _install_local_legion(self, environment: BaseEnvironment) -> None:
        """Overlay a locally packed Legion over the published one.

        This runs at SETUP, not install. Install steps become Docker build
        layers, and a build cannot see a file uploaded to a container that does
        not exist yet -- npm fails with ENOENT on the tarball and takes the whole
        image down. Setup execs in the running container, where upload works.

        `npm pack` rather than copying the checkout: it honours the package's own
        `files` list, so what lands in the sandbox is byte-for-byte what npm
        would publish, and it leaves behind .git, node_modules and the .legion
        run store, which together dwarf the package.
        """
        if self._legion_source is None:
            return
        if not (self._legion_source / "package.json").exists():
            raise RuntimeError(
                f"LEGION_SOURCE={self._legion_source} has no package.json; "
                "point it at a legion-core checkout"
            )
        with tempfile.TemporaryDirectory() as staging:
            packed = subprocess.run(
                ["npm", "pack", "--silent", "--pack-destination", staging],
                cwd=self._legion_source, capture_output=True, text=True, check=True,
            )
            name = packed.stdout.strip().splitlines()[-1].strip()
            await environment.upload_file(Path(staging) / name, _LOCAL_TARBALL)
        if environment.default_user is not None:
            await self.exec_as_root(
                environment,
                command=f"chown {environment.default_user} {_LOCAL_TARBALL}",
            )
        await self.exec_as_agent(
            environment,
            command=(
                'if [ -s "$HOME/.nvm/nvm.sh" ]; then . "$HOME/.nvm/nvm.sh"; fi; '
                f"npm install -g {_LOCAL_TARBALL}"
            ),
        )

    async def setup(self, environment: BaseEnvironment) -> None:
        """Overlay a local Legion if asked, then give Codex the credentials."""
        await self._install_local_legion(environment)
        env = self.build_process_env({"CODEX_HOME": self._CODEX_HOME.as_posix()})
        await self.exec_as_agent(
            environment,
            command=(
                f'mkdir -p "$CODEX_HOME" {shlex.quote(self._SECRETS.as_posix())} '
                f"{shlex.quote(EnvironmentPaths.agent_dir.as_posix())}"
            ),
            env=env,
        )
        auth = Path.home() / ".codex" / "auth.json"
        if not auth.exists():
            return
        remote = (self._SECRETS / "auth.json").as_posix()
        await environment.upload_file(auth, remote)
        if environment.default_user is not None:
            # upload_file lands as root; the agent user has to be able to read it.
            await self.exec_as_root(
                environment,
                command=f"chown {environment.default_user} {shlex.quote(remote)}",
            )
        await self.exec_as_agent(
            environment,
            command=f'ln -sf {shlex.quote(remote)} "$CODEX_HOME/auth.json"',
            env=env,
        )

    async def run(self, instruction: str, environment: BaseEnvironment,
                  context: AgentContext) -> None:
        env = self.build_process_env({
            "CODEX_HOME": self._CODEX_HOME.as_posix(),
            "LEGION_SEED_DEPS": "",   # the image already carries its dependencies
            "LEGION_WT_KEEP": "1",    # keep the worktree so a failure is inspectable
            # Legion hard-blocks danger-full-access, and that default is right:
            # it means "no sandbox" on a developer's machine. Here the sandbox
            # already exists and is stronger -- a Pier container with a
            # no-network verifier and an egress allowlist -- and Codex's own
            # sandbox cannot nest inside it. It fails to create its namespace
            # and then reports, accurately, that every shell command is blocked:
            #
            #   "I'm blocked by the workspace runtime: every shell command fails
            #    before execution because the sandbox cannot create its required
            #    namespace ... No repository changes were made."
            #
            # which scores as a task failure when nothing was ever attempted.
            # Pier's own codex agent passes
            # --dangerously-bypass-approvals-and-sandbox for the same reason.
            "LEGION_ALLOW_DANGER": "1",
        })

        # The instruction goes in a FILE, never argv. Legion learned this the
        # hard way: a task over ~32 KB dies with "Argument list too long", and
        # DeepSWE instructions are long. The environment only uploads real
        # files, so stage it locally first -- and write it as bytes, because a
        # task can carry any UTF-8 and a locale-dependent encode would corrupt it.
        with tempfile.NamedTemporaryFile("wb", suffix=".txt", delete=False) as handle:
            handle.write(instruction.encode("utf-8"))
            staged = Path(handle.name)
        try:
            await environment.upload_file(staged, self._TASK_FILE.as_posix())
        finally:
            staged.unlink(missing_ok=True)
        if environment.default_user is not None:
            # upload_file lands as root; Legion runs as the agent user.
            await self.exec_as_root(
                environment,
                command=(
                    f"chown {environment.default_user} "
                    f"{shlex.quote(self._TASK_FILE.as_posix())}"
                ),
            )

        repo = shlex.quote(REPO.as_posix())
        log = shlex.quote((EnvironmentPaths.agent_dir / "legion.txt").as_posix())
        nvm = 'if [ -s "$HOME/.nvm/nvm.sh" ]; then . "$HOME/.nvm/nvm.sh"; fi; '

        # A container has no global git config, and Legion commits.
        await self.exec_as_agent(
            environment,
            command=(
                f"git config --global --add safe.directory {repo}; "
                "git config --global user.email legion@opusaether.com; "
                'git config --global user.name Legion'
            ),
            env=env,
        )

        # --quiet so stdout is Legion's JSON receipt and nothing else; the
        # human-readable stream still lands in the log for a post-mortem.
        result = await self.exec_as_agent(
            environment,
            command=(
                f"{nvm}cd {repo} && "
                f"legion-delegate run --repo {repo} "
                f"--task-file {shlex.quote(self._TASK_FILE.as_posix())} "
                f"--executor codex --archetype implement-feature "
                f"--sandbox danger-full-access --apply --quiet "
                f"2>{log}"
            ),
            env=env,
        )
        self._last_receipt = self._parse_receipt(getattr(result, "stdout", None))

        # Legion applies into the working tree; DeepSWE grades COMMITS.
        await self.exec_as_agent(
            environment,
            command=(
                f"cd {repo} && git add -A && "
                "{ git diff --cached --quiet || "
                'git commit -q -m "legion: task solution"; }'
            ),
            env=env,
        )
        self._exit_code = getattr(result, "exit_code", None)

        # Keep Legion's own run evidence. Without it a scored zero is unreadable:
        # "the model could not do it", "the executor never edited anything" and
        # "the diff was produced but not applied" all look identical from an
        # empty patch, and they call for completely different fixes.
        run_id = (self._last_receipt or {}).get("run_id")
        agent_dir = shlex.quote(EnvironmentPaths.agent_dir.as_posix())
        await self.exec_as_agent(
            environment,
            command=(
                f"cd {repo} 2>/dev/null || exit 0; "
                f"git status --porcelain > {agent_dir}/git-status.txt 2>&1 || true; "
                f"git log --oneline -3 > {agent_dir}/git-log.txt 2>&1 || true; "
                + (
                    f"cp -R .legion/runs/{shlex.quote(run_id)} "
                    f"{agent_dir}/legion-run 2>/dev/null || true; "
                    if run_id else ""
                )
                + f"ls -R .legion/worktrees > {agent_dir}/worktrees.txt 2>&1 || true"
            ),
            env=env,
        )

    @staticmethod
    def _parse_receipt(stdout: str | None) -> dict | None:
        """Pull Legion's JSON receipt out of stdout.

        Scanned last-line-first rather than parsed whole: even under --quiet a
        wrapper can prepend a line, and the receipt is the last complete JSON
        object. Never raises -- a benchmark must not fail because accounting
        was unreadable.
        """
        if not stdout:
            return None
        for line in reversed(stdout.strip().splitlines()):
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                parsed = json.loads(line)
            except ValueError:
                continue
            if isinstance(parsed, dict) and "run_id" in parsed:
                return parsed
        return None

    def populate_context_post_run(self, context: AgentContext) -> None:
        """Carry Legion's own accounting back into Pier's.

        Legion already prices every run from its span table, so the numbers here
        are the ones its telemetry reports rather than a second, parallel count
        that could disagree with it. Best-effort by contract: this runs even
        when the trial failed, and a missing receipt must not turn a scored
        failure into an errored trial.
        """
        receipt = self._last_receipt or {}
        usage = receipt.get("usage") or {}

        # Legion's numbers become Pier's first-class metrics rather than a
        # parallel set that could disagree with them. Output counts REASONING
        # too, because that is what the provider bills and what Legion prices.
        out = usage.get("output_tokens")
        reasoning = usage.get("reasoning_output_tokens")
        if out is not None or reasoning is not None:
            context.n_output_tokens = (out or 0) + (reasoning or 0)
        context.n_input_tokens = usage.get("input_tokens")
        context.n_cache_tokens = usage.get("cached_input_tokens")
        if receipt.get("cost_usd") is not None:
            context.cost_usd = receipt["cost_usd"]

        context.metadata = {
            **(context.metadata or {}),
            "legion_run_id": receipt.get("run_id"),
            "legion_status": receipt.get("status"),
            "legion_reason": receipt.get("reason"),
            "legion_model": receipt.get("model"),
            "legion_exit_code": self._exit_code,
            "legion_receipt_parsed": bool(self._last_receipt),
        }
