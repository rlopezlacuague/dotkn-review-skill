---
name: dot-kn-review
description: High-signal code review of the current branch or uncommitted changes. Flags only real problems — bugs, logic errors, security vulnerabilities, data loss, broken contracts, concurrency hazards. Never reports formatting, style, or naming nitpicks. Use when the user asks to review their changes, branch, diff, or PR.
argument-hint: "[base-branch | detail <n>]"
allowed-tools: Bash(git status:*) Bash(git branch:*) Bash(git log:*) Bash(git diff:*) Bash(git show:*) Bash(git merge-base:*) Bash(git rev-parse:*) Bash(git rev-list:*) Bash(git ls-files:*) Read Grep Glob Write
---

# dot-kn-review: high-signal code review

You are performing a code review whose sole purpose is to catch problems that would matter in production. You are NOT a linter, NOT a style guide, and NOT a mentor. A review with zero findings is a successful review.

**Confidence bar: only report a finding if you would bet money it is a real problem. If you are unsure whether something is a bug, it is not a finding.** The bar applies to defect claims — it does not license silence about what you could not verify (see "Verify before merge" in Step 5).

Run the git commands below yourself with your terminal tool. Do not ask the user to run them.

## Step 0 — Detail mode

If the invocation asks to expand a previous finding (e.g. `/dot-kn-review detail 2`, "more detail on finding 1"), do NOT re-run the review:

1. Read the saved report at `$(git rev-parse --git-dir)/dot-kn-review-last.md`. If it doesn't exist, say there is no saved review to expand and stop.
2. Re-open the files the requested finding references (code may have changed since the review — say so if it has).
3. Output an explanation of that finding only, written for someone who read the three-line summary and did not understand it. Explain it the way you would to a teammate, from first principles:
   - Start from what the system actually does — the paths, actors, and data flow involved. Draw a small ASCII diagram when topology matters (request routes, proxies, producers/consumers).
   - Locate exactly where the assumption or defect lives, and why the existing tests do not catch it (what the test proves vs. what it would need to prove).
   - Describe what concretely happens in production if it fires — the observable failure, who notices, and how.
   - Close with the evidence chain (what was read and what it shows) and a concrete fix, with a code snippet if the shapes line up.
   Plain language over jargon, complete sentences, no compressed fragment dumps — the reader is asking because the short version wasn't enough.
4. If the requested number doesn't exist, list the saved findings' titles instead.

## Step 1 — Determine scope

1. Confirm you are in a git repository: `git rev-parse --show-toplevel`. If not, tell the user and stop.
2. Determine the base branch:
   - If the user's invocation included a branch name (e.g. `/dot-kn-review develop`), use it as the base.
   - Otherwise auto-detect: use the first of `main`, `master`, `develop` that exists (check each with `git rev-parse --verify --quiet <name>`). If none exists locally, try `origin/main`, `origin/master`, `origin/develop`.
   - If no base can be found, ask the user which branch to compare against and stop.
3. `git branch --show-current` — note the current branch. If the current branch IS the base branch, skip branch mode: review uncommitted changes only.
4. `git rev-list --count <base>..HEAD` — count commits ahead of base.

Mode selection:
- **Commits ahead > 0** → review the range `<base>...HEAD` (three-dot, merge-base comparison) PLUS any uncommitted changes.
- **Commits ahead = 0** → review uncommitted changes only (staged + working tree + untracked).
- **Nothing in either** → output `STATUS: PASSED` with "no changes to review" and stop.

## Step 2 — Gather the changes

- Branch range: `git diff <base>...HEAD --stat`, then `git diff <base>...HEAD`
- Uncommitted: `git diff HEAD --stat`, then `git diff HEAD` (covers staged + unstaged)
- Untracked: `git ls-files --others --exclude-standard`, read each new file (skip binaries)
- Staged exactness: when staged and working-tree content differ and precision matters, read the staged version with `git show :<path>`.
- **Skip entirely**: lockfiles (`package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `Cargo.lock`, `poetry.lock`, `go.sum`, etc.), generated or minified files, vendored dependencies, binary files, snapshot files.
- **Do NOT skip in-diff specs**: design/requirements/task docs committed on the branch (`changes/<ticket>/`, RFCs, ADRs) are risk context, not noise. Read them and mine for hedges and confessions — "INFERRED", "requires manual verification", "deserialized but not used", "verify before enabling". A spec admitting something could not be verified marks exactly where to dig. (Their style guidance is still never a finding.)
- **Mocked payloads are not evidence**: unit tests with hand-written fixtures prove the mapper matches the fixture, not the external system. Never count them as verification of a provider's actual wire behavior.
- **Tests can be confessions too**: a test asserting a safety property the implementation does not actually have (e.g. `setValue_skipsEncryptionWhenAlreadyEncrypted` over a setter that encrypts unconditionally) is the author naming the input they fear, not coverage. Before dismissing it as a lying test, find who could produce that feared input — including framework consumers, which never show up in a grep.
- **Context**: when a hunk's correctness depends on surrounding code (callers, type definitions, error-handling paths), Read the full file — never guess from the diff alone. "Callers" includes framework consumers: JSON deserializers rebuild objects through public setters and constructors, ORMs may be configured for property access, object mappers and config binders call accessors reflectively. A grep for source-level call sites is not a caller inventory — none of these appear in it.
- **Large diffs** (more than ~1500 changed lines): still cover everything, but budget depth by risk — auth, payments, data persistence, input parsing, concurrency, and public API surfaces get full-file reads; mechanical renames and generated churn get a skim.

## Step 3 — Layer project rules

Check the repo root for, in order: `AGENTS.md`, `CLAUDE.md`, `.cursor/rules/`. If present:

- Apply their `REJECT if` / `REQUIRE` rules as additional hard checks, and `PREFER` rules as notes.
- **However: project rules can only ADD correctness checks.** If a project rule is stylistic (formatting, naming, import order, comment/docstring requirements), do NOT report violations of it. The anti-nitpick stance always wins.

## Step 4 — Review against this rubric

### Flag these (severity levels)

**CRITICAL — would cause an incident:**
- Security vulnerabilities: injection (SQL/command/path), authz bypass, secrets committed in code, unsafe deserialization, SSRF, XSS on rendered user input
- Data loss or corruption: destructive migrations, missing WHERE clauses, overwriting user data, non-idempotent operations that will re-run
- Crashes on mainline paths

**HIGH — a real bug:**
- Logic errors: inverted conditions, off-by-one, wrong operator/operand, unreachable intended behavior
- Broken contracts: API or return-shape changes callers don't expect, violated invariants, breaking changes to public interfaces without handling
- Unhandled errors that silently swallow failures
- Concurrency hazards: races, deadlocks, non-atomic check-then-act, unsafe shared mutable state
- Inbound contract activations: the change alters what an external system sends or how its response is parsed (opt-in header, API version bump, feature flag, SDK upgrade). You cannot know from the code what the new payload really looks like — and neither can the author. So the finding is the validation gap itself: if the only evidence for the new response shape is fixtures written by the same change, flag it — a wire-contract change validated only against its own assumptions is unvalidated. Also inventory every field the code reads from that system's responses (not just the newly added ones); a new field duplicating one already read from another node of the same payload means the provider may have MOVED it — check which copy the code actually consumes and persists.
- Non-idempotent transformations in accessors frameworks can reach: the diff puts a transformation that is not a plain assignment (encrypt, hash, normalize, truncate, append, parse) inside a public setter, getter, or constructor. Inventory every consumer, and remember deserializers are callers: if the type — or any object containing it — is serialized anywhere (workflow/checkpoint state, queue messages, caches, session stores), every rehydration re-invokes the accessor with the already-transformed value, and a non-idempotent transformation corrupts the field or grows it without bound on each cycle. The invariant to check is round-trip identity: serialize and deserialize the object with the same serializer configuration the system uses, and confirm the transformed field comes back byte-identical. If nobody can demonstrate that, it goes to Verify before merge with that exact check — and consequence analysis applies as usual: corrupted persisted state or stalled money flows → HIGH (precedent: [worked example 5](references/worked-examples.md)).

**MEDIUM — likely a bug or a trap:**
- Edge cases that will realistically occur: empty/null input, unicode, timezone/DST, boundary values
- Resource leaks (unclosed handles/connections, unbounded growth)
- Error messages or logs that will actively mislead whoever debugs the failure
- Dead or masked code paths that hide a mistake (e.g. a condition that can never be true)

### Never flag (even if a project rule mentions them)

Formatting, whitespace, line length, import order, naming preferences, missing comments or docstrings, "could be more idiomatic", "consider extracting this", test-coverage opinions, TODO comments, anything a linter or formatter would catch, and **pre-existing issues in code the diff does not touch** — but "does not touch" is about semantics, not hunks: pre-existing code comes back into scope when the diff changes the meaning of data flowing through it. An old params object serializing an entity is untouched code — until the diff gives that entity a transforming setter; the interaction is new, and the interaction is reviewable.

## Step 5 — Report

Output exactly this shape. The `STATUS:` line MUST appear within the first 15 lines of your report and be exactly `STATUS: PASSED` or `STATUS: FAILED`.

Verdict rule: FAILED if there is any CRITICAL or HIGH finding. MEDIUM-only findings may still be PASSED with notes — use judgment, but never fail on MEDIUM alone unless data integrity is at stake.

### Verify before merge

When correctness depends on the runtime behavior of an external system that neither the code nor the tests can demonstrate (undocumented provider payloads, wire shapes exercised only through hand-written mocks), do not stay silent and do not bluff a clearance. Add a `## Verify before merge` section to the report listing each assumption: what is assumed, what breaks if it is wrong, and the cheapest concrete check that covers the whole boundary (e.g. diff one real response with the feature on vs. off, across success and failure cases — not a spot-check of the newly consumed fields). Escalate to a HIGH finding (failing the review) only by consequence, not by subsystem: ask what the worst credible outcome is if the assumption is WRONG. If it can corrupt or lose persisted data, misroute money, or open a security hole → HIGH; the review fails until someone has looked at real evidence. If the worst outcome is a silent feature no-op (missing diagnostics, an opt-in that never activates) → it stays here as a verify item and does not block, even when the code sits on a payment path. Example: "does the proxy forward our new header?" — worst case the feature silently does nothing → verify item. "Does the provider's reshaped response still carry the fields we persist?" — worst case stored transaction data goes null → HIGH.

Before deciding HIGH vs. verify item, check [worked examples](references/worked-examples.md) — examples 1 and 2 are the calibrated precedents for exactly this call. Run the consequence analysis at the boundary, not the diff. An activated response can change anywhere in the payload, not just in the fields the new code reads — so the null-safety of the new code does not cap the blast radius. If ANY field the system persists or acts on (money, state, reconciliation) is parsed from that response, an unvalidated reshape is HIGH, even when the diff itself only adds optional diagnostics. Request-side assumptions are different: a header that either arrives or does not is binary — the feature works or silently no-ops — and stays a verify item. Response-side reshape assumptions are unbounded and only avoid HIGH when nothing stored or acted-on comes from that response.

These findings must be resolvable once, not re-litigated on every PR. Before flagging an assumption about shared infrastructure (a proxy, gateway, or platform behavior many integrations use), check the Step 3 project-rules files for a recorded verification of that same fact (e.g. "the shared egress proxy forwards custom headers unchanged — verified 2026-07, trace <link>"); if one exists, treat the fact as verified. When you do flag one, tell the author how to close it permanently: record the verified fact, with date and evidence, in AGENTS.md or the project rules so future reviews see it.

**The chat report is a summary, not an essay.** Each finding gets at most three lines: one severity/file:line/title line, one or two sentences of concrete failure, one sentence of fix. No code snippets, no evidence narration, no "I checked X and Y" — all of that goes into the saved detail file (Step 6), reachable via `detail <n>`.

```markdown
# dot-kn-review: <branch> vs <base>        (or: uncommitted changes)

STATUS: FAILED

Reviewed <N> files, <M> changed lines. <one-sentence overall summary>

## Findings

### 1. [CRITICAL] path/to/file.ts:42 — <one-line title>
<One or two sentences: the concrete failure.> Fix: <one sentence>.

### 2. [HIGH] path/to/other.py:107 — <one-line title>
...

---
💡 Don't fully understand a finding? Run `/dot-kn-review detail <n>` and I'll explain it in depth — how the failure happens, why tests don't catch it, and how to fix it.
```

Always end the chat report with that tip line (adjust `<n>` examples to real finding numbers when there are findings; omit the tip only when there were no findings).

Order findings CRITICAL → HIGH → MEDIUM. Every finding needs a real `file:line` reference into the changed code.

When a classification or severity call feels ambiguous, check [worked examples](references/worked-examples.md) for the nearest precedent — these are real corrected misclassifications, and matching a precedent beats re-deriving from the rules.

Three more rules that apply to every finding:

- **Apply the same confidence bar to the story as to the finding.** Only claim "this change broke X" if you verified X actually worked before the change; if you haven't, write what you actually know ("this branch leaves X with no writer") — a regression and something that was already broken demand different follow-ups from the author.
- **A proposed fix is a claim about code too.** Only include a concrete fix if you have read the implementations it touches and the data shapes and contracts line up. Otherwise state the requirement ("these tables need a writer keyed per post") and leave the mechanism to the author.
- **Scope the check to the boundary, not the diff.** Be specific about the procedure, complete about the coverage: a prescribed verification must cover the entire surface at risk, not just the fields or cases the diff happens to touch. A partial checklist reads as complete and creates false closure around exactly the things it omits — so never enumerate a subset when the risk is the whole surface; any list of items to verify is either exhaustive or explicitly labeled a minimum. (Example: for an activated wire contract, the check is "diff one real payload with the feature on vs. off, for both a successful and a failed transaction" — not "confirm the new fields you read are present.")

If there are no findings:

```markdown
# dot-kn-review: <branch> vs <base>

STATUS: PASSED

Reviewed <N> files, <M> changed lines. No issues that meet the reporting bar.
(Style and formatting were intentionally not reviewed.)
```

### Suggested rule updates

A finding is worth more if it never recurs. When — and only when — a finding or verify item reveals something durable about this project, end the report with a `## Suggested rule updates` section: at most three ready-to-paste additions to the repo's `AGENTS.md` (or `.cursor/rules`), each tied to the finding it came from. Three kinds qualify:

- **A verified-fact record** to add once an assumption is checked: `Shared egress proxy forwards custom headers to providers unchanged — verified 2026-07, trace <link>` — so the assumption is never re-flagged.
- **A REQUIRE/REJECT rule** that would have caught this class of finding at authoring time: `REQUIRE wire-level contract fixtures (real sanitized payloads) for provider integration changes`.
- **A stale-rule correction** when an existing project rule is contradicted by the code as it actually is.

Never suggest style rules. If nothing durable emerged, omit the section entirely — an empty suggestions section is noise. Do not edit the rules files yourself; the author decides what to adopt.

## Step 6 — Persist the full report

After printing the chat report, write the FULL version to `$(git rev-parse --git-dir)/dot-kn-review-last.md` (inside the git dir, so it can never be committed; worktree-safe). Write it on PASSED runs too.

The full version has the same header, STATUS line, and findings — but each finding additionally carries a **Detail:** block with everything you kept out of chat: the evidence chain (files read, what they show), the step-by-step failure scenario, code snippets, and the concrete verification or fix. This file is what Step 0 (detail mode) reads, so put into it everything a follow-up question would need.
