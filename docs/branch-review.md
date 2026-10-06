# Branch Review

Status: design, validated by the user on 2026-10-02. Mockups of the page, on a
real pull request (#57), are published as an artifact; its link is in this
design's pull request.

The user's words: "Read a whole branch on a single page before the PR... If
the review could be simpler. And above all easier to understand, that would be
great."

Today, the editor's file tree has a "Full Branch Diff (N)" entry
(`EditorFileTree.rebuildRootChildren`). Clicking it opens every changed file as
one stacked diff tab (`EditorColumn.showDiffCollection`, rendered by
`pierre-diff.bundle.js`); clicking a file opens that file's diff. Both show raw
diffs in path order:

- nothing says what the branch does, or why;
- a 186-line new controller and a one-line `private(set)` get the same weight;
- nothing points at the risky parts (persistence, concurrency, launch);
- the only way to act is to switch to the agent's terminal and type.

This document proposes a **Branch Review** column: one page that makes a
branch understandable in a few minutes, and lets the user comment and send the
comments to the agent without leaving it.

## Decided

Validated by the user on 2026-10-02, each the recommended option:

1. **A new column type**, not a full-screen view nor the editor's diff tab
   (section 1).
2. **Explanations are a mix, on click:** Nirux's own analysis, the author's
   texts for the "why", and `claude -p` for the "what" when the user clicks
   Explain. Not automatic, and not written by the authoring agent (section 4).
3. **Explain runs Opus 5.5 at effort medium, with read-only access to a copy
   of the branch** (section 4.2).
4. **Comments go to the agent all at once**, typed into its prompt without
   Return, after a sheet that shows the exact text (section 6.2).

## Summary

| Part | What it gives | Main mechanism |
| --- | --- | --- |
| Summary | What the branch does and why, with the decisions taken | PR body, handover, commits; each block says where it comes from |
| Groups | Files grouped by intent, ordered by importance; noise folded | Path rules, then `claude -p`'s intent groups when asked |
| Explanations | One sentence per file, a note per hunk that needs one | `claude -p` on the user's subscription, structured output, cached per file patch |
| Risk signals | Persistence, security, concurrency, launch, CI, side effects; tests against code | Deterministic rules on the diff; the model can add notes, never remove a signal |
| Actions | Comment a line or a file, send the comments to the agent, mark files reviewed | Local storage; bracketed paste into the agent's prompt, no Return |

## 1. Shape

**A new column type, "Branch Review".** The Project Board set the precedent:
a tool that reads state across the workspace is a column, next to the agent
that does the work.

- It opens at two-thirds of the width, so the agent's terminal stays in view:
  the user sends comments and watches the agent answer them. Its width then
  cycles through the presets like any column's.
- It reviews one branch: the branch checked out in the workspace's folder when
  it opened. It stores the worktree path, the branch name and the project
  (space) it was opened in. A second "Review Branch" in the same worktree
  focuses the existing column.
- Entry points:
  - the palette: **Review Branch** (current workspace);
  - the sidebar's workspace menu: **Review Branch**;
  - the editor's "Full Branch Diff (N)" tab: a native banner above the web
    view, like the editor's conflict banner (`EditorConflictBanner`), with an
    "Open in Branch Review" button;
  - later, a "Review" button on the Project Board's rows.

  The palette command and the menu item are listed in the UI flow harness
  (#59, `UIFlowCoverage`), which fails otherwise. The editor's banner is
  outside what the harness enumerates, so it gets its own flow test; it is
  native so that a test can click it.
- **The page is HTML in a `WKWebView`**, like the editor, with its own page
  (`review.html`, not the editor's `index.html`): the summary, the
  groups, the comments and the diffs are one scrolling document. Swift
  computes the data (git, `gh`, rules, `claude -p`) and sends it over the
  bridge; the page renders it and sends back clicks and comments.
- **Diffs use `@pierre/diffs`**, the library already bundled in
  `pierre-diff.bundle.js` (version 1.1.22). It has what the page needs: line
  annotations (`lineAnnotations`, `renderAnnotation`) for explanations and
  comments under a line, a gutter button (`enableGutterUtility`,
  `renderGutterUtility`, `onGutterUtilityClick`; the hover variants are
  deprecated) to start a comment, line selection (`enableLineSelection`,
  `onLineSelected`) for ranges, and virtualization for long branches. The
  wrapper (`Web/pierre-diff`: `pierre-diff-entry.js`, `package.json` and
  its lock, built by `build.sh`) gives the page `createReview`: a file's
  diff from its hunks, unified, without pierre's file header, rendered only
  near the viewport (`VirtualizedFileDiff`). Annotations are `{ side,
  lineNumber, key }`: a removed line's on the `deletions` side, numbered in
  the base, an added or unchanged line's on `additions`, numbered in the
  working tree (an unchanged line's given by its base number goes there
  too). The page's `renderAnnotation` returns the element shown under the
  line, which pierre slots into the diff from the page's DOM: the page's
  CSS styles it, and the key is never markup. The wrapper keeps an
  element by its side, line and key (pierre keeps it by its index in the
  list), so one that stays keeps what it holds and its focus, whatever is
  added or removed before it; those of a line show in the list's order.
  `setAnnotations` renders a file on screen again at once, so the page
  finds its element in place, measures it, and keeps what the viewport
  shows in place; a file off screen renders its annotations once it is
  scrolled to. The gutter button (`onGutterClick`) and the line numbers'
  selection (`onSelect`) are on only when the page gives their callback;
  they report `{ start, side, end, endSide }`, lines of the file's own
  diff, from where a drag began (it can end above, on the other side, or
  in another hunk: the page checks). A gutter click is reported once.
  pierre's button is pointer-only: the page offers another way to
  comment. `setSelection` shows a range without reporting it. A callback
  that throws is logged: it doesn't stop pierre's clicks, or replace the
  diff with the error. A line break inside a line
  (LF, CR, U+2028, U+2029) is shown as its code point, `⟨U+2028⟩`: in the
  patch text pierre parses, it would end the line, and the rest could read
  as a hunk. The CR that ends a CRLF file's line stays hidden, unless the
  hunk's lines don't all end with one: a change of line ending would read
  as no change. Bidi controls, which reorder what follows ("Trojan
  Source"), and invisible characters are shown the same way: zero-width
  ones, Hangul fillers, tag characters, and variation selectors, which can
  carry a hidden payload; U+FE0E and U+FE0F only stay right after an
  emoji, whose look they pick (decided by the user on 2026-10-03). A diff
  past 1,500 lines or 100,000 characters, both sides counted, is plain
  text, and its element says so (`data-uncolored="large"`): pierre colors
  a whole file at once, on the page's main thread, which takes seconds for
  a few hundred KB.
- Persistence: `ColumnKind` gains `branchReview`. An older nightly decodes the
  unknown kind as a terminal, as for the board: a rollback turns the column
  into a shell in the worktree. Reopen it after updating.

### 1.1 Untrusted content

The page shows text that neither Nirux nor the user wrote: diffs, file paths,
PR bodies (a fork's included), commit messages, handovers, Claude's output.
The page has a bridge to Swift, so:

- `review.html` carries a Content Security Policy: scripts from the bundle
  only (`script-src 'self'`), no remote image, font, frame or connection.
  Styles allow `'unsafe-inline'`: `@pierre/diffs` creates `<style>` elements
  and its syntax highlighting writes inline styles.
- The web view loads only its bundled `file://` page. Every other navigation is
  cancelled (`decidePolicyFor`); a link opens in the browser instead.
- The bridge accepts messages only from the main frame of that page.
- The page's own code sets every untrusted string with `textContent` and
  never uses `innerHTML`. Markdown in a PR body is rendered without raw HTML.
  `@pierre/diffs` writes the diff through `innerHTML`
  (`renderPartialHTML`) after escaping it; a test covers that escaping on
  crafted lines (section 9.1). With its file header off, pierre writes no
  path: the page's own row shows it.
- Bridge messages carry ids, links and the user's comments, never text to
  type: Swift builds the message to send to the agent from its own stored
  comments, and the sheet that confirms it is native. A page script gone
  wrong could store any text as a comment, so the sheet shows the whole
  message before anything is sent (section 6.2).

Rejected:

- **A full-screen view** (a sheet or a window over the workspace). It hides the
  agent's terminal, so sending comments and watching the answer means going
  back and forth, and it is a second kind of surface to maintain.
- **Improving the editor's diff tab.** The editor is for editing: its tab bar,
  file tree and Monaco models get in the way of a document read top to bottom,
  and a review needs room the file tree takes.

## 2. The page

Top to bottom:

1. **Header.** `feat/keep-awake → main`, PR #57 and its state, the head
   commit, "3 commits (1 merge from main)", "16 files, +1043 −21".
   Progress: "Reviewed 4 of 16 files". Buttons: Explain, Send N Comments to
   Agent, Refresh. Warnings when they apply: uncommitted changes, unpushed
   commits, local branch behind its PR, PR in the merge queue.
2. **What and why.** The author's account, in this order of preference:
   - the PR's title and body (`gh pr view --json title,body`);
   - the handover (`.claude-handover.md` or `.codex-handover.md` in the
     worktree);
   - the commit messages, merges from the base excluded.

   Each block is labeled with its source. A heading of the PR body that starts
   with "Decisions" is shown as a list of its own, since decisions are what a
   reviewer must not undo by accident. With no PR and no handover, the page
   says so. Once explained (section 4), Claude's overview shows above, labeled
   with the model and the head it read.
3. **Claims.** Once explained, the claims of the PR body that the code
   contradicts, matches only partly, or that aren't in the diff, each with its
   evidence. Matching claims are only counted, in neutral text: nothing from
   the model reads as approval.
4. **Risk signals.** One chip per signal with its count (section 5). Clicking a
   chip filters the list to the hunks that raised it. R2 works by file: the
   files that don't raise it are dimmed, and the groups that hold those that
   do open.
5. **Groups.** Files grouped by intent (feature, behavior change, refactor,
   tests, config, docs, CI), most important group first, and files by
   importance inside a group. Each file row: status (added, modified, deleted,
   renamed), path, +/−, its risk chips, its one-sentence summary once
   explained, a "Reviewed" checkbox, and its comment count. A row expands into
   its diff, with explanation notes under the hunks they explain and comment
   threads under their lines.
6. **Folded.** Collapsed groups that are counted but never hidden:
   - lockfiles: `Package.resolved`, `package-lock.json`, `yarn.lock`,
     `Cargo.lock`, `Gemfile.lock`, `go.sum`;
   - generated files: `*.bundle.js`, `*.min.js`, `*.pb.swift`, paths marked
     `linguist-generated` in `.gitattributes`, files whose first lines say
     `@generated`, "Code generated … DO NOT EDIT", or the header of SwiftGen,
     Sourcery or SwiftProtobuf (added by the user on 2026-10-03: their files
     don't say `@generated`, and would flood "Tests against code");
   - pure renames (similarity 100%) and whitespace-only changes;
   - binaries.

   `-linguist-generated` (or `=false`) keeps a file out of the generated
   group whatever its name. When the branch changes a `.gitattributes`, its
   `linguist-generated` marks are ignored: a branch mustn't fold its own
   files. A marker counts outside quotes, or opening a line or its
   comment: a script that writes the marker isn't generated. Minified code
   with another name isn't folded: one long line would fold a hand-written
   script. Whitespace only means each hunk reads the same without its blank
   lines and the whitespace around its lines; whitespace inside a line
   changes what the code does (`" "` and `""`), and in Python, YAML, a
   Makefile or a shell script the indentation and blank lines do too. In
   Swift, a multi-line string's text counts as Swift reads it: past its
   closing delimiter's indentation, with its blank lines and trailing
   spaces, and line endings as newlines, around an interpolation that
   spans lines too. A
   reindent that moves a string with its closing delimiter still folds; one
   that moves its text alone doesn't ("Swift files read in context",
   section 5). A JavaScript template still reads as code. A folded file's diff loads when
   its row opens, and folded files don't count toward the 5 MB of section
   7: a generated bundle or a reformatted repository mustn't send the whole
   page on demand. Listed without its patch (section 7, past 64 MB), a file
   folds only by its name and attributes.

**Uncommitted changes** are part of what the agent did, but not of the PR yet:
they form their own group at the top, marked "not committed". A file changed
both in commits and in the working tree is listed there once, with its whole
patch from the merge base to the working tree. A folded file that isn't
committed stays in that group, collapsed: a build-rewritten
`Package.resolved` must be seen before it is committed. The group refreshes
while the agent works, so it lists added files first, then by path: a row
doesn't move under the pointer. The files
Nirux's worktree cleanup already treats as disposable
(`WorktreeCleanup.disposablePaths`: the handovers,
`.claude/settings.local.json`) are left out.

The page uses the visual system's tokens. Amber stays reserved for "an agent
waits for the user": risk chips are neutral, and a finished Explain raises no
attention state and no notification.

## 3. Grouping without a model

The page is useful before anyone clicks Explain. Nirux groups by path:

| Group | Paths |
| --- | --- |
| Code | everything not below |
| Tests | a folder whose name ends in `Tests` (`Tests/`, Xcode's `AppTests/`), `*Tests.swift`, `*_test.*`, `*.test.*`, `*.spec.*` |
| Config and dependencies | `Package.swift`, `*.plist`, `*.entitlements`, `.swiftlint.yml`, `.gitattributes`, `scripts/`, the rest of `.github/` |
| CI | `.github/workflows/`, `.github/actions/` |
| Docs | `*.md`, `docs/` at the top level |

The rules apply top to bottom, and the first that matches wins: the table
lists "Code" first for reading, but it is the fallback, tried last
(`Tests/README.md` is a test file). Inside a group, added files come first,
then by lines changed. Once explained,
Claude's intent groups replace the path groups. Nirux checks them: a path that
isn't in the diff is dropped, a file that appears in no group goes to "Other
changes", a file in two groups stays in the first.

## 4. Explanations: who writes them

### 4.1 The three sources

| | The authoring agent annotates its branch | `claude -p` on the user's subscription | Mix (recommended) |
| --- | --- | --- | --- |
| Cost | Tokens in the agent's own context, which may push it into compaction. A Codex or Gemini agent spends that provider's quota | 35k to 210k tokens read and 4k to 25k written for #57 (section 4.2); part of the plan's usage limits | Nothing until the user clicks Explain; then only the files whose patch changed since the last run |
| Time | Only when the agent is idle; asking a working agent interrupts it | 22 s to 3.5 min on #57, depending on the model and the flags | The page opens at once; explanations arrive later |
| Reliability | Knows the why. But it reviews its own work, describes what it meant to do rather than what the code does, and goes stale with its next commit. Codex, Gemini and OpenCode follow a format unevenly | An independent reader with a fixed format. Knows the why only from what it is given, and can be wrong | The why from the author's texts, the what from an independent reader, the risks from rules |
| Privacy | Nothing new leaves the Mac | The diff and the files the model reads go to Anthropic under the user's Claude account, as a Claude agent's work already does. New for a project whose agents are only Codex or Gemini | Same as `claude -p`, only on click |

**Recommendation: the mix.**

- Nirux's own analysis is always there: groups by path, noise, risk signals,
  tests against code. It is free, instant and local.
- The "why" comes from what the author already wrote: the PR body, the
  handover, the commits. They are shown as the author's claims.
- The "what" comes from `claude -p`, when the user clicks Explain. It also
  checks the author's claims against the code ("matches", "partly",
  "contradicts", "not in the diff").
- The authoring agent's role is to answer the comments (section 6), not to
  grade its own work.

### 4.2 Measured on #57

On 2026-10-02, with Claude Code 2.1.287, on the diff of #57 (68 KB with 3 lines
of context, 16 files, +1043 −21), its PR body and its commits, with hunks
numbered (`f12h1`) and a JSON schema for the output. Tokens read include cache
reads. The cost is what the CLI reports (`total_cost_usd`), at API prices; on a
subscription nothing is billed per call, it counts toward the plan's limits.

| Flags | Model | Reads the repository | Time | Tokens read | Tokens written | Reported cost |
| --- | --- | --- | --- | --- | --- | --- |
| Claude Code's defaults | Sonnet 5.5 | no | 33 s | 74k | 5.5k | $0.35 |
| Claude Code's defaults | Opus 5.5, Claude Code's effort | no | 210 s | 74k | 24.5k | $1.08 |
| Lean | Sonnet 5.5 | no | 29 s | 34.5k | 4.8k | $0.19 |
| Lean | Opus 5.5, effort medium | no | 72 s | 34.5k | 8.5k | $0.45 |
| Lean | Sonnet 5.5 | read-only | 22 s | 36.7k | 3.8k | $0.19 |
| Lean | Opus 5.5, effort medium | read-only | 79 s | 47k + 162k cached | 9k | $0.59 |

"Lean" means no MCP servers, no skills, no user settings and Nirux's own
system prompt; section 4.3 has the flags Explain will use.

What the runs found:

- **The lean flags halve the input.** Claude Code's own system prompt, the
  user's MCP servers and skills were 40k of the 74k tokens.
- **Without the repository, the model is wrong about what it can't see.** The
  two main concerns of the Opus run were false alarms: it asked whether
  `foregroundProcesses` covers the hidden spaces' columns (it does:
  `followForegroundProcesses` walks every workspace), and whether saving the
  setting and `setEnabled` could diverge (both run under `!telegramOnly`).
- **With read-only access, Opus checked before asking, and found a real bug**
  that the reviews of #57 missed (two adversarial reviews, a confirmation
  review and `/code-review`), still on `main` then (fixed since by #89). In
  the background, after 10 minutes of silence, a Claude with hooks
  interrupted with Esc no longer needs a background refresh, so
  `refreshAgentStatusInBackground` returns before `updateKeepAwake()`. The
  assertion stays held until Nirux comes back to the front or other activity
  refreshes the sidebar: another column still polled (an agent without Claude
  hooks, an open dialog), a title change, another Claude's hook event.
- **Sonnet with the same access opened no file** (two turns, no read). It
  raised no false alarm, and found nothing either.
- Opus also grouped better: `MainActorSchedule` and `TerminalSearchSession` in
  a refactor group, the hidden-space tick in a behavior-change group of its
  own. Sonnet filed the refactor under the feature.
- One branch is not a benchmark. R3 runs Explain on five merged PRs, one of
  them over 300 KB, before its defaults are frozen.

**Recommendation: Opus 5.5 at effort medium, with read-only access to a copy
of the branch.** About 80 s and $0.59 at API prices for a branch of this size.

**Measured on five merged PRs (R3b-2, 2026-10-04),** with Claude Code 2.1.289,
Opus 5.5 at effort medium, the flags and input of section 4.3, each PR's own
body, its diff against `main` before its merge, and English answers:

| PR | Files | Diff sent | Runs | Time per run | Read (cached) | Written | Reported cost | Notes, checks |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| #57 keep-awake | 16 | 66 KB | 1 | 63 s | 164k (119k) | 6.5k | $0.52 | 8, 5 |
| #88 Mission tell | 14 | 51 KB | 1 | 84 s | 199k (159k) | 10.3k | $0.55 | 9, 7 |
| #107 lexer extensions | 12 | 87 KB | 1 | 99 s | 311k (254k) | 9.6k | $0.70 | 13, 7 |
| #104 Branch Review column | 31 | 176 KB | 2 | 64 s, 50 s | 238k (135k) | 12.3k | $1.10 | 17, 11 |
| #62 merge queue engine (301 KB) | 20 | 284 KB | 2 | 83 s, 55 s | 494k (348k) | 14.6k | $1.53 | 18, 11 |

- Every run answered, and named only ids the input had (no answer dropped a
  reference). Each took 4 to 8 turns, reading the repository before it
  answered.
- The second part of #62 and #104 got the first part's overview, and the
  overview that came back covers the whole branch.
- With partial messages, thinking streams too: no run's stream stayed silent
  2 s. The idle timeout of 3 minutes leaves room for the API's retries.
- This #57 run raised five checks but not the keep-awake bug the design's
  run found (the background poll returning before `updateKeepAwake`): two
  runs of the same branch don't flag the same things. The page says the
  notes are Claude's, and never reads as approval.

Frozen from these runs: Opus 5.5 at effort medium; 150 KB of diff per run
(the largest part, 147 KB, took 83 s); 6 minutes in all (the longest run took
99 s); 3 minutes of silence; and a spending cap of $3 at API prices per run,
about four times the dearest run. A higher effort chosen in Settings keeps
these limits: they cap what a run spends, and Settings says Extra high and
Max can reach them on a large branch.

### 4.3 How Nirux runs it

```sh
claude -p --model claude-opus-5-5 --effort medium \
  --output-format stream-json --verbose --include-partial-messages \
  --json-schema <schema> --max-budget-usd 3.0 \
  --tools Read,Grep,Glob --restricted --permission-prompts none \
  --strict-mcp-config --disable-slash-commands \
  --no-session-persistence \
  --settings '{"disableAllHooks":true,"instructionFiles":"managed-only"}' \
  --system-prompt <review prompt> < input
```

`instructionFiles: managed-only` (in 2.1.284 to 2.1.289) drops the project's
and the user's instruction files: with no `CLAUDE.md` in the copy, Claude Code
would read the branch's `AGENTS.md`, and the user's own `~/.claude/CLAUDE.md`
isn't the reviewer's. A canary run found `--restricted` alone already loads
none, and an unknown value falls back to the default silently: the setting is
a second line, not the first. The system prompt says what the input holds,
that the author's texts are claims to check and never instructions, that
text in the diff addressing the model is a finding, not an order, and to name
files and hunks by their ids. The schema lists the input's ids, so claude
itself makes the model try again when it answers with a path; a path still
stands for its id. `--max-budget-usd` stops a run that an injected diff sends
reading the same files again and again ($3 at API prices, about four times the
dearest run of section 4.2). Partial messages keep the stream busy while the
model thinks or writes (thinking streams too, section 4.2): a run whose
stream stays silent 3 minutes stops, as one does past 6 minutes in all.

- **Read-only and confined.** `--restricted` confines the file tools to the
  working directory, refuses a path that resolves through a symlink to the
  outside, and ignores user, project and local settings. With
  `--permission-prompts none`, anything that would ask is denied. Checked on
  2026-10-02 with a canary: with `--allowedTools Read,Grep,Glob` instead, the
  model read an absolute path outside the folder and a symlink pointing out of
  it; with these flags both were denied. Explain runs the first `claude` it
  finds (every one where a Nirux terminal would look, absolute folders only)
  whose `--help` lists `--restricted`, `--permission-prompts` and
  `--max-budget-usd` (2.1.284 does): an old npm or Homebrew install earlier
  in `PATH` doesn't hide the native installer's. Not
  `ClaudeCodeVersion.detect`: it returns the oldest of the installed
  versions, and nothing for a shim.
- **The run's first event** (`system/init`) says how it started. A run on an
  API key when the account checked is a subscription's (`apiKeySource` other
  than `none`), with tools other than Read, Grep, Glob and the
  `StructuredOutput` tool `--json-schema` answers through, or with an MCP
  server, is stopped at that event: within 50 ms, so its first request may
  already be on its way.
- **`--bare` would be leaner, but it refuses OAuth**, so it doesn't work on a
  subscription.
- **The model id is a full name**, not the `opus` alias, which will move to the
  next model. It is a setting, with this default: Settings > Agents > Branch
  Review offers Opus 5.5 and Sonnet 5.5, and the efforts claude takes (low to
  max). A model set by hand in the state file stays selectable, unless it
  couldn't be a model id: it becomes an argument of claude, which must not
  take it for an option.
- **The copy.** The working directory is a fresh temporary folder outside the
  state directory, deleted after the run. Nirux copies files into it from the
  working tree, so nothing is written to the repository's index or object
  store, unlike a temporary index would. The paths come from `git ls-files -z
  -v`: committed and staged files with their uncommitted edits, intent-to-add
  files included, and the untracked files the run sends when the user asks
  (see "Input" below). That list also holds submodules, deleted files and one
  entry per stage of a conflict, so Nirux copies a path once, and only if it
  opens as a regular file with one link and no symlink anywhere in its path
  (`O_NOFOLLOW_ANY`, and without blocking on a FIFO), and holds UTF-8 text
  (no NUL in its first 8 KB). A file over 4 MB isn't copied, nor files past
  1 GB in all, the branch's own files first. These are never copied:
  - paths that look like a secret, by name whatever the case: `.env*`,
    `*.env`, keys and stores (`*.pem`, `*.p8`, `*.p12`, `*.pfx`, `*.key`,
    `*.jks`, `*.keystore`, `*.ppk`, `id_rsa*`, `id_ed25519*`, `id_ecdsa*`,
    `AuthKey_*`), `*.mobileprovision`, token files (`.netrc`, `.npmrc`,
    `.pypirc`, `.git-credentials`, `.htpasswd`, `.pgpass`), Terraform's
    `*.tfvars` and `*.tfstate`, anything under `.config/gh/`; and, unless it
    is code (Swift, TypeScript, Python, shell, Terraform, SQL, HTML and
    CSS…) or a CI workflow, a name holding `credentials` or
    `secret`, or a file under `.ssh/`, `.gnupg/`, `.aws/`, `.docker/`,
    `.kube/` or `secrets/`. A file renamed from such a path isn't copied
    either;
  - files holding something shaped like a key (below);
  - files whose edits git hides (assume-unchanged, skip-worktree: a common
    way to keep real credentials in a local config), and files, untracked
    ones included, that a clean filter stores as something else (git-crypt,
    git-lfs, a redaction filter): what the working tree holds isn't what
    the diff shows;
  - `CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md`, `AGENTS.override.md` and
    `.claude/`, at any depth and in any case (APFS doesn't tell `claude.md`
    from `CLAUDE.md`): instructions the branch carries must not reach the
    reviewer as project instructions. Claude Code reads `AGENTS.md` where a
    project has no `CLAUDE.md`, which is what the copy leaves. With
    `--restricted`, a canary run of 2.1.289 loaded neither; R3b keeps
    checking it.

  **Keys by their shape** (validated by the user on 2026-10-04, instead of
  the plain markers `-----BEGIN`, `sk-ant-`, `ghp_`, `github_pat_`, `AKIA`,
  which hid code and docs that talk about keys and let other tokens
  through): `-----BEGIN … PRIVATE KEY`, `-----BEGIN` in base64 (a key or a
  certificate inside a config file), `sk-ant-`, `sk-proj-` and OpenAI's
  `sk-` tokens with or without a kind (`sk-svcacct-`), Stripe's live keys, GitHub's `ghp_`, `gho_`,
  `ghu_`, `ghs_`, `ghr_` and `github_pat_` tokens, GitLab's `glpat-`, AWS's
  `AKIA` and `ASIA` key ids, Google's `AIza`, Slack's `xox?-` and npm's
  `npm_`, each followed by as many token characters as the real ones have
  (OpenAI's with a digit, so a slug like `sk-hynix-reports-…` isn't one).
  The check reads only a key's first characters: an open-ended repeat over
  a long run of token characters stops ICU with an error, and a text the
  check can't finish counts as holding a key.

  Not a `git worktree add`: it would show in `git worktree list` and on the
  Project Board. The copy holds an exclusive lock on a sibling `.lock` file,
  taken as it is created (`O_EXLOCK`), for as long as it lives. Leftovers are
  swept at launch and before a run: a copy whose lock nobody holds goes (the
  lock goes with its holder, even after a crash), one without a lock file
  goes once it is 30 minutes old, and a locked one stays, since it may be
  another Nirux's run (the installed app and a dev build share the temporary
  folder).
- **The environment is an allowlist:** `HOME`, `USER`, `LOGNAME`, `LANG`,
  `TMPDIR`, `CLAUDE_CONFIG_DIR`, the proxy and certificate variables (they
  don't bill), the user's telemetry opt-outs (`DISABLE_TELEMETRY`,
  `DISABLE_ERROR_REPORTING`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`,
  which `--restricted` would otherwise lose with the user's settings), and
  a `PATH` that starts with the folder of the `claude` binary, then
  `PtySession.effectivePath`'s absolute entries: an npm install is a `node`
  script, and Nirux's own `PATH` is launchd's. A relative entry (`./bin`)
  would find the branch's own `git` in the copy, which claude runs at
  startup; the copy's files aren't executable either. Nothing else from
  Nirux's environment reaches the child:
  not `NIRUX_AGENT_UUID` (Nirux's hooks run only when it is set), not
  `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` or `ANTHROPIC_BASE_URL` (which
  would bill the API instead of the plan), not the `CLAUDE_CODE_*` variables a
  dev build launched from a Claude session inherits. `disableAllHooks` covers
  hooks from settings Nirux didn't pass.
- **The account.** Before the first run, and when it changes, Nirux reads
  `claude auth status --json`, with the same environment as the run, so it
  reports the account the run will use. The first-use notice of a project
  names the account and its method ("claude.ai, Max"), and the model and
  effort the run asks for; any other method
  (`api_key`, `api_key_helper`, `oauth_token`, `third_party`) or a provider
  other than Anthropic (Bedrock, Vertex) is billed per call, and asks
  again.
  Logged out, or no `claude` found (`AgentCLILocator`), and Explain is
  disabled with the reason.
- **No session is saved** (`--no-session-persistence`): the review doesn't show
  in `claude --resume`. The session history (#68) already ignores `claude -p`.
- **One run at a time, in the whole app** (`ExplainQueue`). A second Explain
  waits in line, and can leave it. The run has a 6-minute timeout and a
  Cancel button; the page counts the files it reads as it goes. `BoundedProcess` can't do
  this today: R3 extends it with stdin (written on a thread of its own while
  the output is read, never raising SIGPIPE), a cancel handle, a replaced (not
  merged) environment, and keeping the output it read when it stops, and runs
  it off the main thread. With `stream-json`, a cancelled or timed-out run
  still leaves the usage its events reported (each assistant message once,
  by its id); a run that ends takes its `result` event's usage, cost and
  turns, and its structured output from that event.
- **Input:** the PR body, the handover, the commits, and the diff from the
  merge base with numbered hunks. Left out: folded noise, binaries, secret
  paths (a rename from one too), and the disposable paths of section 2. A
  hunk holding something shaped like a key, in its lines or in its header
  (git's funcname line, which comes from above the hunk), is replaced by
  "withheld: looks like a secret" and takes no notes; so is an author's text
  that holds one (a commit's message, the handover, the PR body). Untracked
  files are sent by name only, unless the user ticks "Include untracked
  files". The files are listed; those whose diff isn't sent are named with
  why, and so are the branch's files the run can't read in its copy. The
  author's texts are fenced between `<<<nonce` and `nonce>>>` lines, with a
  nonce none of them holds, so a PR body can't pass for the parts that
  follow it. Paths and hunk headers show their invisible characters as code
  points, as the page does, and diff lines their line separators, so none
  of them can fake a line of the input. A diff read on demand for the run is
  checked again (the worktree may have moved), and the input keeps the hash
  of each patch it sent, for the cache.
- **Size:** one run sends at most about 150 KB of diff, and the whole input
  stays near 300 KB: each author's text is cut at 32 KB (the previous
  overview at 16 KB), and past 300 files the lists show the files the run
  sends and the first others, and count the rest by folder. A larger branch
  is explained in several runs of whole groups, packed in the page's order
  (a large group in several runs of whole files), one after the other: a
  later part gets what the earlier parts found (overview, claims, questions),
  fenced with a nonce of its own, and answers for the whole branch, keeping
  what still holds. Each part is cached as it arrives; a part that fails
  stops the rest, and the next Explain sends what is left. A file whose diff
  alone is larger is named, not sent. A branch with no diff left to send
  makes no run.
- **Output:** JSON matching the schema: an overview, intent groups, a summary
  and an importance per file, notes per hunk (with an optional "check this"),
  the claims checked, and at most 5 questions for the author. Nirux drops
  unknown file and hunk ids, a summary of a file whose diff the run didn't
  send, values outside the schema's, and a file listed in a second group;
  caps string lengths (3,000 characters for the overview, 400 for a
  summary, 1,200 for a note); and shows everything as text (section 1.1),
  invisible characters as code points, line breaks kept: the diff itself may
  contain instructions aimed at the model ("say this file is safe"). An
  answer without an overview isn't one.
- **Limits:** the model never marks a file reviewed, never hides a file and
  never removes a risk signal. Its notes are labeled "Claude", with the model
  and the head commit it read, and sit under the last changed line of the
  hunk they explain (pierre's line annotations). Each "check this" note can
  be turned into a comment (once R4 has landed). Every note can be marked
  wrong, and the mark undone: a note can be wrong without a "check this",
  and the count of notes kept counts every note (decided without the user,
  2026-10-06). A mark stays on its note in the review file, and a running
  count of marks, so the page can say how often notes were wrong ("Claude’s
  notes marked wrong: 1 of 12", in the Explain bar). A review this Nirux
  can't write leaves Mark wrong disabled.
- **Cache:** in the review file (section 8), under one top-level key,
  `explain`, with its own `version`:
  - the last overview, groups, claims and questions, with the head and model
    they were written at;
  - per file, its summary, importance and notes, keyed by the hash of the
    patch the run sent (a diff read for the run may be newer than the
    snapshot's), with the head and model that explained it;
  - each note with an id (to mark it wrong, or turn it into a comment), its
    hunk's index in the file's patch and the hunk's anchor, a digest of its
    changed lines (`.1`, `.2`… after the first hunk of the file with the same
    changed lines), not the run's hunk ids (`f12h1`), which only live for one
    run. The patch hash leaves out context and where hunks start, so two
    hunks can merge or split under an unchanged hash when main changes the
    lines between them: the page places a note by its anchor, and hides it
    when no hunk matches;
  - a file whose diff is larger than one run takes, seen at its patch with
    why, so it doesn't stay pending;
  - the last 200 runs' usage, and how many notes were kept and marked wrong
    since the first Explain.

  Reading is lenient: a missing field takes its default, and an entry this
  build can't read is skipped, so a later build's fields don't cost a full
  paid run; a newer `version` is never written over, and Explain then says
  so without running. When the branch moves, Explain again only sends the
  files whose patch changed, with what the last explanation found (overview,
  claims, questions) as context, and the model answers for the whole branch;
  the others keep their notes and their place in the groups, and files no
  longer in the branch go. Only the files Explain would send count: with
  nothing changed but folded, binary, secret, unread or untracked files,
  Explain makes no run and no copy. "Explain again" (`fresh`) sends every
  file without the cache as context, for a fresh look. A file an answer
  sent but neither summarized nor noted isn't kept, and goes again next
  time; an answer that names only ids the input didn't have isn't kept, so
  it can't read as "Claude flagged nothing". Each save applies the job's
  findings onto the cache as the review file holds it then, under its lock:
  a note marked wrong meanwhile keeps its mark, and another Nirux's runs
  stay. Saves record neither a head nor a pull request: opening records the
  job's, only while its head is the review's newest, and a review the job
  creates records them once. After that, the page may open the review at a
  later head of the branch (the agent committed during the run, or the job
  waited in line), or at the job's again: the cache is written at whichever,
  since its entries are keyed by patch hash and hold there too. A review
  deleted meanwhile (Clean Up) or on another history isn't written, nor
  created again: the job stops keeping and says so. A review that can't be
  written (read-only, newer, unverified) is found out before any run, and a
  cache past 2 MB isn't written, though the runs' usage still is and the
  files are seen, so the next Explain doesn't pay for them again: the review
  file also holds the comments and marks, and stops being writable at 8 MB.
- **Usage:** each run's tokens and reported cost are kept with it, and the
  page's Explain bar shows today's total on the branch; a stopped run has no cost, only its
  messages' tokens, so the total says "at least". A run that ends on a usage
  limit says so, rather than "failed": a `rate_limit_event` whose status is
  `rejected` (with when it resets) and no later one lifting it, or a result
  or error that says "usage limit" or "hit your limit" (session, weekly,
  Opus…; not a context or spend limit, nor the servers limiting requests
  "(not your usage limit)", which reads as overloaded), or a run that
  stalled behind one. With extra usage on, the
  event says `rejected` while the run goes on, billed (`isUsingOverage`):
  that isn't a limit, and a successful answer always counts. Other failures
  say what to do: log in from a terminal, a model the account lacks, the API
  overloaded, the spending limit reached.
- **Language:** the Mac's preferred language, English otherwise.
- **First use in a project** shows what will be sent, where, and under which
  account, once: a native alert, asked again in that project when the
  account changes, and before every run for an account billed per call
  (decided by the user on 2026-10-05).

## 5. Risk signals

Deterministic rules on the paths and on the added and removed lines. Each
signal links to its hunks and says why it matters. The model's "check this"
notes are shown apart and never change these signals.

| Signal | Raised by | Why it matters |
| --- | --- | --- |
| Persistence and state | `Codable` types, `CodingKeys`, `decodeIfPresent`, `*Persistence*`, `*Store.swift`, keys of `state.json` or `board.json` | Defaults for missing keys, rollback to an older nightly, data loss |
| Security | Keychain (`SecItem`), `SecCode`/`SecStaticCode`, entitlements, the `nirux://` scheme (`NiruxURLRequest`), `HandoverFile`, Telegram remote access, `/tmp` paths, `Process` arguments | Input from outside, secrets, signing |
| Concurrency | `@MainActor`, `nonisolated`, `@Sendable`, `@unchecked Sendable`, `DispatchQueue`, `OperationQueue`, `Task {`, `MainActor.assumeIsolated`, `RunLoop.main.perform` | CI's Swift 6.1 is stricter than local 6.2; a main-actor closure run off the main thread crashed a nightly (#48) |
| App launch and quit | `applicationDidFinishLaunching`, `applicationWillTerminate`, the `--hook` mode, `NIRUX_*` variables, `Info.plist`, Sparkle, `bundle.sh` | Paths that only the installed, notarized app takes |
| CI workflows | `.github/`, scripts the workflows call | The nightly publishes to every install |
| Side effects outside Nirux | IOKit, `NSWorkspace`, writes to `~/.claude`, `~/.codex` or the hooks, notifications, `launchctl` | They outlive the app or change the Mac |
| Dependencies | `Package.swift`, `Package.resolved` | A build-rewritten `Package.resolved` must not be committed |

`Process` arguments are a launched process's (`Process(`, `BoundedProcess`,
`.arguments =`), not `CommandLine.arguments`; launching one is a security
signal, not a side effect, so that every git run doesn't raise two chips. A
line rule matches anywhere in a `+` or `-` line, strings included, but not
in a line that is only a comment, nor in a doc or a folded file: a generated
file can say anything, and a reindented line changes nothing. In Swift, no
comment counts, trailing or spanning lines (`code // Telegram`). A folded file raises only its path rules. A test ships
nothing: it raises only the concurrency rules, which CI checks more strictly.
Path rules also cover the files whose changes may name no rule: a name with
`Persistence`, `HandoverFile`, `NiruxURLRequest`, `+URLScheme`, `Telegram`,
the app delegate (`NiruxApp.swift`), the hook and skill installers.
"Scripts the workflows call" are the changed files, docs and tests aside,
whose path a workflow (`.github/workflows/*.yml`) or an action
(`action.yml` under `.github/actions`, outside its `node_modules`) names:
`./scripts/bundle.sh`. A change inside a lifecycle function raises "launch"
even when it doesn't name it ("inside applicationDidFinishLaunching"): the
app delegate's `applicationWillFinishLaunching`,
`applicationDidFinishLaunching`, `applicationShouldTerminate` and
`applicationWillTerminate`, and an `@main` type's `static func main` (or
`class func main`, in the type or in an extension of it declared after it
in the same file), where the `--hook` and `--check-release-signature`
modes live (decided by the user on 2026-10-03); not another type's `main`,
such as a subcommand's. A signature may wrap before its body (`-> T`,
`where`, `async`, `throws`, generic parameters, `{` on its own line); the
line that opens the body, and a closure in the signature, count as inside;
a line of comments or blanks changes nothing. On #57 (`setUpKeepAwake(...)`, `keepAwakeController?.shutdown()`)
and #65 (the release check at launch and in `main`), `NiruxApp.swift`
already raised "launch" by its path: this names the reasons and the hunks.

**Swift files read in context.** A Swift file's patch is read a second
time, its two sides through the lexer of "Tests against code": the old side
from the lines both share (taken from the worktree) and the removed lines,
the new side from the file in the worktree, checked against the patch's
lines. That tells, for each changed line, whether it is in a multi-line
string's text, which comments it holds, and which function it is in: its
line rules, its whitespace fold, its symbols and the lifecycle functions
above come from that reading. An addition or a deletion reads from its patch
alone; a type change (a symlink that became the file) reads its new file,
its hunks numbered after the link's; a symlink (added, or modified as its
`index` line says) declares nothing. The files that may declare symbols are
read first, within the scan limits of "Tests against code" (2 MB for the
file, and for its patch: a huge removal isn't read again line by line; 32
MB in all). A file that can't be read so (past those limits, changed since
its patch or a link where the patch shows a file, unbalanced) keeps the
first pass's line rules and fold, its symbols are unknown, and it says why
(`swiftContext`): a row reloaded on its own may then read differently,
since the edit that made it differ triggers a refresh, and alone it is
within the limits.

**Tests against code.** The header shows lines added in tests against lines
added in code, and lists the symbols the branch declares that no test
mentions. A symbol is an identifier declared on an added line (`func`, `var`,
`let`, `class`, `struct`, `enum`, `case`, `protocol`, `typealias`, `actor`)
outside any function body, found by tracking braces in the file in the
worktree, and not `private` or `fileprivate`, nor in a private type or extension:
private members are tested through the API that uses them, and local
variables would only add noise. A test mentions a symbol when the identifier
appears as a whole word in a file of the Tests group. On #57, 578 test lines
for 458 code lines, and 10 of 44 names (each counted once per type) that no
test mentions, among them `setUpKeepAwake` (the launch wiring),
`IOKitSleepAssertions` (the real IOKit calls; the tests inject a fake) and
`mainQueueSchedule`. A mention isn't coverage, so the line says "mentions",
never "tested".

Refined by the user on 2026-10-03, after a run on 18 merged pull requests
where about a quarter of the names listed were noise:

- An `override`, and an `@objc` or `@IBAction` method, aren't listed: the
  superclass, a selector or an action reaches them, not a test by name.
  `@objc` properties are.
- A type counts as mentioned once a test names a member the branch declares,
  in any file, matched by the type's dotted path (`Outer.Inner`): tests
  write `.notRead`, not `Omission.notRead`. Only through a member whose name
  no other type of the branch declares: tests call a protocol's `create` on
  a fake, which says nothing of the real type's (on #57,
  `IOKitSleepAssertions`).
- In a Swift test file, only code counts: a name in a comment or a string
  isn't a mention; one in an interpolation is.
- A name a removed line of the same file declares isn't new: a changed
  value, conformance, signature or visibility (`private` to `private(set)`)
  re-declares it. Removed lines are read in context (below), so only a
  declaration outside any function body counts.
- Lines added under `scripts/` count as code in the ratio: a script is code
  its tests test. The page still groups them as Config.
- Protocol requirements the system calls (`windowShouldClose`,
  `errorDescription`) stay listed: few, and no rule tells them apart
  without a list of names that would age.

How it reads:

- **Lines.** The added lines of the Tests and Code groups' files, and of
  scripts, folded files aside. An untracked file listed by name only counts
  no line.
- **Symbols.** Only Swift files of the Code group, not folded, read in
  context (section 5, "Swift files read in context"), and lexed whole: strings (multi-line, raw,
  with interpolations), nested comments and `#/…/#` regexes hold no brace
  and no declaration. `class func` is a method, `private(set)` doesn't make
  a property private, `if let` and `guard let` at a file's level declare
  nothing, `case a, b(Int)` declares two names, a name in backticks counts
  without them (one with a space can't be a word, and isn't listed), and an
  extension of a private type declared in the same file, or of a type
  nested in one, is private. A member's type is kept as a dotted path
  (`Outer.Inner`). A symlink declares nothing. The symbols are unknown, and
  the header names the file rather than reading "nothing declared", when
  its patch wasn't read, when it or its patch is past
  2 MB or the files read pass 32 MB, when the file in the worktree no
  longer matches the patch's context and added lines (the agent edited it
  meanwhile, a clean filter), or when a brace, a multi-line string or a
  comment doesn't close on either side: a bare `/regex/` literal, which
  reads as code, does that when it holds a brace, and so do `#if` branches
  that each open a brace (which Swift rejects). A CRLF file whose patch
  shows LF (`eol=crlf`) still matches. An edit to a line the patch doesn't
  show isn't seen until the next refresh, which the edit itself triggers.
- **Mentions.** The test files are listed by git (`ls-files --cached --others
  --exclude-standard`, untracked tests included), Swift files first, and read
  up to 4,000 files, 1 MB each and 32 MB in all; reading stops once every name
  is found. A file cut short loses its last word, which may be a longer one.
  The header says how many test files went unread (past the limits, a
  symlink, outside a sparse checkout; not one the worktree deleted) while a
  name was still missing, and when git couldn't list them. A binary file (a
  NUL in its first 8,000 bytes, as git tells them apart: a snapshot image, a
  fixture) isn't a test's text: it is read that far only, and counts toward
  the files read but not as unread. A submodule's folder is skipped.

The rules start built in, for Swift and macOS. Per-project rules
(`board.json`) can come later.

## 6. Acting on the page

### 6.1 Comments

- On a line or a range of one hunk, up to 100 rows: the gutter button, or a
  selection. On a file: the file row's Comment button. A comment is plain
  text, up to 20,000 characters and 80,000 bytes.
- **Drafts.** What is typed is a draft, stored as it is typed: it outlives a
  Reload, the column closing and a crash. The Comment button makes it a
  comment, ready to send. Only comments go to the agent, never drafts
  (section 6.2). An unsent comment can be edited and deleted. A sent one
  stays under its line, read-only, marked "Sent at db9ac66", and can only
  be deleted. (Decided by the user on 2026-10-04.) The page saves a draft a
  moment after the last key, and sends a pending save before Comment, Save
  or Cancel; the column applies them in order: a save arriving after them
  would bring the draft back.
- Stored locally (section 8), anchored to the path and to the rows it covers,
  each with its kind (added, removed or context), its line in the base's
  file and in the working tree's (what `@pierre/diffs` numbers on its
  `deletions` and `additions` sides) and its text, and with the text of the
  two rows above and below. A row's text is kept up to 1,000 characters and
  4,000 bytes, with a hash of the whole line when it is cut, and a
  comment's rows and context up to 32,000 bytes: past that, the range can't
  be commented, and a landmark (below) that doesn't fit with them is left
  out. Not the file's patch hash: it leaves line numbers out, and a
  merge from the base moves lines without changing it. A draft's anchor is
  fixed when it is first saved: the diff may change while the user types.
  With the anchor are kept the best score of a near copy, how many frames
  stood elsewhere, and for copied code its rank and landmark (below): a
  change to how they are scored needs a new `version` of the file
  (section 8).
- **Following the lines.** Each read looks for the rows in the diff: the
  same kinds and texts, in a row, within one hunk. A comment under the wrong
  line is worse than one marked outdated, so a run counts only with
  evidence, and when no other is as likely:
  - a context row is evidence only when it holds a letter or a digit (`}`
    and blank lines are everywhere). Each of the comment's found among the
    run's three nearest rows on its side is a hit; each missing, where the
    rows reach as far as it was, a miss. The score is hits less misses;
  - a run needs a score above 0, and above the best score another run
    that reads as its rows had when the comment was made or last found (a
    near copy, with some of its context: it must not take the comment once
    its own code is rewritten or deleted). A comment found elsewhere is
    made again there: its near copies are counted where it is now;
  - where the nearest context rows that hold a letter or a digit, above
    and below, still stand about as far apart around other rows (a
    frame), the rows were rewritten or deleted there: a frame where the
    rows were leaves the comment outdated; frames elsewhere, when there
    are more of them than when it was made or last found, bar any run that
    doesn't score above them (scored as a run there would be). Another
    test's frame there then doesn't count, but one added since does: a
    test of the same shape added leaves the comment outdated, even
    untouched, rather than risk the wrong line. The comment's own rows, unchanged where they were,
    don't stand as a frame (two lines alike, one under the other);
  - or a run is where the rows were (at the line the page showed), with
    neither hit nor miss, the only run that reads as its rows, and no
    frame;
  - of the runs with the best score, the only one; or the one where the
    rows were, when something around it changed (an unchanged twin is
    code copied since). Two leave the comment outdated, and so does
    another run where the rows were that nothing contradicts;
  - a comment made on copied code, where another run read as its rows with
    all its context, is found among the runs nothing around contradicts:
    by its landmark, the nearest row above found nowhere else in the
    file's diff (`func testB() {`), with the rows between, when its rows
    hold a letter or a digit and one is within 8 rows; otherwise by its
    rank, while the copies' number is the same, the copy at that rank
    where the rows were, or at their line of the base with no other copy
    where they were. Within added code every copy has the same line of the
    base: its own rewritten while another is added after it passes for it
    (as well as lines added above it keep it in place).

  It is looked for from where it was made, which is never rewritten, and
  from where it was last found, which is recorded when the rows, or those
  around them, aren't as they were made, and only if it finds the comment
  there again. When they find different places, the better evidence wins,
  and as good leaves it outdated. Not found, it is "outdated": it keeps its rows as an
  excerpt, and is looked for again at the next read. A comment whose file
  no longer differs from the base says so; one whose file's hunks aren't
  read yet (section 7, "Size") is placed once its row opens; one whose file
  is too large to show stays with its file. A comment on a file lasts as
  long as the file differs from the base. A file the diff shows renamed
  keeps its comments; one the branch added, then renamed, reads as gone. A
  line that isn't UTF-8 compares as it reads, with U+FFFD where it isn't.
- **In the column.** The page asks by ids: save a draft, make it a
  comment, edit, cancel, delete. A new comment's place goes with its saves
  until its draft exists: the file's id, and the rows the user chose (`{
  side, line }` as `@pierre/diffs` numbers them) or that it is on the whole
  file, and the page they were chosen in (its generation). Swift makes the
  anchor from the file's diff as that page's data had it (a file read on
  demand, once its row read it): the branch's page, or one of its last 3,
  which a new read may have replaced before the first save. Rows chosen
  on another branch's page or an older one, or that can't take one comment
  (two hunks, past 100 rows or 32,000 bytes), aren't saved; nor is a new
  comment or draft past 1,000 in a review, or once the review file holds
  6 MB (three quarters of its limit: Reviewed marks, edits and deletes
  still fit). Each request is written in order and answered, saved
  or not, and never before the writes asked for before it; one that wasn't
  saved, refused or not written, says why, by the click it answers, while
  the branch shows. The
  page gets each comment, and each new comment's draft, placed: under its
  last row, or listed with its file with its rows as an excerpt when they
  aren't in the diff, its file gone, or its hunks not read yet. An unsent
  comment comes with the edit under way. Placing is done again only for
  what moved or is new, not for a draft's text, nor, after a new read of
  the branch, in the files it left as they were. Where comments moved to
  is recorded once the review opens (all of them) and once a file's diff
  is read (those on it), only in a review that has comments, and not once
  another column opened the review at another head since: where they are
  is that head's to say. A request that changes nothing never creates the
  review file.
- Not posted on GitHub. Posting a review there can come later.

### 6.2 Sending comments to the agent

**Send N Comments to Agent** builds one message from the unsent comments and
types it into the agent's prompt as a bracketed paste, without Return, as
"Send Selection to Agent" does (`AgentExcerpt`) and as "Ask Agent to Resolve"
will (`docs/project-board.md`, section 3.3). The user reads it, can add to it,
and submits it.

```text
Review comments on feat/keep-awake (head db9ac66), from Nirux:

1. Sources/Nirux/Views/NiruxShellView+KeepAwake.swift:42
   > guard ptys.contains(where: { Self.needsBackgroundRefresh($0, now: now) }) else { return }
   When this guard returns early, nothing calls updateKeepAwake(): a Claude
   interrupted with Esc keeps the assertion while Nirux is in the
   background. Call updateKeepAwake() before returning, and add an
   end-to-end test.

2. Sources/Nirux/NiruxApp.swift (file)
   Nothing tests setUpKeepAwake or the shutdown on quit. Add a test, or say
   why not.

Address each comment, run the tests, commit and push. If a comment is wrong,
say why and change nothing for it. Then say what you did for each number.
```

- **Target:** an agent column whose process runs inside the reviewed worktree:
  the only one, or the one the user picks from a menu. Opened from the main
  checkout, the page never offers the coordinating agent of another worktree.
- **"Idle at its prompt" is a new predicate.** `PtySession.agentResumeRefusal`
  doesn't fit: it refuses any agent without a failed turn, and any agent but
  `claude`. The new one keeps its at-prompt checks without the failed turn:
  the foreground process is `claude` driven by Nirux's hooks (`hookKind ==
  "claude"`, and not headless as `AgentHookCenter.isHeadlessClaude` reads it),
  no dialog is pending, no hook says it is working and no turn has started.
  Closing a column or a workspace already trusts "idle" only on that same
  condition (`WorkspaceClosePolicy.LiveAgent`: `processName == "claude" &&
  hookKind == "claude"`). Every other agent is
  refused, with the reason: Codex's notify hook reports turn ends only, so an
  open approval prompt would read as idle; Gemini CLI and OpenCode report
  nothing. It is checked when the sheet opens and again on Send: a Telegram
  prompt or a merge-queue prompt may start a turn meanwhile.
- **Drafts don't go.** The sheet says how many it leaves out. Sending a
  comment that is being edited sends it as it was saved; the edit becomes
  the draft of a new comment where it is, so nothing typed is lost, and
  the editor goes on as that draft. An edit that changed nothing goes.
- **Lines in the message.** A comment's quoted rows show their line breaks
  (CR, U+2028, U+2029) and invisible characters as code points, as the page
  does, so a quoted line can't end the quote and read as the user's. A
  removed row is named as the base's line ("removed, line 42 of main"), and
  an outdated comment is sent as outdated, with its excerpt and no line
  number.
- **The message is sanitized as a whole**, paths and quoted lines included,
  by the scalar filter of `RemotePromptSanitizer`, factored out: keep `\n` and
  `\t`, turn `\r` and `\r\n` into `\n`, drop the other C0 controls, DEL and
  C1. Not its `sanitize` as is, which also trims and caps at 8,000 Unicode
  scalars, nor its `terminalInput`, which appends a Return:
  the message is wrapped in `ESC[200~` and `ESC[201~` with nothing after, as
  `sendSelectionToAgent` does. A file named with an ESC[201~ can't end the
  paste and inject a Return. In the sheet, bidi and
  zero-width characters are shown escaped, so what the user reads is what is
  sent.
- **A queued PR:** if the PR is in the merge queue, the sheet warns that the
  agent's push will stop the queue (`docs/project-board.md`, section 3.2).
- Claude Code collapses a long paste into "[Pasted text #1 +14 lines]", so the
  sheet is where the user reads what goes out.
- Sent comments are marked "sent", with the time and the head commit.

Rejected:

- **Writing the comments to a file in the worktree** and typing a one-line
  prompt that names it. It is one more untracked file an agent can commit by
  mistake, like the handover. A file outside the worktree makes Claude ask
  for permission to read it.
- **Pressing Return for the user.** A half-typed draft in the agent's prompt
  would go out with it.

### 6.3 Reviewed

- One checkbox per file, keyed by the file's **patch hash**: a hash of its
  path (both paths for a rename), its status, its mode change, and the `-` and
  `+` lines of its hunks, in order, from the merge base to the working tree.
  Context lines, the whole `@@` line (ranges and the enclosing function's
  name), and the `diff --git`, `index` and similarity lines are left out: they
  change when the base changes the file elsewhere, even next to a hunk. A
  change to the branch's own lines clears it: "changed since you reviewed". A
  merge from the base keeps it unless it changed those lines, and an
  uncommitted edit clears it.
- The header counts reviewed files ("Reviewed 4 of 16 files"), and each
  group its own. Ticking a file folds its diff, as GitHub's "Viewed" does.
  Each group has a checkbox that marks every file of it not marked yet, or
  clears them all once all are. (Decided by the user on 2026-10-04.) A file
  whose patch wasn't read (section 7) can be marked once its row opens and
  reads it; a mark Nirux can't check for that reason still counts.
- The column opens the review file (section 8) when it shows a branch, and
  writes it off the main thread, in order, with the access `open` gave;
  changes asked for while a write runs are written together. A same-head
  refresh with the file unchanged doesn't open it again, unless the last
  open failed in a way that may pass (git, the lock) or the column wrote
  since. A review opened at
  another head since (another Nirux, Explain): at an older head, it is
  opened again at the page's and written; at a later one, written as it is,
  its head kept (a mark carries its own head); at a head neither before nor
  after, not written. A write that would create the review asks the
  repository first (its common folder, which outlives a worktree Clean Up
  deleted) whether the branch still exists, by its exact name: once gone,
  nothing is written until the branch is read again. A review that is
  read-only, or couldn't be opened, disables the checkboxes, and the page
  says why. The page shows each click at once, until Swift answers it: a
  write that fails undoes the click.
- **A new head never re-renders the page under the user.** A banner offers
  Reload; drafts survive it.
- Later: "Changes since my last review", and the review state on the merge
  queue's confirmation sheet ("reviewed at db9ac66, 2 files changed since, 1
  comment unanswered").

## 7. Data and refresh

- **Git.** Every call runs with `GitDetect.readOnlyEnvironment`
  (`GIT_OPTIONAL_LOCKS=0`). That is not enough for `git diff`: with or without
  a tree-ish, it refreshes the index, which also fires the watcher
  (`GitCommand.swift` says so). Every `git diff` therefore runs with `-c
  diff.autoRefreshIndex=false` (checked: the index is left untouched), and an
  entry without a hunk, a mode change or a rename, which only a stale
  timestamp can produce, is dropped. Patches also use `-c core.quotePath=false
  -c diff.suppressBlankEmpty=false --no-color --no-ext-diff --no-textconv
  --src-prefix=a/ --dst-prefix=b/ -M -l1000 -U3 --inter-hunk-context=0
  --diff-algorithm=myers --indent-heuristic --submodule=short --no-relative`,
  so the user's git config doesn't change the patch or its hash. Paths come
  from `--name-status -z`; the patch parser still reads C-quoted paths.
  Output is decoded per file, lossily: one Latin-1 file must not empty the
  page (`GitCommand.output` returns an empty string for non-UTF-8 output).
- **Base.** With a PR, the merge base of HEAD and the PR's base branch, fetched
  on Refresh: `git fetch --no-auto-maintenance --no-write-fetch-head origin
  <baseRefName>`, with `GIT_TERMINAL_PROMPT=0` and a timeout. Nirux has never
  fetched before. This updates one remote-tracking ref; it is the page's only
  write to the repository. Without one, the merge base
  with the remote's default branch (`origin/HEAD`), else `main` or `master`.
  Not `GitCommand.branchBaseRef`, which tries `@{upstream}` first: after `git
  push -u` with no PR yet, that is the branch's own remote, and the page would
  show only unpushed commits. The diff runs from the merge base to the working
  tree. Untracked files (`git ls-files --others --exclude-standard -z`) are
  read from disk and shown as added files.
- **Which PR.** Found as the sidebar finds it (`PRDetect`: `gh pr list
  --head <branch>` on the upstream repository), then kept only if it is open
  and at least one of its commits (`gh pr view --json commits`) is in HEAD's
  history and not in the base's, or its head (`headRefOid`) is in the branch's
  reflog: after a local rebase not pushed yet, none of the PR's commits is in
  HEAD's history. A merged or closed PR, or one under a reused branch name, is
  ignored. The PR's head may not be local (the merge queue
  updates branches on GitHub): the header then says the PR has commits the
  worktree doesn't. `gh` missing or logged out: the page works without the
  PR, and says so.
- **Local against PR:** when the local head isn't the PR's head (unpushed
  commits, or a branch updated on GitHub by the merge queue), the header says
  so.
- **Refresh.** The column watches its own worktree with a
  `GitRepositoryWatcher` (the workspace's watcher follows the focused
  column's folder and is suspended in the background), from the moment it
  starts. A change reads the branch again once changes stop for a moment
  (2 s for files, 0.5 s for git's own), at 8 s at the latest during a burst
  that never stops (a build), and never sooner after the last read than
  that read took. Each read in a row that finds nothing new doubles that
  8 s, up to 64 s: a build writing in an ignored folder. Watched reads run
  at utility priority. The read asks gh only after the remote branch moved
  (a push); otherwise it reuses the pull request found before. A new head
  shows the Reload banner, and the page stays as it was. The same head
  updates the page:
  - the row or group the reader is at keeps its place on screen;
  - open diffs whose patch and merge base didn't change stay as they were;
    a changed one stays, dimmed, until its new diff comes;
  - while the user has text selected in the page, the update waits for the
    selection to go.

  A read that changes nothing leaves the page alone, and clears a banner
  whose cause went away. A read that fails keeps the page, under a banner.
  A failed fetch stays noted until the next Refresh. Off screen, the column
  only marks itself stale, and reads once it shows. Refresh re-reads
  everything, the pull request included. No polling of `gh` in the
  background.
- **Rebase or switch.** During a rebase or a merge, a page already shown
  stays, under a banner; a column without one says so instead. If the
  worktree is now on another branch, a banner offers to review it in this
  column; its button reads the worktree again first, in case it came back.
- **Size.** Files over 400 KB get a placeholder, as in the editor's stacked
  diff (`EditorColumn.maxDiffCollectionFileBytes`). Above 5 MB of diff in
  total, the page lists the files and loads a diff when its row is opened.
  The page asks for every file's diff when its row opens: the snapshot keeps
  the hunks of the files within these limits, so they come at once, and
  only the others are read then. The page's data is the files' list, not
  their diffs.

## 8. Storage

- One file per reviewed branch: `<state dir>/reviews/<branch>-<hash>.json`,
  where `<branch>` is percent-encoded (cut at 120 bytes) and `<hash>` is a
  short hash of the repository and the exact branch name. The repository is
  its common git folder (`git rev-parse --git-common-dir`, symlinks
  resolved), which every worktree shares: two repositories can each have a
  `main` or a `feat/x`, and must not archive or delete each other's review.
  The exact name, because APFS is case-insensitive: `Fix/A` and `fix/a` must
  not share a file. The file isn't per project: a workspace moved to another
  project keeps its review, and a worktree open in two projects has one.
  Moving or renaming the repository's folder starts its reviews fresh; the
  old files stay. `NIRUX_STATE_DIR` moves them. (Validated by the user on
  2026-10-03; this section first named the file after the branch alone, in a
  folder per project.)
- It holds the comments, drafts, reviewed marks, what was sent, the
  explanation cache, each Explain run's usage, the PR number and the last
  head the review was opened or written at. Comments and drafts are keyed
  by an id the page makes (letters, digits and `-`, up to 64): a write
  changes only the entries it is about. It keeps the keys a later build
  added to an entry, to where its comment was made (never rewritten) and to
  its "sent" mark; where a comment was last found is rewritten whole. A reused branch name must not
  inherit old comments. The file is kept when its last head is the branch's
  head, or one of the branch's own commits (in HEAD's history and not in the
  base's: the branch moved on from it). Otherwise, when both the file and the
  branch have a PR, it is kept only if the numbers match. Otherwise it is kept
  when its last head is in the branch's reflog (`git reflog
  refs/heads/<branch>`, the head before the oldest entry included: a
  worktree's branch created from a bare repository doesn't log its creation).
  `git branch -D` deletes the reflog, a rebase keeps it. A file not kept is
  archived (moved to `reviews/archive/`, where it stays) and the review starts
  fresh. So a new PR for the same commits keeps the review, and a review is
  never archived for want of `gh`; if git can't answer, the review opens
  read-only until a Refresh can. Three limits: `git checkout -B` or `git
  switch -C` from another commit reuses a name and keeps its reflog, so only
  the PR number catches that reuse; a name reused at the very commit last
  reviewed (merged by a local fast-forward, deleted outside Clean Up, made
  again from the base) keeps the review until a different PR appears; and a
  reflog entry expires 30 days after the branch moved to it once a rebase
  left it unreachable (`gc.reflogExpireUnreachable`), so a review last opened
  at a head that old, then rebased with no PR to match, is archived. Opening
  a kept review records the head and the PR it was opened at.
- Writes take an exclusive `flock` on a sibling `<file>.lock`, held across
  read, merge and write: the installed app and a dev build can share the
  state directory, and a lock on the data file itself would be lost when the
  file is replaced atomically. A write waits up to 10 seconds for it (a
  holder stopped in a debugger must not hang Clean Up), and git never runs
  while it is held. A writer that waited checks it locked the file still at
  that path, since Clean Up deletes it.
- Only a review opened with the checks above can be written: a write fails
  if the review it opened was deleted (Clean Up), archived or opened at
  another head since, and the page opens it again. A page that opened a
  branch never reviewed must stop writing once its branch is gone, or its
  first write creates the review again.
- A `version` field. A file from a newer version opens read-only, so an older
  build never drops keys it doesn't know. Within a version, a build keeps the
  top-level keys it doesn't know, so a later part (R3 to R5) can add its own
  without a new version; a key whose meaning changes needs one. A file that
  isn't a review (not a JSON object, or a `version` that isn't a number) is
  set aside by the first write. A file that can't be read right now, a link
  or a folder in its place, or a file over 8 MB is never set aside or
  replaced.
- Clean Up of the worktree deletes the file and its lock once the branch is
  deleted. A branch Clean Up keeps keeps its review; archived files stay.

## 9. Plan

One pull request each. Explain comes third, before comments: understanding a
branch is the point, and acting on it is worth building only if the page gets
used.

1. **R1, review data, no UI.** The snapshot builder (git as in section 7, and
   `gh` through an injectable runner: CI has no `gh` login), base and PR
   selection, noise classification, path groups, risk rules, tests against
   code, the patch hash, and the versioned storage file with its lock, which
   Clean Up of the worktree deletes. Pure and unit-tested.
2. **R2, the column, read-only.** `ColumnKind.branchReview`, `review.html` and
   its safety rules (section 1.1), the summary, the risk chips, the groups and
   the diffs. The column's watcher, Refresh, the stale state, the Reload
   banner and the pause during a rebase or a switch. "Review Branch" in the
   palette and the sidebar menu, listed in the UI flow harness, and the
   editor's native banner with its own flow test. The `@pierre/diffs` wrapper
   source, its `package.json` and lock, and a build script that records the
   hashes of the sources and the bundle; a test fails when the bundle no longer
   matches them, since CI doesn't build JavaScript. The editor's diff tab must
   render as before. It ships in three pull requests: the wrapper (#103), the
   column and its page, then the watcher, the stale state, Reload, the pause
   and the editor's banner.
3. **R3, Explain.** `BoundedProcess`'s extensions, the run of section 4.3, the
   copy, the account check, the settings (model, effort), the first-use
   notice, the cache, the checks on the output, the claims, the usage line.
   Run on five merged PRs before its defaults are frozen. It ships in three
   pull requests: the engine without network (`BoundedProcess`'s extensions,
   the copy, the input), then the run (account, output checks, cache, the
   five PRs), then the page and the settings. The page ships in three
   (decided by the user on 2026-10-05): Explain on the page (its button and
   states, the account check and the notice, the queue and Cancel, the
   overview, claims, questions, intent groups and summaries, the usage line,
   and stopping a run on Clean Up, on closing the column and on quitting),
   then the model and effort settings, then the notes under the hunks and
   marking them wrong. A file changed since it was explained keeps its
   summary, dimmed and marked so.
4. **R4, comments and reviewed marks.** Drafts, re-anchoring, outdated
   comments, and turning a "check this" note into a comment. It ships in
   four pull requests (decided by the user on 2026-10-04): the comments'
   model, with drafts, anchors and re-anchoring, without UI; the reviewed
   marks, with the review file wired into the column (a file's checkbox,
   which folds its diff, a group's that marks all its files, the progress);
   the comments on the page, after the wrapper's annotations, gutter
   button and selection, on their own, in two (the column's side: the
   comments in the page's data, the requests and their writes; then the
   page itself); then a "check this" note turned into a comment, once
   Explain's page has landed.
5. **R5, sending to the agent.** The "idle at its prompt" predicate, the
   sanitizer, the message, the target rules, the sheet; shared with "Ask Agent
   to Resolve" if it has landed.

After R3, the user decides whether R4 and R5 are worth building.

Later: changes since the last review, the review state on the merge queue's
sheet, posting to GitHub, per-project risk rules, the Project Board's "Review"
button.

### 9.1 Tests

- Work that ends off the main thread (git, `gh`, `claude -p`, the bridge) is
  tested through a fake that completes on a background queue, so a main-actor
  closure called from the wrong thread traps in CI (Swift 6.1, as the nightly)
  rather than in the nightly (#48).
- Tests that touch main-actor types are `@MainActor`. AppKit clicks go through
  `hitTest`, then `mouseDown` for a custom view or `performClick` for an
  `NSButton`; windows set `isReleasedWhenClosed = false`.
- The page is tested on the JSON Swift sends, and on its pure functions under
  JavaScriptCore (`JSContext`), with crafted strings: a PR body with HTML and
  links, a path with ESC and bidi characters. `@pierre/diffs`'s escaping is
  tested on the same strings through `renderPartialHTML`'s output, in a
  `WKWebView` that loads the committed bundle (`PierreDiffRenderTests`).
- Explain is tested against a fake `claude`; the real CLI runs only by hand,
  on a dev build with `NIRUX_STATE_DIR`.
