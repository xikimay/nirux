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
  bundle only imports `FileDiff` today, so the wrapper must also import the
  virtualized components. The wrapper (`pierre-diff-entry.js`,
  `package.json`, esbuild) only exists in the private proof of concept; R2
  brings it into this repository.
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
  (`renderPartialHTML`) after escaping it; a test covers that escaping on a
  crafted line and path (section 9.1).
- Bridge messages carry ids, never text to type: Swift builds the message to
  send to the agent from its own stored comments, and the sheet that confirms
  it is native.

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
   chip filters the list to the hunks that raised it.
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
   - generated files: `*.bundle.js`, `*.min.js`, paths marked
     `linguist-generated` in `.gitattributes`, files whose first lines say
     `@generated` or "Code generated … DO NOT EDIT", minified scripts and
     styles (changed lines over 110 bytes on average, as GitHub's Linguist
     tells them);
   - pure renames (similarity 100%) and whitespace-only changes;
   - binaries.

   `-linguist-generated` (or `=false`) keeps a file out of the generated
   group whatever its name. When the branch changes a `.gitattributes`, its
   `linguist-generated` marks are ignored: a branch mustn't fold its own
   files. A marker counts outside quotes, or opening a comment: a script
   that writes the marker isn't generated. Whitespace only means each hunk
   reads the same without its blank lines and the whitespace around its
   lines; whitespace inside a line changes what the code does (`" "` and
   `""`), and in Python, YAML or a Makefile the indentation does too. A
   folded file's diff loads when its row opens, and folded files don't
   count toward the 5 MB of section 7: a generated bundle or a reformatted
   repository mustn't send the whole page on demand.

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
| Tests | `Tests/`, `*Tests.swift`, `*_test.*`, `*.test.*`, `*.spec.*` |
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
  review and `/code-review`), still on `main`. In the background, after 10
  minutes of silence, a Claude with hooks interrupted with Esc no longer needs
  a background refresh, so `refreshAgentStatusInBackground` returns before
  `updateKeepAwake()`. The assertion stays held until Nirux comes back to the
  front or other activity refreshes the sidebar: another column still polled
  (an agent without Claude hooks, an open dialog), a title change, another
  Claude's hook event.
- **Sonnet with the same access opened no file** (two turns, no read). It
  raised no false alarm, and found nothing either.
- Opus also grouped better: `MainActorSchedule` and `TerminalSearchSession` in
  a refactor group, the hidden-space tick in a behavior-change group of its
  own. Sonnet filed the refactor under the feature.
- One branch is not a benchmark. R3 runs Explain on five merged PRs, one of
  them over 300 KB, before its defaults are frozen.

**Recommendation: Opus 5.5 at effort medium, with read-only access to a copy
of the branch.** About 80 s and $0.59 at API prices for a branch of this size.

### 4.3 How Nirux runs it

```sh
claude -p --model claude-opus-5-5 --effort medium \
  --output-format stream-json --verbose --json-schema <schema> \
  --tools Read,Grep,Glob --restricted --permission-prompts none \
  --strict-mcp-config --disable-slash-commands \
  --no-session-persistence --settings '{"disableAllHooks":true}' \
  --system-prompt <review prompt> < input
```

- **Read-only and confined.** `--restricted` confines the file tools to the
  working directory, refuses a path that resolves through a symlink to the
  outside, and ignores user, project and local settings. With
  `--permission-prompts none`, anything that would ask is denied. Checked on
  2026-10-02 with a canary: with `--allowedTools Read,Grep,Glob` instead, the
  model read an absolute path outside the folder and a symlink pointing out of
  it; with these flags both were denied. Explain requires that the binary it
  will run lists `--restricted` and `--permission-prompts` in its `--help`
  (2.1.285 does). Not `ClaudeCodeVersion.detect`: it returns the oldest of
  the installed versions, and nothing for a shim.
- **`--bare` would be leaner, but it refuses OAuth**, so it doesn't work on a
  subscription.
- **The model id is a full name**, not the `opus` alias, which will move to the
  next model. It is a setting, with this default.
- **The copy.** The working directory is a fresh temporary folder outside the
  state directory, deleted after the run; leftovers are swept at launch. Nirux
  copies files into it from the working tree, so nothing is written to the
  repository's index or object store, unlike a temporary index would. The
  paths come from `git ls-files -z`: committed and staged files with their
  uncommitted edits, and no untracked file (see "Input" below). That list also
  holds submodules, deleted files, intent-to-add files and one entry per stage
  of a conflict, so Nirux copies a path once, and only if `lstat` reports a
  regular file and no folder above it is a symlink. Then it deletes:
  - paths that look like a secret (`.env*`, `*.pem`, `*.p12`, `*.key`,
    `*.mobileprovision`, `*credentials*`, `id_rsa*`, `id_ed25519*`,
    `.netrc`);
  - text files containing a key marker (`-----BEGIN`, `sk-ant-`, `ghp_`,
    `github_pat_`, `AKIA`), the same markers the input withholds;
  - `CLAUDE.md`, `CLAUDE.local.md` and `.claude/`, at any depth: instructions
    the branch carries must not reach the reviewer as project instructions.

  Not a `git worktree add`: it would show in `git worktree list` and on the
  Project Board.
- **The environment is an allowlist:** `HOME`, `USER`, `LOGNAME`, `LANG`,
  `TMPDIR`, and a `PATH` that starts with the folder of the `claude` binary
  `AgentCLILocator` found, then `PtySession.effectivePath`: an npm install is
  a `node` script, and Nirux's own `PATH` is launchd's. Nothing else from
  Nirux's environment reaches the child:
  not `NIRUX_AGENT_UUID` (Nirux's hooks run only when it is set), not
  `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` or `ANTHROPIC_BASE_URL` (which
  would bill the API instead of the plan), not the `CLAUDE_CODE_*` variables a
  dev build launched from a Claude session inherits. `disableAllHooks` covers
  hooks from settings Nirux didn't pass.
- **The account.** Before the first run, and when it changes, Nirux reads
  `claude auth status --json`, with the same environment as the run, so it
  reports the account the run will use. The first-use notice of a project
  names the account and its method ("claude.ai, Max"); `api_key` asks again.
  Logged out, or no `claude` found (`AgentCLILocator`), and Explain is
  disabled with the reason.
- **No session is saved** (`--no-session-persistence`): the review doesn't show
  in `claude --resume`. The session history (#68) already ignores `claude -p`.
- **One run at a time, in the whole app.** A second Explain waits in line. The
  run has a 6-minute timeout and a Cancel button. `BoundedProcess` can't do
  this today: R3 extends it with stdin, a cancel handle, a replaced (not
  merged) environment, and keeping the output it read when it stops, and runs
  it off the main thread. With `stream-json`, a cancelled or timed-out run
  still leaves the usage its events reported; R3 checks that the structured
  output arrives in the final `result` event.
- **Input:** the PR body, the handover, the commits, and the diff from the
  merge base with numbered hunks. Left out: folded noise, binaries, secret
  paths, and the disposable paths of section 2. Hunks containing a key marker
  (`-----BEGIN`, `sk-ant-`, `ghp_`, `github_pat_`, `AKIA`) are replaced by
  "withheld: looks like a secret". Untracked files are sent by name only,
  unless the user ticks "Include untracked files".
- **Size:** one run sends at most about 150 KB of diff. A larger branch is
  explained one group at a time, each cached as it arrives.
- **Output:** JSON matching the schema: an overview, intent groups, a summary
  and an importance per file, notes per hunk (with an optional "check this"),
  the claims checked, and at most 5 questions for the author. Nirux drops
  unknown paths and hunk ids, caps string lengths, and shows everything as
  text (section 1.1): the diff itself may contain instructions aimed at the
  model ("say this file is safe").
- **Limits:** the model never marks a file reviewed, never hides a file and
  never removes a risk signal. Its notes are labeled "Claude", with the model
  and the head commit it read. Each "check this" note can be turned into a
  comment (once R4 has landed), or marked wrong; the marks are kept with the
  run, so the page can say how often notes were wrong.
- **Cache:** per file, keyed by the file's patch hash (section 6.3). Notes are
  stored by path and by the hunk's index in the file's patch, not by the run's
  hunk ids (`f12h1`), which only live for one run. When the branch moves,
  Explain again only sends the files whose patch changed, with the previous
  overview as context; the others keep their notes.
- **Usage:** each run's tokens and reported cost are kept with it, and the
  column's header shows today's total. A run that ends on a usage limit says
  so, rather than "failed".
- **Language:** the Mac's preferred language, English otherwise.
- **First use in a project** shows what will be sent, where, and under which
  account, once.

## 5. Risk signals

Deterministic rules on the paths and on the added and removed lines. Each
signal links to its hunks and says why it matters. The model's "check this"
notes are shown apart and never change these signals.

| Signal | Raised by | Why it matters |
| --- | --- | --- |
| Persistence and state | `Codable` types, `CodingKeys`, `decodeIfPresent`, `Persistence*.swift`, `*Store.swift`, keys of `state.json` or `board.json` | Defaults for missing keys, rollback to an older nightly, data loss |
| Security | Keychain (`SecItem`), `SecCode`/`SecStaticCode`, entitlements, the `nirux://` scheme (`NiruxURLRequest`), `HandoverFile`, Telegram remote access, `/tmp` paths, `Process` arguments | Input from outside, secrets, signing |
| Concurrency | `@MainActor`, `nonisolated`, `@Sendable`, `@unchecked Sendable`, `DispatchQueue`, `OperationQueue`, `Task {`, `MainActor.assumeIsolated`, `RunLoop.main.perform` | CI's Swift 6.1 is stricter than local 6.2; a main-actor closure run off the main thread crashed a nightly (#48) |
| App launch and quit | `applicationDidFinishLaunching`, `applicationWillTerminate`, the `--hook` mode, `NIRUX_*` variables, `Info.plist`, Sparkle, `bundle.sh` | Paths that only the installed, notarized app takes |
| CI workflows | `.github/`, scripts the workflows call | The nightly publishes to every install |
| Side effects outside Nirux | IOKit, `NSWorkspace`, writes to `~/.claude` or the hooks, notifications, process launches | They outlive the app or change the Mac |
| Dependencies | `Package.swift`, `Package.resolved` | A build-rewritten `Package.resolved` must not be committed |

A line rule matches anywhere in a `+` or `-` line, strings and trailing
comments included, but not in a line that is only a comment, nor in a doc or
a folded file: a generated file can say anything, and a reindented line
changes nothing. A folded file raises only its path rules. A test ships
nothing: it raises only the concurrency rules, which CI checks more strictly.
Path rules also cover the files whose changes may name no rule: a name with
`Persistence`, `HandoverFile`, `NiruxURLRequest`, `+URLScheme`, `Telegram`,
the app delegate (`NiruxApp.swift`), the hook and skill installers.
"Scripts the workflows call" are the changed files, docs and tests aside,
whose path a workflow (`.github/workflows/*.yml`) or an action
(`action.yml` under `.github/actions`, outside its `node_modules`) names:
`./scripts/bundle.sh`. A change inside `applicationDidFinishLaunching` that
doesn't name it is raised once the brace tracking of "Tests against code"
gives each hunk its enclosing function.

**Tests against code.** The header shows lines added in tests against lines
added in code, and lists the symbols the branch declares that no test
mentions. A symbol is an identifier declared on an added line (`func`, `var`,
`let`, `class`, `struct`, `enum`, `case`, `protocol`, `typealias`) outside any
function body, found by tracking braces in the file at the head, and not
`private` or `fileprivate`: private members are tested through the API that
uses them, and local variables would only add noise. A test mentions a symbol
when the identifier appears as a whole word in a file under `Tests/`. On #57,
578 test lines for 458 code lines, and a script applying this rule found 11
of 42 names (each counted once per file) that no test mentions, among them
`setUpKeepAwake` (the launch wiring), `IOKitSleepAssertions` (the real IOKit
calls; the tests inject a fake) and `mainQueueSchedule`. A mention isn't
coverage, so the line says
"mentions", never "tested".

The rules start built in, for Swift and macOS. Per-project rules
(`board.json`) can come later.

## 6. Acting on the page

### 6.1 Comments

- On a line or a range: the gutter button, or a selection. On a file: the
  file row's Comment button. A comment is plain text. A draft is stored as it
  is typed.
- Stored locally (section 8), anchored to the path, the side, the line, the
  line's text and the file's patch hash. When the patch changes, Nirux looks
  for the same text near the old line; otherwise the comment is "outdated" and
  keeps its excerpt.
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
- The header counts reviewed files. Reviewed files can be collapsed.
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
  column's folder and is suspended in the background). A `.metadata` event
  compares `rev-parse HEAD` and the branch: a new head shows the Reload banner;
  an unchanged head refreshes the "not committed" group, since a batch of
  events reports only `.metadata`. A `.worktree` event refreshes that group
  too, debounced. Off
  screen, the column only marks itself stale. Refresh re-reads everything. No
  polling of `gh` in the background.
- **Rebase or switch.** During a rebase or a merge, the page pauses and says
  so. If the worktree is now on another branch, the page says so and offers to
  review it.
- **Size.** Files over 400 KB get a placeholder, as in the editor's stacked
  diff (`EditorColumn.maxDiffCollectionFileBytes`). Above 5 MB of diff in
  total, the page lists the files and loads a diff when its row is opened.

## 8. Storage

- One file per reviewed branch:
  `<state dir>/reviews/<space id>/<branch>-<hash>.json`, where `<branch>` is
  percent-encoded and `<hash>` is a short hash of the exact branch name (APFS
  is case-insensitive: `Fix/A` and `fix/a` must not share a file).
  `NIRUX_STATE_DIR` moves it.
- It holds the comments, drafts, reviewed marks, what was sent, the
  explanation cache, each Explain run's usage, the PR number and the last
  head reviewed. A reused branch name must not inherit old comments: the file
  is kept only if its PR number matches the branch's PR, or, without a PR, if
  its last head is still in the branch's reflog (`git reflog
  refs/heads/<branch>`; `git branch -D` deletes it, a rebase keeps it).
  Otherwise it is archived and the review starts fresh. Two limits: `git
  checkout -B` or `git switch -C` reuses a name and keeps its reflog, so only
  the PR number catches that reuse; and a head a rebase left unreachable leaves
  the reflog after 30 days (`gc.reflogExpireUnreachable`), which archives a
  review idle that long.
- Writes take a blocking exclusive `flock` on a sibling `<file>.lock`, held
  across read, merge and write: the installed app and a dev build can share the
  state directory, and a lock on the data file itself would be lost when the
  file is replaced atomically.
- A `version` field. A file from a newer version opens read-only, so an older
  build never drops keys it doesn't know.
- Clean Up of the worktree deletes the file.

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
   render as before.
3. **R3, Explain.** `BoundedProcess`'s extensions, the run of section 4.3, the
   copy, the account check, the settings (model, effort), the first-use
   notice, the cache, the checks on the output, the claims, the usage line.
   Run on five merged PRs before its defaults are frozen.
4. **R4, comments and reviewed marks.** Drafts, re-anchoring, outdated
   comments, and turning a "check this" note into a comment.
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
  tested on the same strings through `renderPartialHTML`'s output; if that
  needs a DOM, R2 adds the first test that loads a `WKWebView` and proves it
  stable on CI before relying on it.
- Explain is tested against a fake `claude`; the real CLI runs only by hand,
  on a dev build with `NIRUX_STATE_DIR`.
