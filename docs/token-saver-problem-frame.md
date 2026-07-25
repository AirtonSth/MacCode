# Token Saver — problem frame (Fase -2 / task-01)

**Status:** sealed for T-012 series
**Schema version:** `1`
**Baseline:** `production` / plan T-012 rev. 12
**Gate:** incomplete owners or cohort below floor → **STOP** (no-change / wrappers only; no new mutative lanes)

This document freezes the user problem, measurement denominators, owners, no-go list, and STOP rule **before** census, probe, or replacement work (tasks 02+).

---

## 1. User problem (testable)

RemoteCode agent turns send large, repeated, and structured tool/context payloads to Claude, Codex, and Grok. Users pay avoidable **provider input cost**, hit **quota / rate limits** attributable to input size, and lose task success under **context pressure** (truncation, forced summarization, or failed continuation). Token Saver must reduce **provider-visible input** (and, only when measured, avoided full provider rounds) without trading accuracy, recovery, security, or user trust for a larger dashboard number.

Primary outcome for this series:

| Field | Value |
|-------|--------|
| Primary outcome | Avoidable provider **input tokens** (and paired **provider rounds** when a trajectory experiment exists) on same-user agent-app turns |
| Secondary outcomes | Rate-limit / quota incidents attributable to input; context-pressure task failures |
| Non-outcomes | Character-count savings; local CPU/bytes; unproven upstream % claims; output truncation via hard caps |

---

## 2. Cohort, denominator, floors

### Cohort

- **In:** same-user agent-app provider turns (Claude / Codex / Grok) where Token Saver is eligible under project admission; tool results and host-owned projections only.
- **Out:** cross-user runs (Token Saver raw-only); non-agent surfaces; turns with Token Saver opted out / kill switch / retention zero for lossy paths.

### Denominators (pre-registered; formulas stay separate)

1. **API cost cohort** — sum of provider-reported input tokens on eligible same-user turns in the measurement window.
2. **Subscription / quota cohort** — count of quota or rate-limit events with evidence that input size contributed (joined attempt IDs).
3. **Context-pressure cohort** — count of turns that fail or degrade with provider context-limit / pressure signals.

Context relief **without** validated willingness-to-pay or productivity endpoint does **not** receive a monetary value in gates.

### Incidence minimum (floor)

A BindingID (or pre-BindingID shape key during task-01 only as documentation) advances past “measure only” only if, in the sealed census window, **all** of the following hold:

1. **Absolute volume:** `eligibleTokens > 0` (top rank with zero absolute eligible tokens **does not pass**).
2. **Observation count:** ≥ **30** independent eligible observations.
3. **Token share:** absolute eligible token volume ≥ **1%** of the API-cost cohort denominator for that provider+shape (`denominatorTokens > 0`).

This is the **stricter** (AND) freeze of the two thresholds, plus a non-zero absolute volume requirement. Machine-readable mirror: `TokenSaverProblemFrame.cohortMeetsFloor`.

### Minimum useful improvement (MDE)

- **API cost:** ≥ **5%** relative reduction in provider input tokens on paired treatment/control for the BindingID, with one-sided confidence bound above zero after multiplicity rules (task-05).
- **Quota:** ≥ **20%** relative reduction in attributable quota/rate-limit events, or absolute drop that clears the pre-registered bound.
- **Context pressure:** non-inferior task success within Δ (task-05); monetary value only if WTP/productivity endpoint is later validated.

If the sealed experiment is **INCONCLUSIVE**, treat as **STOP** (not soft-GO).

---

## 3. Owners receipt (required)

Promotion and new mutative lanes require all five roles named. Empty field ⇒ gate closed (blocks task-03+ promotion path and ReleaseGate in later tasks).

| Role | Owner (name or team handle) | Contact / on-call |
|------|-----------------------------|-------------------|
| Decision owner | RemoteCode Product (Token Saver) | product@remotecode.local |
| Runtime owner | Agent Runtime / Distill | runtime@remotecode.local |
| Data / accounting owner | Token Saver Ledger | accounting@remotecode.local |
| Security / privacy approver | Security & Privacy | security@remotecode.local |
| Release / on-call / rollback owner | Release Engineering | release-oncall@remotecode.local |

Machine-readable mirror: `TokenSaverProblemFrame.sealedOwners` in `Sources/DistillCore/TokenSaverProblemFrame.swift` (tested).

---

## 4. No-go freeze (immutable for this series)

The following are **out of plan** and must not ship as Token Saver “savings” mechanisms without a new RFC + council:

1. Cross-user hook or sidecar credential / Token Saver active under different UID
2. Truncating caps for Claude/Codex (hard max that drops content without recovery handles)
3. Provider HTTP proxy
4. Python, Rust, external Headroom/Tura runtime, or new ONNX dependency for Token Saver
5. Persistent config writes under `~/.claude` or `~/.codex`
6. Semantic response cache for mutable answers
7. Automatic writes to AGENTS/CLAUDE as learned instructions
8. Automatic lowering of user-selected reasoning / effort
9. SessionLearn free-text auto-instructions (typed+consented path remains OFF until its own gate)
10. Billing/headline “tokens saved” from character counts alone

PR checklist (copy into every Token Saver PR):

- [ ] No cross-user Token Saver activation
- [ ] No truncating provider caps
- [ ] No HTTP provider proxy
- [ ] No Python/Rust/ONNX/Headroom-Tura runtime
- [ ] No `~/.claude` / `~/.codex` mutation
- [ ] No semantic response cache / auto-learn / effort auto-lower
- [ ] Fail-open preserved
- [ ] Savings claims only with provider usage + accounting states

---

## 5. STOP rule

**STOP → no-change / wrappers only** when any of:

- Cohort below incidence floor
- Owners receipt incomplete
- Experiment INCONCLUSIVE or non-inferiority fails
- Security / recovery / capacity breach
- Coverage manifest cell missing/stale/skipped

STOP does **not** authorize “try promotion anyway in shadow UI as Active.”

---

## 6. What this task does **not** change

- No compression / replacement path behavior
- No census instrumentation
- No BindingID promotion
- No dashboard confirmed savings

Defaults remain shadow / measuring / OFF for mutative lanes.

---

## 7. Traceability

- Plan: `plan/token-saver-agent-app.html` (§1 decision, §3 phases, §10 verification)
- Task: `plan/tasks/task-01.html`
- Series index: `plan/tasks/index.html`
- Related ops: `docs/token-saver-t003-operations.md`
