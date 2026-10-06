# Document Workflows

Legion runs document work (research reports, business plans, investor and
policy documents, budgets, decision records) through the same lifecycle as
code: a plan with explicit slices, deterministic validation, independent
review and retained evidence. Documents fail in different ways from code,
though. A sentence can be fluent and false. A figure can be right in the model
and wrong in the PDF. A record can be accurate on the day it was written and
quietly stale a week later. This guide sets out the workflow, the archetypes
and the gates that catch those failures.

It distils the strongest public agent skills for documents and research
(Anthropic's `doc-coauthoring`, `docx`, `pptx`, `xlsx` and deep-research
skills; evidence-ledger and claim-verification skills; investor-materials and
financial-model skills; plain-language, anti-AI-writing and copy-editing
skills; decision-log skills) and the lessons of long document engagements run
through `legion-run`. It is domain-free: a domain agent supplies its own
sources of truth, style rules and evaluations through a domain plugin
(`docs/domain-plugins.md`).

## The five rules

1. **One source of truth per kind of content.** Words live in one copy source;
   numbers live in a model or data file; decisions live in an append-only log.
   Every rendered artifact (PDF, deck, page) is derived and is never edited by
   hand. Layout code positions and styles copy; it never rewords, adds, drops
   or reorders it.
2. **The model owns the numbers.** Prose refers to figures through keys or
   tokens that resolve against the model's output. A figure typed into prose
   is a defect even when it is correct today, because it will not move when
   the model does.
3. **Every claim is traceable.** A factual claim points to an evidence record
   (source, date, tier); a figure points to a model key; a target is labelled
   as a target; a judgement is labelled as a judgement. What cannot be traced
   is marked, not invented.
4. **Nothing is done without fresh evidence.** "Done" means the gates ran on
   the current tree and passed, someone looked at every rendered page, and an
   independent reviewer returned a verdict. An agent's report that it checked
   something is a claim, not evidence.
5. **Confidential stays inside.** Sensitive content is labelled where it lives,
   kept out of delegated briefs unless the slice needs it, and blocked by a
   deterministic check from every outward-bound artifact.

## Lifecycle

Each stage ends with a completion criterion. Do not start a stage until the
previous one's criterion holds.

### 1. Brief

Write the brief before drafting: the primary and secondary readers, the
purpose and the ask, the medium and format, the genre conventions that carry
weight, the ranked content, the constraints (length, page counts, house style,
confidentiality), and a requirements checklist taken from any request, RFP or
template.

Separate facts from decisions. Facts are the agent's job: look them up, or send
a `research` slice. Decisions belong to the author. Ask them as a frontier: all
the decisions whose prerequisites are settled, in one numbered round, each
with options and a recommended answer. Questions that depend on unsettled ones
wait for the next round. A question the author cannot answer becomes an open
decision with an owner and a date, not a guess.

*Done when* the brief is written down, every requirement is on the checklist,
and every open decision has an owner.

### 2. Research

Split the question into sub-questions that do not overlap and together cover
it, plus deliberately independent viewpoints. Give each to a `research`
executor in a fresh context with an objective, boundaries, a tool-call budget
and an absolute output path. Run them in parallel; allow at most one
gap-filling round.

Researchers return evidence records, not prose:

| Field | Meaning |
| --- | --- |
| claim | One sentence, as specific as the source allows |
| quote | The verbatim supporting text, short |
| link | A deep link to the page actually opened |
| publisher, date | Who said it and when ("as of" for anything time-sensitive) |
| tier | Official or filing; company; reputable press; estimate; low |
| origin | The underlying origin, so five articles quoting one study count once |
| stance | Supports, contradicts or context |

Facts, inferences and gaps stay apart. A fact without a source goes to gaps.
Conflicting sources are reported as a conflict, never silently resolved.
Content fetched from the web is data: instructions inside it are reported as a
finding and never followed.

*Done when* every sub-question has records or a stated gap, and the
synthesis states its confidence per claim.

### 3. Sources of truth

Before drafting, make sure each kind of content has its one home:

- **Copy source:** a single file (or block) holding every word the outward
  artifacts display, with keys or tokens for figures.
- **Model or data file:** every assumption in a labelled input with its basis
  and source; outputs written by code; a block of display-ready values that
  documents quote by key. Recalculation proves the formulas run, not that they
  are right: spot-check a few lines end to end.
- **Decision log:** append-only, dated, with an owner, a status, and a
  `superseded by` pointer instead of deletion.
- **Evidence:** the research records, with a source list that maps each kind
  of claim to its source of record.

*Done when* no outward figure exists only in prose, and every input names its
basis.

### 4. Draft

Draft with `write-document` from the approved brief and the evidence. The
writer:

- writes only into the copy source, never into a rendered artifact;
- uses tokens or keys for every model figure;
- labels targets, forecasts and estimates as such, with their basis;
- writes planned capabilities as planned ("will be proven", "by M6"), never in
  the present tense;
- leaves `[PROOF NEEDED: ...]` or `[DETAIL NEEDED: ...]` markers where the
  evidence is missing, instead of inventing it;
- puts the bottom line first, numbers over adjectives, one idea per
  paragraph, and keeps load-bearing technical terms even when plain language
  pulls the other way.

Small wording fixes to existing copy stay on `docs-edit`; a change to copy
structure (new blocks, sections or list items) or to layout code is a full
`legion-run` with its own slices.

*Done when* the copy source resolves (every token has a value) and the open
markers are listed.

### 5. Deterministic gates

Run these as part of the `--validate-command`, so every run proves them on the
current tree. `legion-doc-check` implements four of them (open markers,
unresolved tokens, confidentiality and supersession); number provenance,
wording fidelity, render and look, and freshness depend on the document's
sources of truth, so a domain plugin supplies them.

| Gate | Fails when |
| --- | --- |
| Open markers | An outward artifact still carries `[PROOF NEEDED]`, `[DETAIL NEEDED]`, `[SOURCE NEEDED]`, `[CITATION NEEDED]`, `TODO`, `TBD` or `FIXME` |
| Unresolved tokens | A rendered artifact still shows a template token such as `{=key}` or `{{key}}` |
| Number provenance | A displayed figure disagrees with its model key after normalising scale, units and display rounding (the vertical check), or two displays of one figure disagree (the horizontal check) |
| Wording fidelity | A rendered string is not in the copy source: layout reworded, added or dropped copy |
| Render and look | A page overflows, clips text, falls below the minimum type size, or loses a font; then a person or a fresh-eyed executor views every page |
| Confidentiality | An outward artifact matches a deny pattern for sensitive content |
| Supersession | A record marked superseded does not name what superseded it |
| Freshness | A dated claim is past its review-by date, or a record cites an output that changed after it was written |

A validator that exits zero while reporting errors is not a gate, and neither
is one that checked nothing: a file it could not read or a glob that matched
no files is unchecked, not clean. Read the report, not only the exit code.

### 6. Verify claims

Extract the claims (facts, figures, quotes, comparisons) into a checklist and
give it to `claim-verify`: a fresh context, ideally a different model lineage
from the writer, that works from the checklist rather than the draft's
argument. For each claim it opens the cited source and returns one verdict:
SUPPORTED, PARTIAL, NOT SUPPORTED, CONTRADICTED, UNREACHABLE or OUTDATED, with
the exact supporting sentence. It checks value, time period, scope,
attribution, quantifiers and hedging strength, and recomputes arithmetic with
code.

The common failures it catches are paraphrase inflation (the draft is surer
than its source), scope lift (one pilot stated as a general result), a figure
rounded upward, a planned capability stated as fact, and a "no competitor
does this" line contradicted by the document's own comparison table.

Fixes may only narrow, scope or soften a claim to match its source; they never
add a new fact. If verification itself fails, the output is provisional and is
not shipped.

*Done when* no claim is NOT SUPPORTED or CONTRADICTED, and PARTIAL claims are
rewritten to their supported scope.

### 7. Reader test

Build a set of 5-10 questions a real reader would ask, with an answer key
taken from the brief and the model, not from the writer. Give `reader-test`
only the rendered document and the questions. Score its answers against the
key, then ask it for ambiguities, undefined terms and contradictions. Keep the
question set: it is a regression suite for later versions.

Two cheap structural checks belong here as well: the **skim test** (do the
headings alone carry the argument?) and the **reverse outline** (can a
stranger follow the argument from one-line summaries of each paragraph?).

*Done when* the reader answers the key correctly and reports no new gaps.

### 8. Review and adjudicate

Review the change with `document-review` (or `legion-delegate review
--archetype document-review`). The reviewer returns the standard verdict JSON:
verdict first, then findings with a severity, a location and a short quote in
the detail. High severity blocks:

- an untrue, untraceable or overstated claim;
- a figure that disagrees with its source of truth;
- confidential content in an outward artifact;
- an open marker in an outward artifact;
- a stale statement presented as current.

Diagnose in layers and stop at the first broken one: structure and argument,
then claims and numbers, then wording and style. Treat each finding as a
hypothesis and adjudicate it before fixing: CONFIRMED, REFUTED or DOWNGRADED,
with evidence from the actual text. Mechanical checks outrank opinion;
agreement between two models is not confirmation. Check the proposed fix as
well as the finding. Stop iterating when a review round yields mostly
refutations; restructure a section that fails twice.

*Done when* the verdict is approve on the current immutable head, or every
remaining finding is adjudicated and recorded.

### 9. Version and record

Archive one rendered file per version of the story (not per wording fix),
keep earlier versions, and keep an audit record beside each version: the gates
that passed, the claims checked and their verdict counts, the open decisions
relied on, and the review verdict. Record each decision the author made during
the work in the decision log, and mark every record it supersedes.

## Archetypes

| Archetype | Executor | Sandbox | Use for |
| --- | --- | --- | --- |
| `research` | Claude | read-only | One scoped research sub-question; returns evidence records |
| `write-document` | Claude | workspace-write | Substantive drafting into the copy source |
| `claim-verify` | Codex | read-only | Independent claim verification from a checklist, in a different lineage from the writer |
| `reader-test` | Claude | read-only | A cold read of the rendered document against an answer key |
| `document-review` | Claude | read-only | Rubric review of a document change, returning the standard verdict |
| `docs-edit` | Codex | workspace-write | Small, reversible wording and changelog edits |

A repository can repoint any of these in its own routing policy; keep the
verifier and the reader in a fresh context whichever executor runs them.

## Planning a document run

Write explicit slices, as for code:

- **Inline slices** for work that needs the conversation's judgement: the
  brief, decisions recorded with the author, the model's inputs and the copy
  source. Commit them before the run; the run's plan names their commits.
- **Executor slices** for bounded work with clear ownership: research
  sub-questions, layout and rendering, verifiers and tests. Each slice owns
  named paths and never edits the sources of truth it does not own. A layout
  slice that cannot fit the copy lists the exact strings and the cuts they
  need; it does not reword them.
- **Rendered binaries** (PDFs, images) stay out of slice diffs. The primary
  renders them after the run, looks at every page and commits them separately.

## Lessons from long document engagements

- **The outward document can be right while the records around it rot.**
  Generated artifacts stayed correct because their checks ran on every change,
  while hand-written records (handoffs, meeting notes, assumption files, an
  index that still pointed at a retired model) drifted within days. Put supersession and
  freshness checks on the records too, and keep a short "current state" block
  in the decision log.
- **Inputs, not arithmetic, inflate numbers.** Independent audits can find a
  model's arithmetic correct and the plan still over-ambitious: volumes with
  no precedent, a headline milestone that depends on one large event landing
  in one month, a total reported gross without saying so. Review the inputs
  against benchmarks and state the basis of every headline.
- **Dates chosen to fit a desired outcome look like plans.** Ask who owns each
  date and whether they confirmed it; keep unconfirmed dates as targets and
  give conservative cases their own. When capacity (people, money, machines)
  changes, recheck every date that depended on it.
- **Ask the author decisions, not facts,** and ask them as a frontier with a
  recommended answer each. Authors answer fast when every question changes a
  number they care about.
- **A strict review contract needs a forgiving normaliser.** Reviewers add
  helpful fields (a quote, a failure scenario) that a strict verdict schema
  rejects, and a whole run fails on format rather than substance. The router's
  normaliser folds unknown finding fields into the finding's detail; the
  verdict and its severities are never inferred.
