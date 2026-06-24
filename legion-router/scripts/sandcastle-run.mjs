#!/usr/bin/env node
// Thin optional bridge from legion-delegate's diff contract to Sandcastle's
// branch-merge contract. @ai-hero/sandcastle is imported only on this path.

import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { cpSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

const INSTALL_HINT =
  "@ai-hero/sandcastle not installed. Run: npm i -D @ai-hero/sandcastle";

const readStdin = async () => {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf8");
};

const git = (cwd, args) =>
  execFileSync("git", ["-C", cwd, ...args], { encoding: "utf8" });

const sandboxImport = {
  docker: "@ai-hero/sandcastle/sandboxes/docker",
  podman: "@ai-hero/sandcastle/sandboxes/podman",
  vercel: "@ai-hero/sandcastle/sandboxes/vercel",
};

const providerName = { docker: "docker", podman: "podman", vercel: "vercel" };

const job = JSON.parse(await readStdin());
const {
  task,
  model,
  sandbox,
  cwd,
  main_repo: mainRepo = cwd,
  base = "HEAD",
  diff_path: diffPath,
  artifact_dir: artifactDir,
  untrusted = false,
} = job;

if (!task || !model || !sandbox || !cwd || !sandboxImport[sandbox]) {
  console.error(
    "sandcastle-run: expected { task, model, sandbox, cwd, base?, diff_path? }",
  );
  process.exit(2);
}

let run;
let codex;
let sandboxFactory;
try {
  ({ run, codex } = await import("@ai-hero/sandcastle"));
  ({ [providerName[sandbox]]: sandboxFactory } = await import(
    sandboxImport[sandbox]
  ));
} catch {
  console.error(INSTALL_HINT);
  process.exit(3);
}

const baseSha = git(cwd, ["rev-parse", base]).trim();
const branch =
  job.branch || `legion/sandcastle-${Date.now()}-${randomUUID().slice(0, 8)}`;

// codex() only accepts effort ∈ low|medium|high|xhigh (it bypasses approvals by
// default, so no permission flag is needed). Map Legion's "max" → "xhigh" and
// drop anything else rather than passing an invalid value.
const CODEX_EFFORTS = new Set(["low", "medium", "high", "xhigh"]);
let effort = job.effort === "max" ? "xhigh" : job.effort;
if (effort && !CODEX_EFFORTS.has(effort)) effort = undefined;

const agent = codex(model, effort ? { effort } : {});

const readSandboxConfig = (repoRoot) => {
  const path = join(repoRoot, ".legion", "sandbox.json");
  if (!existsSync(path)) return {};
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8"));
    return parsed && typeof parsed === "object" && !Array.isArray(parsed)
      ? parsed
      : {};
  } catch {
    console.error("sandcastle-run: warning: invalid .legion/sandbox.json; ignoring config");
    return {};
  }
};

const detectInstall = (worktreeRoot) => {
  if (existsSync(join(worktreeRoot, "bun.lockb")) || existsSync(join(worktreeRoot, "bun.lock"))) {
    return "bun install";
  }
  if (existsSync(join(worktreeRoot, "pnpm-lock.yaml"))) return "pnpm install";
  if (existsSync(join(worktreeRoot, "yarn.lock"))) return "yarn install";
  if (existsSync(join(worktreeRoot, "package-lock.json"))) return "npm install";
  return "";
};

const safeRelativePath = (path) =>
  typeof path === "string" &&
  path.length > 0 &&
  path !== "." &&
  !path.startsWith("/") &&
  !path.split("/").includes("..");

const sandboxConfig = readSandboxConfig(mainRepo);
const installCommand =
  typeof sandboxConfig.install === "string" && sandboxConfig.install.length > 0
    ? sandboxConfig.install
    : detectInstall(cwd);
const devCommand =
  typeof sandboxConfig.dev === "string" && sandboxConfig.dev.length > 0
    ? sandboxConfig.dev
    : "";
const copyPaths = Array.isArray(sandboxConfig.copy)
  ? sandboxConfig.copy.filter(safeRelativePath)
  : [];

// copyToWorktree resolves paths relative to the run's `cwd` (the anchor worktree),
// but configured creds (e.g. .env.local) are gitignored and live in the MAIN repo,
// not in this fresh worktree. Stage them into `cwd` first so copyToWorktree finds
// them, then list them. Trusted runs only — untrusted (issue-triggered) gets none.
let copyToWorktree = [];
if (untrusted && copyPaths.length > 0) {
  console.error("sandcastle-run: creds skipped (untrusted run)");
} else if (!untrusted) {
  for (const rel of copyPaths) {
    const src = join(mainRepo, rel);
    if (!existsSync(src)) {
      console.error(`sandcastle-run: warning: copy path missing: ${rel}`);
      continue;
    }
    try {
      const dest = join(cwd, rel);
      mkdirSync(dirname(dest), { recursive: true });
      cpSync(src, dest, { recursive: true });
      copyToWorktree.push(rel);
    } catch (error) {
      console.error(`sandcastle-run: warning: copy failed for ${rel}: ${error.message}`);
    }
  }
}
if (copyToWorktree.length > 0) {
  const copiedSecretsPath = join(artifactDir || (diffPath ? dirname(diffPath) : cwd), "copied-secrets.json");
  try {
    writeFileSync(
      copiedSecretsPath,
      `${JSON.stringify({ copied_secret_names: copyToWorktree })}\n`,
    );
  } catch (error) {
    console.error(`sandcastle-run: warning: copied-secret audit failed: ${error.message}`);
  }
}

// Setup runs INSIDE the sandbox once it's ready. SandboxHooks.sandbox.onSandboxReady
// is a DECLARATIVE list of { command, sudo?, timeoutMs? } (not a callback) — see the
// @ai-hero/sandcastle types. Install deps first; then, opt-in, start the dev server
// in the BACKGROUND (& ) so the hook returns and the sandbox teardown reaps it.
const sandboxCommands = [];
if (installCommand) {
  sandboxCommands.push({ command: installCommand });
} else {
  console.error("sandcastle-run: install skipped (no .install and no supported lockfile)");
}
if (devCommand) {
  sandboxCommands.push({
    command: `sh -lc ${JSON.stringify(
      `${devCommand} >/tmp/legion-sandbox-dev.log 2>&1 & echo $! >/tmp/legion-sandbox-dev.pid`,
    )}`,
  });
  console.error(
    "sandcastle-run: dev server will start in sandbox (parallel worktrees may clash on a fixed port)",
  );
}
const hooks = sandboxCommands.length > 0 ? { sandbox: { onSandboxReady: sandboxCommands } } : undefined;

const result = await run({
  agent,
  sandbox: sandboxFactory(),
  prompt: task,
  cwd,
  ...(hooks ? { hooks } : {}),
  ...(copyToWorktree.length > 0 ? { copyToWorktree } : {}),
  // NamedBranchStrategy: commits land on `branch`, created from `baseBranch`.
  branchStrategy: { type: "branch", branch, baseBranch: base },
});

const resultBranch = result?.branch || branch;
const diff = git(cwd, ["diff", `${baseSha}...${resultBranch}`]);

if (diffPath) {
  writeFileSync(diffPath, diff);
} else {
  process.stdout.write(`${resultBranch}\n${diff}`);
}

// Sum token usage across iterations so the caller meters real cost instead of a
// false zero. sandcastle exposes camelCase counts (undefined when the provider
// can't parse usage); map to legion's snake_case shape. null => "unmeasured".
const totals = (result?.iterations || []).reduce(
  (acc, it) => {
    const u = it?.usage;
    if (!u) return acc;
    acc.input_tokens += u.inputTokens || 0;
    acc.cached_input_tokens += u.cacheReadInputTokens || 0;
    acc.output_tokens += u.outputTokens || 0;
    acc.seen = true;
    return acc;
  },
  { input_tokens: 0, cached_input_tokens: 0, output_tokens: 0, reasoning_output_tokens: 0, seen: false },
);
const usage = totals.seen
  ? {
      input_tokens: totals.input_tokens,
      cached_input_tokens: totals.cached_input_tokens,
      output_tokens: totals.output_tokens,
      reasoning_output_tokens: 0,
    }
  : null;

process.stdout.write(
  `${JSON.stringify({
    status: "ok",
    sandbox,
    branch: resultBranch,
    diff_path: diffPath || null,
    usage,
  })}\n`,
);
