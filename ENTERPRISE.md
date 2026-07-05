# Legion — Enterprise

Legion is the open-source (Apache-2.0) engine that runs a cohort of coding agents —
**Codex, Cursor, Claude, and the models you already trust** — as one accountable workflow:
**plan → execute → review → a verified Pull Request**. The core is free forever. Enterprise is
Legion run **inside your environment, on your models, gated by your standards** — with us on the
line for it. It meets your engineers in the tools they already use — **Claude Code, Codex, Cursor,
and opencode** — from one shared install.

> The one-line pitch for a CTO: *Legion is orchestration, not another cloud. It adds no place for
> your code to go that it doesn't already go — and every change it makes lands as a normal PR that
> passes the exact gates your engineers' code passes.*

---

## Enterprise-safe by design

### 1. Local-first. No Legion cloud, no middleman.
Legion runs **locally on your engineers' machines** — CLIs plus **isolated local git worktrees**.
There is no Legion server, and unlike Cursor there is **no third-party vendor in the path**. Model
inference runs on **your own Claude and Codex accounts directly**, so context sent for inference
goes to Anthropic / OpenAI **under your own agreement with them** (use their enterprise /
zero-retention / no-training tiers) — never routed through us. Your repository, history, and
worktrees stay on your machine.

> Contrast with the Cursor concern you raised: Cursor puts *its* cloud between you and the model.
> Legion doesn't — it drives *your* accounts from a local CLI. The one external hop is the model
> inference itself, the same hop any use of Claude or Codex makes.
>
> **Roadmap:** an API-key-based, **hostable** deployment for centralized/team use; and because
> routing is endpoint-agnostic, on-network model endpoints for teams that need inference to stay
> inside their boundary too.

### 2. Agent code passes the same quality gate as human code — no bypass.
Legion's output is a **normal Pull Request**. It flows through your existing pipeline — **Sonar
static analysis, your per-file line ceiling, your duplication threshold, your security scans** —
and merges **only on a green gate**. An AI author gets no special path. Better: Legion's **pre-PR
verify step** can run those same checks, so a diff that would fail Sonar **never opens a PR** in
the first place. And **nothing auto-merges** — a human approves every change.

### 3. Organizational guardrails, enforced by construction.
Consistency isn't left to whether a developer remembers the standard. Legion carries your
**stacks, patterns, and required checks** as policy (skills + `routing.toml` + `legion-doctor`),
applied identically to **every developer and every agent run**. The doctor gates CI and refuses to
ship a broken configuration. Deviations into non-standard implementations are caught at the gate,
not in review three weeks later.

### 4. Observable and auditable — in *your* stack.
Every unit of work emits a **`legion.span.v1`** record — executor, model, tokens, **cost**,
timing, outcome — and exports as **OpenTelemetry (OTLP)** into your existing observability
(Datadog, Grafana, your OTel collector). You get a full, metered **audit trail** of what every
agent did and what it cost. A multi-agent run stitches into one trace tree.

### 5. Read the engine before it touches a repo.
The core is **Apache-2.0 on GitHub** — no black box. Your security team can audit exactly what it
does, vendor a **pinned release**, and run it air-gapped from source. Vulnerability reporting and
handling policy: [`SECURITY.md`](SECURITY.md).

---

## Mapped to the AWS Well-Architected Framework

| Pillar | How Legion serves it |
|---|---|
| **Operational excellence** | Every run is a metered `legion.span.v1` trace exported to OTLP; `legion-doctor` health-gates the toolchain; self-healing opens (never merges) remediation PRs. |
| **Security** | Runs locally (no Legion cloud, no vendor middleman); your own model accounts under your data terms; isolated git worktrees; sandboxed executors; agent PRs pass your Sonar/security gates; Apache-2.0 auditable core. |
| **Reliability** | Built for long-running/overnight agents: worktree isolation + observability + self-healing keep multi-hour runs from drifting. Deterministic orchestration, not a single unbounded agent. |
| **Performance efficiency** | `routing.toml` sends each task to the cheapest **capable** model, escalating only hard work; parallel fan-out across worktrees. |
| **Cost optimization** | Spend is metered per task on one dollar scale across providers; routing policy enforces cost ceilings; `legion-report` shows the bill by model. |
| **Sustainability** | Cheapest-capable routing + no idle SaaS layer means less redundant model compute per shipped change. |

---

## Built for the long-running case
Legion exists to fix the failure mode of a single agent left to run overnight or watch a system
continuously: it drifts, loses context, and ships something nobody reviewed. Legion decomposes the
goal, isolates each slice in its own worktree, cross-verifies across models, and **stops at a
reviewable PR**. That's the difference between a coding *assistant* and an orchestration *engine*
you can trust with a background lane.

---

## What we stand up (the engagement)

1. **Runs on your machines (local, today).** Legion CLIs + your own Claude/Codex accounts; your
   repo, history, and worktrees stay local — no Legion cloud, no vendor middleman. We configure it
   against your CI and telemetry sink and hand you a green `legion-doctor`. *(A hostable,
   API-key-based deployment for centralized/team use is on the roadmap.)*
2. **Wire your Secure SDLC.** Sonar and your quality gates (line ceiling, duplication threshold,
   security scans) integrated into Legion's pre-PR verify, so agent output is gated *before* it
   asks for a human's time — and always at the same bar on merge.
3. **Encode your guardrails.** Your approved stacks, patterns, and org standards as Legion policy,
   applied to every run.
4. **Design your routing policy.** Model mix, cost ceilings, and risk tolerance in `routing.toml`,
   validated against your own workloads.
5. **Build your domain agent on legion-core.** Not a generic horizontal tool — a focused agent for
   *your* stacks (the fastest path to demonstrable value), with the same delegation, telemetry, and
   gates we run ourselves.
6. **Support & SLA.** A named channel, priority fixes, and upgrade help.

## Deployment models
- **Local (today)** — Legion CLIs on each developer's machine, driving your Claude + Codex
  accounts; repo and worktrees stay local.
- **Hostable (roadmap)** — a centralized/team deployment via API-key-based Claude/Codex.
- **On-network inference (roadmap)** — endpoint-agnostic routing to model endpoints inside your
  boundary for teams that need inference to stay on-network.
- **Managed pilot** — Opus Aether builds a scoped domain agent in your repos to prove value fast.

## Commercial
Engagement-based: a scoped **paid pilot** (deploy + one domain agent + your SDLC gates wired), then
an annual **support + SLA** subscription for the rollout. Pricing is set to the engagement — talk
to us.

## Talk to us
- ai@opusaether.com
- https://legion.opusaether.com/enterprise
