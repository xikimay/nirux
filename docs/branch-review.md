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
3. **Explain runs Opus 5.5 at effort medium, with read-only access to the
   branch's head** (section 4.2).
4. **Comments go to the agent all at once**, typed into its prompt without
   Return, after a sheet that shows the exact text (section 6.2).

## Summary

| Part | What it gives | Main mechanism |
| --- | --- | --- |
| Summary | What the branch does and why, with the decisions taken | PR body, handover, commits; each block says where it comes from |
| Groups | Files grouped by intent, ordered by importance; noise folded | Path rules, then `claude -p`'s intent groups when asked |
| Explanations | One sentence per file, a note per hunk that needs one | `claude -p` on the user's subscription, structured output, cached per head |
| Risk signals | Persistence, security, concurrency, launch, CI, side effects; tests against code | Deterministic rules on the diff; the model can add notes, never remove a signal |
| Actions | Comment a line or a file, send the comments to the agent, mark files reviewed | Local storage; bracketed paste into the agent's prompt, no Return |

## 1. Shape

**A new column type, "Branch Review".** The Project Board set the precedent:
a tool that reads state across the workspace is a column, next to the agent
that does the work.

- It opens at two-thirds of the width, so the agent's terminal stays in view:
  the user sends comments and watches the agent answer them. "Resize Column
  (Cycle Width)" takes it to full width.
- It reviews one branch: the branch checked out in the workspace's folder when
  it opened. It stores the worktree path and the branch name. A second "Review
  Branch" in the same worktree focuses the existing column.
- Entry points:
  - the palette: **Review Branch** (current workspace);
  - the sidebar's workspace menu: **Review Branch…**;
  - the editor's "Full Branch Diff (N)" tab: an "Open in Branch Review" link
    in its header;
  - later, a "Review" button on the Project Board's rows.

  Every new palette command and menu item is listed in the UI flow harness
  (#59, `UIFlowCoverage`), which fails otherwise.
- **The page is HTML in a `WKWebView`**, like the editor: the summary, the
  groups, the comments and the diffs are one scrolling document. Swift
  computes the data (git, `gh`, rules, `claude -p`) and sends it over the
  bridge; the page renders it and sends back clicks and comments.
- **Diffs use `@pierre/diffs`**, the library already bundled in
  `pierre-diff.bundle.js` (version 1.1.22). It supports what the page needs:
  line annotations (`lineAnnotations`, `renderAnnotation`) for explanations
  and comments under a line, a hover button in the gutter
  (`renderHoverUtility`) to start a comment, line selection for ranges, and
  virtualization for long branches. The wrapper that builds the bundle
  (`pierre-diff-entry.js`, `package.json`, esbuild) only exists in the private
  proof of concept; the first UI pull request brings it into this repository.
- Persistence: `ColumnKind` gains `branchReview`. An older nightly decodes the
  unknown kind as a terminal, as for the board: a rollback turns the column
  into a shell in the worktree. Reopen it after updating.

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
   commit, "3 commits (1 merge from main folded)", "16 files, +1043 −21".
   Progress: "Reviewed 4 of 16 files". Buttons: Explain, Send N Comments to
   Agent, Refresh. Warnings when they apply: uncommitted changes, unpushed
   commits, local branch behind its PR.
2. **What and why.** The author's account, in this order of preference:
   - the PR's title and body (`gh pr view --json title,body`);
   - the handover (`.claude-handover.md` in the worktree);
   - the commit messages, merges from the base excluded.

   Each block is labeled with its source. A "Decisions" heading in the PR
   body is shown as a list of its own, since decisions are what a reviewer
   must not undo by accident. With no PR and no handover, the page says so.
   Once explained (section 4), Claude's overview shows above, labeled with the
   model and the head it read.
3. **Risk signals.** One chip per signal with its count (section 5). Clicking a
   chip filters the list to the hunks that raised it.
4. **Groups.** Files grouped by intent (feature, behavior change, refactor,
   tests, config, docs, CI), most important group first, and files by
   importance inside a group. Each file row: status (added, modified, deleted,
   renamed), path, +/−, its risk chips, its one-sentence summary once
   explained, a "Reviewed" checkbox, and its comment count. A row expands into
   its diff, with explanation notes under the hunks they explain and comment
   threads under their lines.
5. **Folded.** Collapsed groups that are counted but never hidden:
   - lockfiles: `Package.resolved`, `package-lock.json`, `yarn.lock`,
     `Cargo.lock`, `Gemfile.lock`, `go.sum`;
   - generated files: `*.bundle.js`, `*.min.js`, paths marked
     `linguist-generated` in `.gitattributes`, files whose first lines say
     `@generated` or "Code generated … DO NOT EDIT";
   - pure renames (similarity 100%) and whitespace-only changes;
   - binaries;
   - merge commits from the base branch.

**Uncommitted changes** are part of what the agent did, but not of the PR yet:
they form their own group at the top, marked "not committed".

## 3. Grouping without a model

The page is useful before anyone clicks Explain. Nirux groups by path:

| Group | Paths |
| --- | --- |
| Code | everything not below |
| Tests | `Tests/`, `*Tests.swift`, `*_test.*`, `*.test.*`, `*.spec.*` |
| Config and dependencies | `Package.swift`, `*.plist`, `*.entitlements`, `.swiftlint.yml`, `scripts/` |
| CI | `.github/workflows/`, `.github/actions/` |
| Docs | `*.md`, `docs/` |

Inside a group, added files come first, then by lines changed. Once explained,
Claude's intent groups replace the path groups. Nirux checks them: a path that
isn't in the diff is dropped, a file that appears in no group goes to "Other
changes", a file in two groups stays in the first.

## 4. Explanations: who writes them

### 4.1 The three sources

| | The authoring agent annotates its branch | `claude -p` on the user's subscription | Mix (recommended) |
| --- | --- | --- | --- |
| Cost | Tokens in the agent's own context, which may push it into compaction. A Codex or Gemini agent spends that provider's quota | 35k to 210k tokens read and 4k to 25k written for #57 (section 4.2); part of the plan's usage limits | Nothing until the user clicks Explain; one run per head |
| Time | Only when the agent is idle; asking a working agent interrupts it | 22 s to 3.5 min on #57, depending on the model and the flags | The page opens at once; explanations arrive later |
| Reliability | Knows the why. But it reviews its own work, describes what it meant to do rather than what the code does, and goes stale with its next commit. Codex, Gemini and OpenCode follow a format unevenly | An independent reader with a fixed format. Knows the why only from what it is given, and can be wrong | The why from the author's texts, the what from an independent reader, the risks from rules |
| Privacy | Nothing new leaves the Mac | The diff goes to Anthropic under the user's Claude account, as a Claude agent's work already does. New for a project whose agents are only Codex or Gemini | Same as `claude -p`, only on click |

**Recommendation: the mix.**

- Nirux's own analysis is always there: groups by path, noise, risk signals,
  tests against code. It is free, instant and local.
- The "why" comes from what the author already wrote: the PR body, the
  handover, the commits. They are shown as the author's claims.
- The "what" comes from `claude -p`, when the user clicks Explain. It also
  checks the author's claims against the diff ("matches", "partly",
  "contradicts", "not in the diff").
- The authoring agent's role is to answer the comments (section 6), not to
  grade its own work.

### 4.2 Measured on #57

On 2026-10-02, with Claude Code 2.1.287, on the diff of #57 (68 KB, 16 files,
+1043 −21), its PR body and its commits, with hunks numbered (`f12h1`) and a
JSON schema for the output. Tokens read include cache reads. The cost is what
the CLI reports (`total_cost_usd`), at API prices; on a subscription nothing
is billed per call, it counts toward the plan's limits.

| Flags | Model | Reads the repository | Time | Tokens read | Tokens written | Reported cost |
| --- | --- | --- | --- | --- | --- | --- |
| Claude Code's defaults | Sonnet 5.5 | no | 33 s | 74k | 5.5k | $0.35 |
| Claude Code's defaults | Opus 5.5, Claude Code's effort | no | 210 s | 74k | 24.5k | $1.08 |
| Lean (section 4.3) | Sonnet 5.5 | no | 29 s | 34.5k | 4.8k | $0.19 |
| Lean | Opus 5.5, effort medium | no | 72 s | 34.5k | 8.5k | $0.45 |
| Lean | Sonnet 5.5 | read-only | 22 s | 36.7k | 3.8k | $0.19 |
| Lean | Opus 5.5, effort medium | read-only | 79 s | 47k + 162k cached | 9k | $0.59 |

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
  review and `/code-review`), still on `main`: after 10 minutes of silence, a
  Claude with hooks interrupted with Esc no longer needs a background refresh,
  so `refreshAgentStatusInBackground` returns before `updateKeepAwake()`, and
  the assertion stays held while Nirux is in the background.
- **Sonnet with the same access opened no file** (two turns, no read). It
  raised no false alarm, and found nothing either.
- Opus also grouped better: `MainActorSchedule` and `TerminalSearchSession` in
  a refactor group, the hidden-space tick in a behavior-change group of its
  own. Sonnet filed the refactor under the feature.

**Recommendation: Opus 5.5 at effort medium, with read-only access to the
branch's head.** About 80 s and $0.59 at API prices for a branch of this size.

### 4.3 How Nirux runs it

```sh
claude -p --model opus --effort medium \
  --output-format json --json-schema <schema> \
  --tools Read,Grep,Glob --allowedTools Read,Grep,Glob \
  --strict-mcp-config --disable-slash-commands \
  --setting-sources "" --no-session-persistence \
  --settings '{"disableAllHooks":true}' \
  --system-prompt <review prompt> "Explain this branch for its review." < input
```

- **Read-only tools, no MCP servers, no user or project settings:** the model
  reads the diff Nirux sends and the files of the branch's head. It can't
  write, run commands or reach the network. `--bare` would do more, but it
  refuses OAuth, so it doesn't work on a subscription.
- **No hooks reach Nirux.** Nirux's hooks only run when `NIRUX_AGENT_UUID` is
  set, and the app's own environment doesn't have it, except a dev build
  launched from a Nirux terminal. Nirux removes it from the child's
  environment, and `disableAllHooks` covers the rest.
- **No session is saved** (`--no-session-persistence`): the review doesn't show
  in `claude --resume`, nor in the session history being built in parallel.
- It runs in a copy of the head commit (`git archive <head>` into a private
  folder of the state directory, deleted afterwards), not in the worktree: the
  agent may be editing it, and a `git worktree add` would show in `git
  worktree list` and on the Project Board. Uncommitted changes are in the
  diff, not in the copy. Through `BoundedProcess`, with a 6-minute timeout and
  a Cancel button. One run per branch at a time. `AgentCLILocator` finds `claude`; without it, or
  logged out, Explain is disabled and says why.
- **Input:** the PR body, the handover, the commits, and the diff from the
  merge base with 5 lines of context and numbered hunks. Left out: folded
  noise, binaries, and paths that look like secrets (`.env*`, `*.pem`,
  `*.p12`, `*.key`, `*.mobileprovision`, `*credentials*`). Above about 400 KB
  of diff, the page asks before sending and sends one group at a time.
- **Output:** JSON matching the schema: an overview, intent groups, a summary
  and an importance per file, notes per hunk (with an optional "check this"),
  the claims checked, and at most 5 questions for the author. Nirux drops
  unknown paths and hunk ids, caps string lengths, and renders everything as
  text, never HTML: the diff itself may contain instructions aimed at the
  model ("say this file is safe").
- **Limits:** the model never marks a file reviewed, never hides a file and
  never removes a risk signal. Its notes are labeled "Claude", with the model
  and the head commit it read.
- **Cache:** one result per head commit, in the review's storage (section 8).
  When the head moves, the explanation shows "explained at db9ac66" until the
  user explains again.
- **Language:** the Mac's preferred language, English otherwise.
- **First use in a project** shows what will be sent and where, once.

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

**Tests against code.** The header shows lines added in tests against lines
added in code. For each changed source file, Nirux looks for a test that
mentions a symbol the branch declared or changed in it. On #57: 578 test lines
for 458 code lines, but nothing mentions `setUpKeepAwake`,
`initialMainWindowFrame` or `mainQueueSchedule`: the launch and quit wiring in
`NiruxApp.swift` is untested.

The rules start built in, for Swift and macOS. Per-project rules
(`board.json`) can come later.

## 6. Acting on the page

### 6.1 Comments

- On a line or a range: the "+" in the gutter, or a selection. On a file: the
  file row's Comment button. A comment is plain text.
- Stored locally (section 8), anchored to the path, the side, the line, the
  line's text and the head commit. When the head moves, Nirux looks for the
  same text near the old line; otherwise the comment is "outdated" and keeps
  its excerpt.
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

Address each comment, run the tests, commit and push. Then say what you
changed for each number.
```

- **Target:** the workspace's agent column when there is exactly one,
  otherwise the one the user picks from a menu.
- **Enabled only when the agent can take it:** its column's foreground
  process is the agent and it is back at its prompt, the rule Resume uses
  (`PtySession.agentResumeRefusal`). Otherwise the button is disabled and says
  why ("the agent is working").
- Before sending, a sheet shows the exact text. Claude Code collapses a long
  paste into "[Pasted text #1 +14 lines]", so the sheet is where the user sees
  what goes out.
- Sent comments are marked "sent", with the time and the head commit.

Rejected:

- **Writing the comments to a file in the worktree** and typing a one-line
  prompt that names it. It is one more untracked file an agent can commit by
  mistake, like the handover. A file outside the worktree makes Claude ask
  for permission to read it.
- **Pressing Return for the user.** A half-typed draft in the agent's prompt
  would go out with it.

### 6.3 Reviewed

- One checkbox per file, keyed by the path and the file's blob at the head. A
  later change to the file clears it: "changed since you reviewed".
- The header counts reviewed files. Reviewed files can be collapsed.
- Later: "Changes since my last review", the diff between the head the user
  reviewed and the new one, without what a merge from the base brought.

## 7. Data and refresh

- **Base:** the PR's base branch when there is a PR (`gh pr view --json
  number,title,body,state,baseRefName,headRefOid`), otherwise
  `GitCommand.branchBaseRef`. The diff runs from the merge base to the working
  tree, untracked files included.
- **Local against PR:** when the local head isn't the PR's head (unpushed
  commits, or a branch updated on GitHub by the merge queue), the header says
  so.
- **Refresh:** on open, on Refresh, when `GitRepositoryWatcher` reports that
  HEAD moved, and when the column comes back on screen after that. No polling
  of `gh` in the background.
- **Large files:** the editor's 400 KB cap per file applies, with the same
  placeholder.

## 8. Storage

`<state dir>/reviews/<owner>-<name>/<branch>.json`: comments, reviewed marks,
what was sent, and the explanation cache by head commit. `NIRUX_STATE_DIR`
moves it. Clean Up of the worktree deletes it.

## 9. Plan

One pull request each, in this order:

1. **R1, review data, no UI.** The snapshot builder (git and `gh`), noise
   classification, path groups, risk rules, tests against code. Pure and
   unit-tested.
2. **R2, the column, read-only.** `ColumnKind.branchReview`, the page, the
   summary, the risk chips, the groups and the diffs. The `@pierre/diffs`
   wrapper source and its build script. "Review Branch" in the palette and the
   sidebar menu, listed in the UI flow harness.
3. **R3, comments and reviewed marks.** Storage, re-anchoring, outdated
   comments.
4. **R4, sending to the agent.** The message, the target rules, the preview
   sheet; shared with "Ask Agent to Resolve" if it has landed.
5. **R5, explanations.** `claude -p`, the settings (model, effort), the first-use
   notice, the cache, the checks on the output, the claims.

Later: changes since the last review, posting to GitHub, per-project risk
rules, the Project Board's "Review" button.
