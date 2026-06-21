#!/usr/bin/env node
// Thin optional bridge from legion-delegate's diff contract to Sandcastle's
// branch-merge contract. @ai-hero/sandcastle is imported only on this path.

import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { writeFileSync } from "node:fs";

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
const { task, model, sandbox, cwd, base = "HEAD", diff_path: diffPath } = job;

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

const result = await run({
  agent,
  sandbox: sandboxFactory(),
  prompt: task,
  cwd,
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

process.stdout.write(
  `${JSON.stringify({
    status: "ok",
    sandbox,
    branch: resultBranch,
    diff_path: diffPath || null,
  })}\n`,
);
