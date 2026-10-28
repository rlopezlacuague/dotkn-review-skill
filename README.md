# dot-kn-review

A high-signal code-review skill for **Claude Code** and **Cursor**. Run `/dot-kn-review` on a branch (or on uncommitted changes) and get back only the findings that matter: bugs, logic errors, security vulnerabilities, data loss, broken contracts, concurrency hazards.

**It will never nag you about formatting, import order, naming, missing docstrings, or anything a linter would catch.** A review with zero findings is a successful review — the skill is explicitly instructed that unsure ≠ finding.

Inspired by (and preserving the output contract of) [gentleman-guardian-angel](https://github.com/Gentleman-Programming/gentleman-guardian-angel), minus the provider plumbing: your editor's agent *is* the model, so the whole thing is one portable `SKILL.md` following the open [Agent Skills](https://agentskills.io) standard that both tools read.

## Install

```bash
git clone https://github.com/rlopezlacuague/dotkn-review-skill.git && cd dotkn-review-skill
./install.sh              # installs to ~/.claude/skills and ~/.cursor/skills
```

Options:

```
./install.sh --claude             # Claude Code only
./install.sh --cursor             # Cursor only
./install.sh --project <path>     # into a repo's .claude/skills + .cursor/skills
                                  # (version it with the project, share with the team)
```

Note: Cursor also reads `~/.claude/skills/` as a compatibility path, so `--claude` alone usually covers both tools. If Cursor lists the skill twice, uninstall one copy (`./uninstall.sh` then `./install.sh --claude`).

Uninstall with `./uninstall.sh` (or `./uninstall.sh --project <path>`).

## Usage

Standing on a branch with code changes, in Claude Code or Cursor agent chat:

```
/dot-kn-review                 # auto-detects base (main > master > develop)
/dot-kn-review develop         # explicit base branch
/dot-kn-review detail 2        # expand finding #2 from the last review (no re-run)
```

What it reviews, auto-detected:

- Branch ahead of base → the full range `<base>...HEAD` **plus** any uncommitted changes
- No commits ahead (or you're on the base branch) → uncommitted changes only (staged + working tree + untracked)

## Output

The chat report is deliberately short — three lines per finding:

```markdown
# dot-kn-review: feature/checkout vs main

STATUS: FAILED

Reviewed 7 files, 412 changed lines. Two real bugs in the payment path; everything else is sound.

## Findings

### 1. [CRITICAL] src/db/orders.ts:88 — SQL built by string interpolation
`orderId` comes straight from the request; a crafted id reads arbitrary rows. Fix: use the parameterized query API.

### 2. [HIGH] src/auth/guard.ts:31 — inverted admin check
`if (!isAdmin)` grants access to non-admins on the settings route. Fix: drop the negation and add a 403 test.

---
💡 Don't fully understand a finding? Run `/dot-kn-review detail <n>` and I'll explain it in depth.
```

The full report (evidence chain, failure walkthroughs, code snippets) is saved to `<git-dir>/dot-kn-review-last.md` — inside `.git`, so it can never be committed. `/dot-kn-review detail <n>` reads it and expands one finding without re-running the review.

### The STATUS contract

The report always contains `STATUS: PASSED` or `STATUS: FAILED` within its first 15 lines — the same machine-readable contract as gentleman-guardian-angel, so you can grep the verdict from a saved report or wire it into a gate later:

- **FAILED** — at least one CRITICAL or HIGH finding
- **PASSED** — clean, or MEDIUM-only notes

## CI gate

Interactively, `STATUS: FAILED` is advisory — nothing stops a merge. To make it blocking, run the review headlessly in CI and fail the pipeline unless the verdict is PASSED. Install the skill into the repo once (`./install.sh --project <repo>` and commit `.claude/skills/dot-kn-review/`), then:

```yaml
# .github/workflows/dot-kn-review.yml
name: dot-kn-review
on: pull_request

jobs:
  review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0        # the review needs the base branch for base...HEAD

      - name: Install Claude Code
        run: npm install -g @anthropic-ai/claude-code

      - name: Run review and gate on STATUS
        env:
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
        run: |
          claude -p "/dot-kn-review origin/${{ github.base_ref }}" \
            --allowedTools "Bash(git:*)" "Read" "Grep" "Glob" "Write" \
            | tee review.md
          head -15 review.md | grep -q "STATUS: PASSED"
```

The last line is the entire gate: the verdict must appear as `STATUS: PASSED` within the first 15 lines of the report, matched by substring — the same contract gentleman-guardian-angel uses, so any runner (Cursor CLI: `cursor-agent -p "/dot-kn-review origin/main" --trust`, a pre-push hook, another CI system) can gate the same way. `tee review.md` keeps the full report as a build artifact for the humans reading the failure.

## Project rules

If the target repo has an `AGENTS.md`, `CLAUDE.md`, or `.cursor/rules/`, their `REJECT if` / `REQUIRE` rules are applied as additional hard checks. Stylistic project rules are deliberately **not** enforced — the anti-nitpick stance always wins.

Project rules are also where **verified infrastructure facts** live. When the review flags an assumption about shared infrastructure (e.g. "does the shared egress proxy forward custom headers?"), verify it once and record the answer with date and evidence in `AGENTS.md` — future reviews treat it as settled instead of re-flagging it on every integration change.

The review also helps the rules improve over time: when a finding reveals something durable (an infrastructure fact worth recording, a missing `REQUIRE`/`REJECT` rule that would have caught this class of bug at authoring time, or an existing rule the code contradicts), the report ends with a `## Suggested rule updates` section containing ready-to-paste additions — never applied automatically, never style rules, omitted entirely when there's nothing worth saying.

## Layout

```
skills/dot-kn-review/SKILL.md                       # the entire product (portable Agent Skills format)
skills/dot-kn-review/references/worked-examples.md  # classification precedents the skill consults
install.sh / uninstall.sh
CURSOR_SKILL_DESIGN.md                              # original design/analysis notes (GGA → skill port)
```

## License

[MIT](LICENSE)
