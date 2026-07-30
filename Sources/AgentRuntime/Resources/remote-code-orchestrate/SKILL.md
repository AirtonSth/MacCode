---
name: remote-code-orchestrate
description: "Coordinate complex work as a controller-only orchestrator using cost- and risk-aware capability routing, explicit task dependencies and ownership, skeptical proof verification, and an independent review gate. Use when Auto routing is on or the user asks for delegated multi-agent delivery."
---

# Remote Code Orchestrate

Coordinate execution without implementing task artifacts directly. Route work by
capability and risk, then bind each delegated node to the active host’s fixed
runtime matrix (Codex, Claude Code, or Grok). Remain stack-neutral outside that
matrix.

**Token posture:** thin controller, fat workers, progressive disclosure, cheap
proof, selective review. Spend tokens on verification of artifacts — not on
re-reading this skill or re-prompting full history into every worker.

**Host Token Saver inheritance:** nested workers inherit the host-provided
`RC_TOKEN_SAVER_EXECUTION_RECEIPT_V1` and its provider-neutral capability/lane
environment. Workers never reconstruct or widen admission, disabled lanes,
Graphify, Distill, recovery scope, or provider attribution. Missing, malformed,
denied, cross-user, or mismatched receipts remain raw. Prompts, transcripts,
tool output, and secrets never enter the receipt; Skills and exact-output
commands remain lossless.

**Use the Agent App middleware for controlled provider workers.** When a worker
contract can run as a normal Agent App turn, launch it with
`remote-code agent-app <codex|claude|grok> --prompt-file <path>` (plus the
required workspace/model/permission/reasoning flags). This creates a real Agent App thread, so the
child uses the same admitted prompt processing, recovery, eligible command
output lanes, provider-usage accounting, and live Token Saver refresh as a
user-started thread. The command is installed beside RemoteCode's own service;
do not install a proxy server, SDK, Python, Rust, or another provider runtime.

Bare `grok`, `claude`, or `codex` names still resolve through the host-managed
PATH controller (`~/.remote-code/bin`). The exact `sam-grok-worker` one-shot
contract (Grok 4.5, prompt file, permitted effort, JSON output, workspace
sandbox, always approve, and its memory/subagent/tool/update guards) is upgraded
automatically to `remote-code agent-app grok`. Its stdout remains a JSON object
with the worker report in `text`, while the real Agent App thread/run owns
persistence, Token Saver processing, provider usage, and the live Subagents UI.
Any missing, duplicated, aliased, reordered-with-unknown, or additional CLI
member fails closed to the raw Grok ABI instead of receiving a partial rewrite.
Other explicit provider CLI contracts remain raw: RemoteCode keeps their
provider/output ABI, records supported lifecycle and provider-usage telemetry,
and adds documented runtime-guidance options only for recognized provider
turns. That raw path does not provide Agent App persistence or prompt
compression, and telemetry alone is not evidence of token savings. Keep
specialized read-only/tool-allowlisted contracts raw when the Agent App flags
cannot express the same boundary. Skills must not invent or widen Token Saver
admission.

Provider-native collaboration whose child prompt is hidden inside a provider
SDK cannot be rewritten by a Skill. RemoteCode records its live lifecycle and
provider-reported usage when available, while eligible shell output continues
to inherit the parent's admitted runtime. Never label a lifecycle-only child as
measured savings.

For controlled nested workers that are **not** a bare provider CLI (custom
scripts, non-provider tools), use the provider-neutral telemetry command around
the actual lifetime: `${REMOTE_CODE_SUBAGENT_TELEMETRY_COMMAND:-distill}
subagent begin --node <stable-id>` before spawn and the matching `subagent end
--run-id <id> --status <completed|failed|cancelled>` on terminal exit. The app
sets `REMOTE_CODE_SUBAGENT_TELEMETRY_COMMAND` to its co-located service even
when Token Saver is off, so telemetry does not depend on an optimization lane.
The bridge is provider-neutral and receipt-bound; if it is unavailable, keep the
worker raw and report that the Subagents row is unproven.

## Non-Negotiable Contract

- Keep the main agent controller-only. Delegate production code, tests,
  documentation, migrations, and other task artifacts.
- Permit direct main-agent work only for task decomposition, agent coordination,
  result inspection, proof reruns, conflict integration, and final reporting.
- Give every worker one explicit owner boundary, writable scope, no-go scope,
  dependencies, pass criteria, required proof, and a bound runtime receipt.
- Tell every worker that other agents may share the workspace and that it must
  not revert or overwrite unrelated work.
- Distill applies only to eligible ordinary tool/command output when Token Saver
  is active. Never Distill skill content: requested/returned skill bodies must
  stay complete. Do not require every worker prompt to restate Distill rules
  (host/runtime carries the ordinary-output policy).
- Treat every returned claim as unverified until the controller checks its
  artifact, scope, and proof (diff vs writable paths; one real TARGET proof).
- Select capability by task risk first. Bind model/effort only from
  [references/host-runtime-matrix.md](references/host-runtime-matrix.md) for the
  active host. Never invent models, never ask the user which model to pick, and
  never put model or host names into owner IDs.
- **Cheap-first:** never open on `DEEP` or `genius_worker`. Escalate only after
  concrete capability failure or new risk evidence — never because a task is large.
- If delegation is unavailable, stop before execution and report the exact
  blocker. Do not silently abandon controller-only mode.
- Never expose secrets in prompts, reports, commands, or evidence.

## Orchestration bypass (Micro chat) — decide first

**Before** any DAG, worker, tool fan-out, matrix load, or validator:

If the user request is **purely conversational** and does **not** ask for code,
files, commands, PRs, deploys, refactors, or any repo change — answer **directly
on the controller in one short reply**.

Examples that **bypass orchestration** (class `T0`, certainty `absolute`, mode
Micro chat):

- Identity / host: “quem é você?”, “who are you?”, “what model?”, “que LLM é?”
- Greeting / ack: “oi”, “olá”, “thanks”, “obrigado”
- Trivial status: “você está aí?”, “ping”, “status?”

**Do not:**

- Delegate or spawn subagents
- Build a task DAG or orchestration table theater
- Load [host-runtime-matrix.md](references/host-runtime-matrix.md),
  [output-contract.md](references/output-contract.md), or run the validator
- Run tools unless a single read is strictly required to answer (usually none)
- Claim a different host than the host runtime receipt

**Do:** answer from the host receipt + this session; stop.

If the message mixes chat with a real task (“who are you, and fix the bug”),
**do not** bypass — classify and orchestrate the real work.

## Progressive Disclosure (read only what you need)

Do **not** load every reference on every turn.

| Path | Read now | Defer |
| --- | --- | --- |
| **Micro chat** (bypass above) | This section only | everything else |
| **Micro** (`T0` + certainty `absolute`/`high`) | This SKILL (this section + §1 micro) | matrix full tables, output-contract, validator until report |
| **Single** (`T1`) | + [routing-policy.md](references/routing-policy.md) + [prompt-contract.md](references/prompt-contract.md) | full output-contract until drafting report |
| **Multi** (`T2`) | + [host-runtime-matrix.md](references/host-runtime-matrix.md) | — |
| **Critical** (`T3`) | + [output-contract.md](references/output-contract.md) + contract review | optional formal validator |

RemoteCode orchestration must remain functional without Python or another
unbundled runtime. When you produce report JSON (Single/Multi/Critical), review
it against [output-contract.md](references/output-contract.md) before declaring
completion. The packaged Python validator is an optional development check only
when the current environment already provides a compatible runtime; its absence
does not block the core orchestration. Micro chat bypass: no report.

## Certainty Budget

Record `task.controller_certainty` as one of: `absolute` | `high` | `medium` |
`low`.

| Certainty | Meaning | Orchestration shape |
| --- | --- | --- |
| `absolute` | Zero residual doubt on scope, risk, ownership, proof | Micro path only (`T0`) |
| `high` | Clear single-slice work; ordinary residual risk only | Micro or Single |
| `medium` | Normal ambiguity or multi-touch | Single or Multi |
| `low` | Unclear ownership, risk, or proof path | Multi or Critical; do not skip review |

Never invent `absolute`/`high` to save cost.

## Orchestration Modes (T0–T3)

| Mode | When | Shape |
| --- | --- | --- |
| **Micro** | `T0` and certainty `absolute` or `high` | No subagent required; optional one `LIGHT` worker; **no REVIEWER** if absolute-certainty (or high) skip rules hold; no formal DAG theater |
| **Single** | `T1` | One `STANDARD` worker (or `LIGHT` if purely mechanical); review only if triggers fire and skip rules fail |
| **Multi** | `T2` | Minimum independent workers (default parallel **2**, hard cap **3**); one integration owner; review when multi-producer or risk |
| **Critical** | `T3` | `DEEP` only on the risky slice; serialize unsafe writes; **REVIEWER required** |

Parallel fan-out: default max **2** concurrent execution workers; hard cap **3**.
Split only on real ownership/dependency boundaries — never to increase agent count.

## 1. Freeze Goal and Constraints

Record before delegation:

- Goal and observable success criteria.
- Explicit constraints and no-go surfaces.
- Certainty budget (`absolute`/`high`/`medium`/`low`).
- Risk flags, expected artifact classes, empty changed-file manifest.
- User decisions that must not be inferred.

Classify `T0`–`T3` per [routing-policy.md](references/routing-policy.md). Pick the
**cheapest** mode that still preserves evidence quality.

### Micro path (token-efficient)

When mode is Micro:

0. **Micro chat bypass first** (see § Orchestration bypass): if the request is
   only conversational (identity, greeting, status) and asks for no repo work →
   answer on the controller and stop. No workers, DAG, tools, or validator.
1. Do the work yourself only if it is pure controller integration; otherwise one
   short `LIGHT` worker with a **slice-only** prompt (see prompt-contract).
2. Proof: scope diff + at most one focused command. No full-suite runs. No raw
   log dumps — summary + failing excerpt only.
3. Skip REVIEWER when absolute/high certainty skip rules hold.
4. Report: one table row (node / model / proof / status) or a minimal validated
   JSON report. No narrative essay. Micro chat: no report.

## 2. Build the Task DAG (Single / Multi / Critical)

Create the **smallest** useful DAG. Each node must contain:

- Stable task ID and kind: `EXECUTION`, `ORCHESTRATION`, or `REVIEW`.
- Neutral owner ID and capability: `LIGHT`, `STANDARD`, `DEEP`, or `REVIEWER`.
- Runtime binding for every delegated `EXECUTION` and `REVIEW` node.
- Dependencies, one objective, no-go, proof requirements.
- Writable paths or explicitly read-only scope; artifact classes.
- Status, blocker provenance, evidence IDs.

Owner IDs: `worker-N`, `controller-N`, `reviewer-N` only.

Caps by class: `T0`/`T1` → at most **1** execution producer; `T2`/`T3` → at most
**3** execution producers.

`DEEP` only when classification is `T3` or `risk_flags` is non-empty. Prefer a
better `LIGHT`/`STANDARD` re-prompt over escalating model tier.

## 3. Bind Runtime and Delegate

Use the **host runtime receipt** from RemoteCode when present (`active_host`,
`provider`, `controller_model`). It is authoritative — do not re-detect or claim
another host. If absent, detect host once (`codex`, `claude-code`, `grok`). Bind
matrix rows from [host-runtime-matrix.md](references/host-runtime-matrix.md).

| Capability | Codex | Claude Code | Grok |
| --- | --- | --- | --- |
| `LIGHT` | `gpt-5.6-luna` / `medium` | `haiku` / `high` | `grok-4.5` / `medium` |
| `STANDARD` | `gpt-5.6-luna` / `xhigh` | `sonnet` / `high` | `grok-4.5` / `medium` |
| `DEEP` | `gpt-5.6-luna` / `max` | `opus` / `medium` | `grok-4.5` / `medium` |
| rare escalate | `gpt-5.6-sol` / `high` | `opus` / `xhigh` | `grok-4.5` / `high` |
| `REVIEWER` | `gpt-5.6-sol` / `medium` | `opus` / `high` | `grok-4.5` / `high` |

Worker prompts: [prompt-contract.md](references/prompt-contract.md) — **slice-only**,
no full skill paste, no other workers’ conclusions into independent review.

## 4. Track and Reconcile (cheap skepticism)

1. Track node state; prevent overlapping writes without a dependency edge.
2. Reconcile every changed file to one producer + artifact class.
3. **Before accepting claims:** check diff ⊆ writable_paths; require one real
   TARGET proof per proof requirement.
4. Prefer re-running the smallest proof over re-reading whole transcripts.
5. Reject unrelated changes and unsupported completion claims.
6. Escalate capability only after capability failure or new risk evidence.
7. Stop for required user decisions that expand scope.

## 5. Review Gate

### Require REVIEWER when

- Classification `T3`, or non-empty `risk_flags`, or `DATA`/`RELEASE` artifacts.
- More than one execution producer.
- TARGET proof missing or not `PASS`.
- User set `review_requested: true`.
- `CODE`/`TEST` changed **and** certainty skip does not apply.

### Certainty skip (no REVIEWER)

| | Absolute | High |
| --- | --- | --- |
| Class | `T0` only | `T0` or `T1` |
| Producers | 1 | 1 |
| Capability | any allowed | `LIGHT` or `STANDARD` only |
| risk_flags | empty | empty |
| TARGET proof | all PASS | all PASS |
| review_requested | false | false |
| Record | `controller_certainty: "absolute"` | `controller_certainty: "high"` |
| Gate reason | `micro_task_absolute_certainty` | `micro_task_high_certainty` |

### Reviewer efficiency

- Read-only; distinct neutral owner; after all producers.
- Feed **combined diff/artifact + checklist + frozen scope + proof IDs** — not
  this entire SKILL and not expected findings.
- Dedicated TARGET/`PASS` proof for the review node.
- Corrections → re-gate until pass or concrete blocker.

When skip applies or no trigger fires: `NOT_REQUIRED` + exact reason.

## 6. Validate Completion

For Single/Multi/Critical (and any Micro that wrote a report), write JSON per
[output-contract.md](references/output-contract.md) and review the required
schema, DAG, proof, manifest, and decision invariants there. This core path must
not call or install Python, Rust, an SDK, or another provider runtime.

`scripts/validate_orchestration.py` remains an optional development validator
for environments that already provide its runtime. Do not install a dependency
to run it and do not treat its unavailability as an orchestration failure. When
used, report `PASS` or its exact errors and remove temporary artifacts.

`COMPLETE` only when DAG + review gate satisfy the contract, every completed
producer has dedicated TARGET/`PASS` proof, manifest reconciles, and no required
correction remains. `BLOCKED` only with evidence-backed external/authority/
user-decision/dependency provenance. Else `IN_PROGRESS`.

## 7. Report (lean)

Return a **table**, not an essay:

| Field | Content |
| --- | --- |
| Class / certainty / mode | `T*`, certainty, micro/single/multi/critical |
| Nodes | id · capability · model · effort · status |
| Manifest | path · class · producer |
| Proof | id · requirement · PASS/FAIL |
| Review | required? reason / skip reason |
| Decision | COMPLETE / BLOCKED / IN_PROGRESS + remaining IDs |

Do not repeat unverified agent claims. Do not dump raw logs.
