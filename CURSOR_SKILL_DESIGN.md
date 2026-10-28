# GGA → Cursor Skill: Analysis & Port Design

Reference document for porting [`gentleman-guardian-angel`](https://github.com/Gentleman-Programming/gentleman-guardian-angel) (GGA) — a provider-agnostic AI code-review pre-commit tool — into a **custom Cursor skill** that performs the same workflow inside the Cursor editor / CLI.

This is a planning document. No code yet. It captures *how GGA works* in enough detail that a future implementation pass can be done deterministically, and lays out the design space for the Cursor port.

---

## 1. What GGA Does (in one paragraph)

GGA is a ~1,200-line Bash CLI (`bin/gga`) that hooks into `git commit` (or runs in CI / PR mode). On every commit it: (a) finds the files about to be committed, (b) reads a project-local rules file (`AGENTS.md`), (c) builds a single combined prompt of `rules + file contents`, (d) sends it to a configurable AI provider CLI (Claude, Gemini, Codex, OpenCode, Ollama, LM Studio, GitHub Models), (e) requires the model to answer with a literal `STATUS: PASSED` or `STATUS: FAILED` line, (f) on `PASSED` lets the commit through and caches file hashes so unchanged files are skipped next time, and on `FAILED` blocks the commit and prints the violations. There is zero language runtime — pure Bash + git + the chosen provider CLI.

---

## 2. Repo Layout

```
gentleman-guardian-angel/
├── bin/gga                    # CLI entry point (subcommand dispatcher + main run flow)
├── lib/
│   ├── providers.sh           # 7 provider adapters + timeout wrapper
│   ├── cache.sh               # Per-project SHA-256 content cache
│   └── pr_mode.sh             # Base-branch detection, PR range, PR prompt builder
├── install.sh / uninstall.sh  # Copies bin+lib into ~/.local/bin and ~/.local/share/gga
├── Makefile                   # test / lint / docker targets (shellspec + shellcheck)
├── spec/                      # shellspec unit + integration tests (~266 tests)
├── skills/                    # 6 internal "agent skills" used by humans + AIs working *on* GGA
│   ├── branch-pr/SKILL.md     # Conventional branch + PR conventions
│   ├── commit-hygiene/SKILL.md
│   ├── docs-alignment/SKILL.md
│   ├── issue-creation/SKILL.md
│   ├── shellcheck-standards/SKILL.md
│   └── testing-coverage/SKILL.md
├── AGENTS.md                  # Index pointing at the skills/ above
└── docs/                      # User docs (configuration, providers, caching, integrations, etc.)
```

Note: `skills/` here is GGA's own contributor docs — *not* the same notion as a Cursor skill. They're useful as a template, though.

---

## 3. Core Run Flow (`bin/gga` → `cmd_run`)

```
git commit (or `gga run`)
   │
   ▼
┌─────────────────────────────────────────────────────────────┐
│ 1. Parse flags: --no-cache, --ci, --pr-mode, --diff-only,   │
│    [commit-msg-file]                                         │
├─────────────────────────────────────────────────────────────┤
│ 2. load_config():                                            │
│    a. Defaults                                               │
│    b. Source global ~/.config/gga/config                     │
│    c. Source project ./.gga                                  │
│    d. Apply env: GGA_PROVIDER, GGA_TIMEOUT                   │
├─────────────────────────────────────────────────────────────┤
│ 3. validate_provider(PROVIDER) — CLI installed?              │
├─────────────────────────────────────────────────────────────┤
│ 4. Verify RULES_FILE (default AGENTS.md) exists              │
├─────────────────────────────────────────────────────────────┤
│ 5. Get file list (mode-dependent — see §4)                   │
│    Filter by FILE_PATTERNS (include) / EXCLUDE_PATTERNS      │
├─────────────────────────────────────────────────────────────┤
│ 6. Cache pass (only in normal mode):                         │
│    - Hash AGENTS.md + .gga → invalidate all if changed       │
│    - For each file: if hash exists with status PASSED, skip  │
├─────────────────────────────────────────────────────────────┤
│ 7. Build prompt (see §5):                                    │
│    - Rules block                                             │
│    - Optional commit-msg block                               │
│    - File contents (staged via `git show :path` in normal    │
│      mode; working-tree `cat` in --ci / --pr-mode)           │
│    - STATUS sentinel instructions                            │
├─────────────────────────────────────────────────────────────┤
│ 8. execute_provider_with_timeout($PROVIDER, $PROMPT, $TIMEOUT)│
│    - Spawns command in background, polls every 0.1s (TTY)   │
│      or 1s (non-TTY) with spinner / 30s heartbeat            │
│    - Exit 124 on timeout, otherwise propagates child status  │
├─────────────────────────────────────────────────────────────┤
│ 9. Parse output:                                             │
│    grep "STATUS: PASSED|FAILED" in first 15 lines of stdout  │
│    - PASSED → cache hashes, exit 0                           │
│    - FAILED → exit 1                                         │
│    - Neither → STRICT_MODE=true → exit 1 / false → exit 0    │
└─────────────────────────────────────────────────────────────┘
```

---

## 4. The Three Modes (file-selection logic)

| Mode | Trigger | `git` command used | File source for prompt | Cache |
|---|---|---|---|---|
| **Normal (pre-commit)** | default | `git diff --cached --name-only --diff-filter=ACM` | `git show :path` (staging area — *not* working tree) | ✅ on |
| **CI** | `--ci` | `git diff --name-only --diff-filter=ACM HEAD~1..HEAD` (overridable via `GGA_CI_SOURCE_COMMIT`) | `cat path` (working tree, file is already committed) | ❌ off |
| **PR** | `--pr-mode` | `git diff --name-only --diff-filter=ACM <base>...HEAD` (base = `PR_BASE_BRANCH` or auto-detect `main`/`master`/`develop`) | `cat path`; if `--diff-only`, also includes `git diff <range>` content | ❌ off |

Filename filtering is a hand-rolled glob: `*.suffix` → suffix match (`[[ "$file" == *"$suffix" ]]`), exact match, or basename match. Comma-separated lists, trimmed via `xargs`.

Reading from the *staging area* (`git show :path`) in normal mode is a deliberate correctness choice — guarantees the model reviews exactly what the commit will contain, not whatever is currently in the working tree.

---

## 5. Prompt Structure

### Normal / CI mode (`build_prompt`)

```
You are a code reviewer. Analyze the files below and validate they comply with the coding standards provided.

=== CODING STANDARDS ===
<full contents of AGENTS.md>
=== END CODING STANDARDS ===

[=== COMMIT MESSAGE ===          <-- only when commit-msg hook
<commit msg body>
=== END COMMIT MESSAGE ===]

=== FILES TO REVIEW ===

--- FILE: src/foo.ts ---
<file contents>

--- FILE: src/bar.ts ---
<file contents>

=== END FILES ===

**IMPORTANT: Your response MUST include one of these lines near the beginning:**
STATUS: PASSED
STATUS: FAILED

**If FAILED:** List each violation with:
- File name
- Line number (if applicable)
- Rule violated
- Description of the issue

**If PASSED:** Confirm all files comply with the coding standards.

**Begin with STATUS:**
```

### PR mode (`build_pr_prompt`) — extra preamble + optional diff block:

```
You are a code reviewer analyzing a pull request against the <base> branch.

=== CODING STANDARDS === ... === END CODING STANDARDS ===

=== PR CONTEXT ===
This is a pull request review. The following files were changed in this PR (compared to <base>).
=== END PR CONTEXT ===

[=== PR DIFF ===                  <-- only when --diff-only
<git diff output>
=== END PR DIFF ===

=== FILES (complete content for context) ===]

(or in non-diff-only: === FILES TO REVIEW ===)

--- FILE: ... ---  <contents>  (repeated)

=== END FILES ===

<STATUS sentinel block>
```

Important: the STATUS-line contract is **the entire success/failure detection mechanism**. It's parsed with a permissive grep — works with `STATUS: PASSED`, `**STATUS: PASSED**`, and tolerates up to 15 lines of preamble (added in v2.6.1 to handle agents that emit instruction-acknowledgement chatter before the verdict).

---

## 6. Provider Abstraction (`lib/providers.sh`)

Each provider is a `<base>:<model?>` string. Dispatch is by `${provider%%:*}` (everything before the first colon). Two execution styles:

| Style | Providers | Mechanism |
|---|---|---|
| **CLI pipe** | `claude`, `gemini`, `codex`, `opencode`, `ollama` (fallback) | Spawn the local CLI, pipe prompt via stdin or pass as arg, capture stdout (stderr → stdout) |
| **HTTP API** | `ollama` (preferred), `lmstudio`, `github` | `python3 json.dumps` to build payload (safe escaping), `curl -d` to POST, `python3` to parse response. Falls back to manual JSON for `lmstudio` if no python3. |

Provider-specific notes:

- **claude**: `printf '%s' "$prompt" | claude --print 2>&1`
- **gemini**: `gemini -p "$prompt"` (checks `gemini whoami` first)
- **codex**: `codex exec "$prompt"`
- **opencode**: `opencode run [--model X] "$prompt"`
- **ollama**: prefers `curl + python3 → /api/generate` with validated `OLLAMA_HOST` (`^https?://[\w.-]+(:\d+)?/?$`); falls back to `ollama run <model> "$prompt"` and strips ANSI escapes
- **lmstudio**: OpenAI-compatible `/v1/chat/completions`, default `http://localhost:1234/v1`, validated host regex
- **github**: GitHub Models API at `https://models.inference.ai.azure.com/chat/completions`, auth via `gh auth token`, temperature 0.2

Timeout wrapper (`execute_with_timeout`) is generic:

- Writes child stdout+stderr to a temp file, writes exit code to another temp file
- Polls `kill -0 $cmd_pid` in a loop, increments elapsed-seconds counter
- TTY: spinner (`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`, 0.1s tick); non-TTY: prints status every 30s
- On expiry: `kill -TERM` then `kill -KILL` after 0.5s, returns 124 (matching GNU `timeout`)

---

## 7. Caching (`lib/cache.sh`)

```
$XDG_CACHE_HOME/gga/  (or ~/.cache/gga/ or %LOCALAPPDATA%/gga/cache/)
└── <sha256(git_root_path)>/      ← project ID
    ├── metadata                   ← sha256("<rules_hash>:<config_hash>")
    └── files/
        ├── <sha256(file_content)>  ← contents "PASSED"
        └── ...
```

- **Two-level invalidation**: top-level `metadata` invalidates everything (rules or `.gga` changed); per-file hash invalidates only that file.
- **Cross-platform hash**: tries `sha256sum`, falls back to `shasum -a 256`.
- **Only PASSED is cached**. Failed reviews are not stored (you re-run on every fix attempt).
- Cache is **disabled** in `--ci` and `--pr-mode` (the contexts where reviewing the same content twice is the *point*).

---

## 8. Git Hook Installation (`cmd_install` / `cmd_uninstall`)

- Hooks dir located via `git rev-parse --git-path hooks` (worktree-safe).
- Two flavors:
  - **pre-commit** (default): hook line is `gga run || exit 1`
  - **commit-msg** (`--commit-msg`): hook line is `gga run "$1" || exit 1` (Git passes the commit message file path as `$1`)
- Idempotent install via marker pair:
  ```
  # ======== GGA START ========
  # Gentleman Guardian Angel - Code Review
  gga run || exit 1
  # ======== GGA END ========
  ```
- If a hook already exists without the markers, GGA splices its block before any trailing `exit 0`; otherwise appends to end.
- Uninstall removes the marker block; if the file becomes shebang-only, it's deleted.
- Includes legacy migration: any `ai-code-review` references are sed-replaced with `gga` automatically (macOS vs Linux `sed -i` handled).

---

## 9. Configuration (`.gga`)

Bash-sourceable `KEY=value` file. Hierarchy:

1. **Env vars** (highest): `GGA_PROVIDER`, `GGA_TIMEOUT`
2. **Project** `./.gga`
3. **Global** `$XDG_CONFIG_HOME/gga/config` (or `~/.config/gga/config`, or `%APPDATA%/gga/config`)
4. **Defaults**

| Key | Default | Purpose |
|---|---|---|
| `PROVIDER` | *(required)* | `claude`, `gemini`, `codex`, `opencode[:model]`, `ollama:<model>`, `lmstudio[:model]`, `github:<model>` |
| `FILE_PATTERNS` | `*` | Comma-separated globs to include |
| `EXCLUDE_PATTERNS` | (none) | Comma-separated globs to exclude |
| `RULES_FILE` | `AGENTS.md` | Path to the standards file |
| `STRICT_MODE` | `true` | If true, ambiguous AI responses fail the review |
| `TIMEOUT` | `300` | Seconds before provider call is killed |
| `PR_BASE_BRANCH` | auto-detect | Override base for `--pr-mode` |

Plus provider hosts: `OLLAMA_HOST`, `LMSTUDIO_HOST` (regex-validated to prevent injection).

---

## 10. Rules File (`AGENTS.md`)

LLM-optimized, **~100–200 lines** (keep it short or model focus degrades). Conventions the docs recommend:

- **Action keywords**: `REJECT if`, `REQUIRE`, `PREFER`
- **Skill-based decomposition for monorepos**: top-level index mapping file globs → per-language skill files. Models with tool-use (Claude/Gemini/Codex) follow the references on demand. Pure LLMs (Ollama) can't, so they must use one consolidated file.
- **Always** include the response-format instruction:
  ```
  FIRST LINE must be exactly:
  STATUS: PASSED
  or
  STATUS: FAILED
  ```

Example minimal `AGENTS.md` shipped by `gga init` is in `docs/rules-file.md`.

---

## 11. Cursor Primitives & Mapping Choices

What Cursor provides that we can use to build a skill:

| Cursor primitive | What it is | Maps to GGA's… |
|---|---|---|
| `.cursor/rules/*.mdc` | Project rules with frontmatter (`description`, `globs`, `alwaysApply`). Auto-attached to chat context per matched globs. | The `AGENTS.md` rules content. Glob-based attachment ≈ skill-index file-pattern triggers. |
| `AGENTS.md` (repo root) | Cursor reads it as a global agent instruction. | Direct 1:1. Can be the same file. |
| `.cursor/commands/<name>.md` | User-invokable slash commands (`/<name>`). The body is a prompt template. | The `gga run` CLI invocation — a user-triggered workflow. |
| **Cursor Hooks** (config in `.cursor/hooks.json` or settings) | Run shell scripts at lifecycle events (e.g. before tool use, on prompt submit). | The `pre-commit` hook glue. |
| **Cursor CLI** (`cursor-agent`) | Headless agent invocation from a terminal. | Equivalent of `gga run` from inside a real git hook. |
| **Cursor Background Agents** | Sandboxed agents that run async (web/Slack/cron). | A managed alternative to `--pr-mode` in CI. |
| **BugBot** | Cursor's managed GitHub PR reviewer. | The `--pr-mode --diff-only` workflow as a hosted product. |
| **MCP servers** | External tool providers. | Could expose a "review" MCP tool if needed. |

The provider abstraction GGA spends so much code on (`lib/providers.sh`) is **not needed in Cursor** — Cursor *is* the model layer. We get model selection for free, including via the user's chosen Cursor model. The whole 800-line `providers.sh` collapses to "Cursor handles it."

Conversely, GGA's git-aware file gathering, prompt assembly, STATUS parsing, and cache **are still needed** if we want the same deterministic pre-commit behavior.

---

## 12. Design Options for the Cursor Port

### Option A — Pure Rule (passive)

- `.cursor/rules/code-review.mdc` with `alwaysApply: true` or relevant globs, body = GGA's `AGENTS.md` content + STATUS sentinel instructions.
- User triggers manually by typing "review my staged changes" in Cursor chat.
- **Pros**: zero infrastructure, native to Cursor.
- **Cons**: not deterministic, no pre-commit blocking, easy to skip. No cache. No PR mode. Relies on user discipline.

### Option B — Slash Command (active, in-editor)

- `.cursor/commands/review.md` defines `/review`. Body tells the agent to:
  1. Run `git diff --cached --name-only --diff-filter=ACM` via a shell tool call
  2. Read each file (preferably from staging with `git show :path`)
  3. Apply the rules from the auto-attached `.cursor/rules/code-review.mdc`
  4. Emit STATUS: PASSED/FAILED + violation list
- Optional flags via command args: `/review --pr` or `/review --ci`.
- **Pros**: native, one-keystroke, uses Cursor's model and tools.
- **Cons**: no commit blocking; the agent can deviate from the prompt; STATUS parsing is for human/CI consumption only.

### Option C — Hook-Backed Slash Command (active, deterministic)

- `.cursor/commands/review.md` + a small `scripts/cursor-review.sh` (or `.ts`) that does the deterministic parts (file gathering, prompt assembly, STATUS parsing) and uses `cursor-agent` (Cursor CLI) for the model call.
- Optionally register the script as a **git pre-commit hook** (same as GGA does), giving you the commit-blocking guarantee.
- **Pros**: best of both — deterministic gather/parse, Cursor as the model, real commit blocking.
- **Cons**: more moving parts; depends on `cursor-agent` CLI availability.

### Option D — Full Reuse (call GGA from Cursor)

- Install GGA itself, configure `PROVIDER="..."` to whichever provider the user has, and write a thin `.cursor/commands/review.md` that just shells out to `gga run` (or `gga run --pr-mode`).
- **Pros**: zero re-implementation; instant feature parity.
- **Cons**: defeats the purpose of "a Cursor-native skill"; user needs a non-Cursor provider CLI installed; doesn't leverage Cursor's model.

### Recommendation — Option C (Hook-Backed Slash Command)

Best balance of (a) staying inside the Cursor ecosystem, (b) preserving GGA's deterministic guarantees (STATUS parsing, caching, pre-commit blocking), and (c) leveraging Cursor's model selection. Option A is a worthwhile *fallback* mode for users who don't want to wire up hooks.

---

## 13. Proposed Skill Structure (Option C)

```
<user-project>/
├── .cursor/
│   ├── rules/
│   │   └── code-review.mdc          ← The rules (REJECT/REQUIRE/PREFER) + STATUS contract
│   ├── commands/
│   │   ├── review.md                ← /review (staged files)
│   │   ├── review-ci.md             ← /review-ci (last commit)
│   │   └── review-pr.md             ← /review-pr (PR range)
│   └── hooks.json                   ← Optional: tie /review to commit lifecycle
├── .cursor-review/
│   ├── config.json                  ← FILE_PATTERNS / EXCLUDE_PATTERNS / RULES_FILE / STRICT_MODE / TIMEOUT
│   └── cache/                       ← Per-project content hashes (mirrors lib/cache.sh)
├── scripts/
│   └── cursor-review.{sh|ts}        ← The deterministic core (file gather + prompt build + parse)
└── AGENTS.md                        ← Same file, referenced by the .mdc; also read by Cursor natively
```

Key implementation contracts to preserve from GGA:

1. **Read from staging area in normal mode** — `git show :path`, not `cat path`. Reviews the actual commit content.
2. **STATUS sentinel in first 15 lines** — same permissive grep, same `STRICT_MODE` toggle.
3. **Two-level cache** (`metadata` for rules+config, `files/<hash>` per file content) — same invalidation rules; disable in CI/PR modes.
4. **Marker-based hook install/uninstall** — same `# ======== START/END` block, same worktree-safe `git rev-parse --git-path hooks`.
5. **Three file-list modes** (staged / `HEAD~1..HEAD` / `<base>...HEAD`) with base-branch auto-detect (`main` → `master` → `develop`).
6. **Comma-separated glob filters** with suffix-match semantics (or upgrade to real glob with minimatch / picomatch if rewriting in TS).

---

## 14. Translation Cheatsheet (GGA → Cursor)

| GGA concept | Cursor equivalent |
|---|---|
| `bin/gga` (CLI dispatcher) | `.cursor/commands/*.md` (one per subcommand) |
| `lib/providers.sh` (provider abstraction) | **Deleted.** Cursor is the provider. |
| `lib/cache.sh` | Keep as-is in `scripts/cursor-review.{sh|ts}` |
| `lib/pr_mode.sh` (base detection, range) | Keep as-is |
| `AGENTS.md` (rules) | `.cursor/rules/code-review.mdc` + optionally keep `AGENTS.md` for tool interop |
| `.gga` (config) | `.cursor-review/config.json` (or YAML; or frontmatter inside the `.mdc`) |
| `gga install` (pre-commit hook) | `scripts/install-hook.sh` (drops in the same marker-bracketed pre-commit) |
| `gga run` | `/review` slash command + script invocation |
| `gga run --ci` | `/review-ci` |
| `gga run --pr-mode [--diff-only]` | `/review-pr [--diff-only]` |
| `gga cache status / clear / clear-all` | `/review-cache <subcommand>` (or just bash script subcommand) |
| `STATUS: PASSED/FAILED` parsing | Identical contract — Cursor's agent emits it, script greps for it |
| `STRICT_MODE` | Identical — config flag |
| Timeout + spinner | Use Cursor CLI's own timeout, or wrap with `timeout(1)` in the script |

---

## 15. Open Questions / Decisions to Make Later

1. **Language**: Stay in Bash (max portability, mirrors GGA closely) or rewrite in TypeScript/Node (better cross-platform on Windows, better glob libraries, easier JSON config)? Recommendation: **TypeScript** for a Cursor-native feel; users likely already have Node.
2. **Cursor CLI dependency**: Do we require `cursor-agent` to be installed for the hook-backed flow? Or is Option B (pure slash command, no CLI) the default and Option C (with hook) optional?
3. **Rule format**: Keep the `REJECT / REQUIRE / PREFER` vocabulary, or adopt Cursor-native rule patterns? Recommendation: keep — model-agnostic, well-established, already covered in `docs/rules-file.md`.
4. **Cache scope**: Per-user (`~/.cache/`) like GGA, or per-project (`.cursor-review/cache/` checked into `.gitignore`)? Per-project is friendlier for fresh clones; per-user matches GGA.
5. **Multi-file vs per-file prompting**: GGA sends one combined prompt. For very large PRs this hits context limits. Should the Cursor port batch by file count or token budget? (GGA simply lets you bump `TIMEOUT` or tighten `EXCLUDE_PATTERNS`.)
6. **STATUS contract under Cursor's chat UI**: Slash commands return free-form chat output. The user can see violations directly. The `STATUS:` line is mostly relevant for the script's exit code. Make sure the rule explicitly tells the model to emit it even though the user might find it redundant.
7. **PR mode without GitHub**: GGA's `--pr-mode` works on any branch with a detectable base. Cursor's BugBot is GitHub-specific. Our port should preserve GGA's git-only behavior.
8. **Commit-msg hook**: GGA optionally validates the commit message. Worth porting? Probably yes — it's cheap.

---

## 16. Reference: Minimum Viable Skill (MVP) Spec

What needs to ship for a v0.1 that demonstrates parity with `gga run` (normal mode only):

- [ ] `.cursor/rules/code-review.mdc` — rules + STATUS contract, `alwaysApply: true`
- [ ] `.cursor/commands/review.md` — `/review` that:
  - calls `scripts/cursor-review.{sh|ts} stage` (or equivalent)
  - shows the resulting violations and STATUS line to the user
- [ ] `scripts/cursor-review.{sh|ts}` with subcommands:
  - `stage` → gather staged files (`git diff --cached`), read via `git show :path`, build prompt, hand to Cursor (via `cursor-agent` or via the slash-command channel itself), parse STATUS, manage cache
  - `cache status|clear|clear-all`
- [ ] `.cursor-review/config.json` (or sensible defaults) for `FILE_PATTERNS`, `EXCLUDE_PATTERNS`, `RULES_FILE`, `STRICT_MODE`, `TIMEOUT`
- [ ] `scripts/install-hook.sh` (or equivalent) — drops a marker-bracketed `pre-commit` invoking the same script

v0.2 adds `--ci` and `--pr-mode [--diff-only]`. v0.3 adds the commit-msg variant.

---

## 17. Things to *Not* Carry Over

- The 7-provider switch in `lib/providers.sh`. Cursor handles model selection.
- The Bash-specific `set -e` / signal handling acrobatics if rewriting in TS.
- The legacy `ai-code-review` → `gga` migration logic.
- The Homebrew tap / install machinery (Cursor skills are repo-local, not globally installed).
- The custom timeout-with-spinner (use the runtime's primitives).
- Manual JSON-escape fallback in `execute_lmstudio_api_fallback` (no longer needed without HTTP providers).

---

## 18. Recap

**GGA in one diagram:**

```
[ git staged files / commit / PR ]
            │
            ▼ filter (FILE_PATTERNS / EXCLUDE_PATTERNS)
            │
            ▼ apply cache (hash → PASSED?)
            │
            ▼ build prompt (rules + files + STATUS contract)
            │
            ▼ provider CLI (claude | gemini | codex | opencode | ollama | lmstudio | github)
            │
            ▼ parse STATUS line
            │
       ┌────┴────┐
       │         │
     PASSED    FAILED
   (cache,    (exit 1,
    exit 0)    block commit)
```

**The Cursor port retains all of this *except* the provider switch, replaces the hook glue with either a slash command or a hook-backed script, and keeps the rules contract intact.** Aim for Option C: deterministic gather/parse in a small script, Cursor as the model, rules in `.cursor/rules/*.mdc`, invocation via `/review` slash command and (optionally) a real git pre-commit hook.
