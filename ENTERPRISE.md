# Legion — Enterprise

Legion is a source-available, model-agnostic execution layer for AI agents. It
routes scoped work to configured executors, runs it in isolation, retains
evidence, meters outcomes, and feeds learning loops. Its current executors are
coding-focused, so implementation and review are the leading use case today.
Enterprise runs Legion inside your environment, on your models, gated by your
standards.

> Legion is an execution layer, not another cloud. It adds no place for your
> code to go that it does not already go, and its coding workflows retain the
> same review and validation evidence as normal engineering work.

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
The core is public and auditable on GitHub — no black box. It is licensed under
[**BSL 1.1**](LICENSE), converting to Apache-2.0 on **2030-08-27**. Your security team can
audit exactly what it does, vendor a **pinned release**, and run it air-gapped
from source. Internal and production use are permitted; offering Legion's
routing, delegation, execution, or observability functionality to third parties
as a hosted, managed, or embedded service requires a commercial licence.
Vulnerability reporting and handling policy: [`SECURITY.md`](SECURITY.md).

---

## Mapped to the AWS Well-Architected Framework

| Pillar | How Legion serves it |
|---|---|
| **Operational excellence** | Every run is a metered `legion.span.v1` trace exported to OTLP; `legion-doctor` health-gates the toolchain; self-healing opens (never merges) remediation PRs. |
| **Security** | Runs locally (no Legion cloud, no vendor middleman); your own model accounts under your data terms; isolated git worktrees; sandboxed executors; agent PRs pass your Sonar/security gates; public, auditable BSL 1.1 core, converting to Apache-2.0 on 2030-08-27. |
| **Reliability** | Built for long-running/overnight agents: worktree isolation + observability + self-healing keep multi-hour runs from drifting. Deterministic orchestration, not a single unbounded agent. |
| **Performance efficiency** | `routing.toml` sends each task to the cheapest **capable** model, escalating only hard work; parallel fan-out across worktrees. |
| **Cost optimization** | Spend is metered per task on one dollar scale across providers; routing policy enforces cost ceilings; `legion-report` shows the bill by model. |
| **Sustainability** | Cheapest-capable routing + no idle SaaS layer means less redundant model compute per shipped change. |

---

## Built for accountable execution

Legion gives a long-running or multi-step agent workflow a durable execution
contract: scoped routing, isolation, evidence, observability, and learning.
For the coding executors available today, that commonly means isolated slices,
cross-model review where configured, and a reviewable diff or PR.

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
