# Projects

Status: design proposal. Nothing here is implemented yet.

Nirux groups workspaces into "spaces" (`WorkspaceProfile`: id, name, color).
In practice spaces are used as projects, but a space knows nothing about its
project: no repository, no context for the agents, no defaults, no history. It
also disappears when its last workspace closes.

This document proposes promoting spaces to **Projects**, and answers a related
question: why not connect Nirux to claude.ai instead?

## Decided

- **Session names come first.** Sessions launched by Nirux get a readable name
  on claude.ai and the phone. This ships first, as a small independent PR.
- **No "Open on claude.ai" button.** On the Mac it would reopen what is already
  on screen.
- **The brief is a local file managed by Nirux**, so it works with Claude and
  Codex. A claude.ai doc is only an option, for editing from the phone.
- **No direct sync with claude.ai Projects.** There is no public API, and
  scraping with cookies is ruled out.
- **Telegram stays as it is.** Projects don't build on it.
- **Routing is sticky.** A workspace stays in the project it was assigned to,
  even if its shell later `cd`s into another repository.
- **The Project view is a dedicated column type.**
- **Only fresh launches are named.** A restore never overwrites a name the user
  set by hand.

## Summary

| Part | What it gives | Main mechanism |
| --- | --- | --- |
| Session names | Readable titles on claude.ai, the phone and `claude --resume` | `claude -n "<branch> · <project>"` |
| Model | Projects persist, carry settings, survive with zero workspaces | `projects.json`, migrated from `workspaceProfiles` |
| Routing | New workspaces land in the right project automatically | Repo identity via `git rev-parse --git-common-dir` |
| Brief | Every agent starts with the project's goals, priorities and rules | `--append-system-prompt-file` (Claude), `developer_instructions` (Codex) |
| Defaults | Agent, modes, env, setup script, pinned URLs per project | Applied at launch; override global Settings |
| History | Past sessions of the project, across worktrees, resumable | Ledger built from hook events; `claude --resume <id>` |
| Project view | One column for worktrees, PRs, CI, agents, sessions | Existing git/PR detection, aggregated per project |

## Can Nirux sync with claude.ai?

Not with claude.ai Projects. With claude.ai *sessions*, partly.

- **No public API for claude.ai Projects.** The only official endpoints that
  touch them are the Compliance API, which is Enterprise-only and read/delete
  only ([compliance data][compliance]). Console "Workspaces" and the Files API
  are unrelated API-side concepts.
- **No "Sign in with Claude" for third-party apps.** Anthropic explicitly does
  not permit it, nor collecting or intermediating claude.ai credentials or
  session tokens ([legal and compliance][legal]).
- **No scraping.** The Consumer Terms (§3) forbid scraping and automated access
  other than through an API key ([consumer terms][terms]). Nirux has a
  `CookieImporter` for web columns; it must never be used to drive claude.ai.
- **Claude Code Projects (beta) are not a sync target either.** They live at
  claude.ai/code, the desktop app and the mobile app, not in the CLI. A session
  started locally cannot be added to one. A project reaches a machine only by
  running a "Work locally" thread through Remote Control
  ([Claude Code Projects][cc-projects], Limitations).

What *is* possible, all documented:

1. When the user turns on `remoteControlAtStartup`, every interactive Claude
   session launched by Nirux appears on claude.ai and in the Claude app
   ([Remote Control][rc]).
2. Nirux can name those sessions (section 1).
3. The Claude app already pushes a notification when a Remote Control session
   needs a permission or an answer ("Push when actions required"), and when
   Claude decides a task is worth reporting ("Push when Claude decides"). Both
   are toggled in `/config`. Claude Code skips the push while the user is typing
   in or focused on the connected terminal ([Remote Control][rc], Mobile push
   notifications). For Claude sessions this overlaps with Telegram. Telegram
   still covers Codex, which Remote Control doesn't reach.
4. Claude Code fetches the user's claude.ai connectors (for example Claude Docs)
   in terminal sessions ([MCP][mcp]). That makes a claude.ai doc possible as an
   optional brief (section 4).

Not pursued:

- A per-column link to the claude.ai session. It is possible:
  `CLAUDE_CODE_BRIDGE_SESSION_ID` (Claude Code 2.1.199+) is set in hook
  subprocesses while Remote Control is connected, and holds the ID used in the
  `claude.ai/code/<id>` URL ([env vars][env]). It was dropped as not useful on
  the Mac.
- Hosting `claude remote-control` in a project folder, so that "Work locally"
  threads of a Claude Code Project run on this Mac. Possible later.

## 1. Session names

Today a session gets an auto-generated title from its first prompt. Every
session launched from a worktree handover starts with "Read
.claude-handover.md…", so on the phone the Remote Control list is full of
near-identical ".claude-handover.md" titles.

**Mechanism: `claude -n <name>` at launch.** `--name` sets the display name
shown in `/resume` and the terminal title ([CLI reference][cli]). It is also the
first choice for the Remote Control title on claude.ai and in the app, and once
it is set the title no longer follows the prompt ([Remote Control][rc]).

Because a name freezes the title, Nirux only passes one when it is more telling
than the prompt-based title. The name is `<label> · <project>`, for example
`feat/projects · Nirux`, with the distinctive part first because phone lists
truncate.

- **Label**, first match wins:
  1. The workspace title, if the user renamed the workspace. Today's
     `titleIsManual` can't tell this apart: every new workspace gets a
     placeholder title ("ws N") marked manual, and the flag isn't persisted.
     This PR adds a persisted "renamed by the user" flag.
  2. The current branch, if it isn't the repository's default branch and HEAD
     isn't detached. It is read with one git call at launch. Worktree
     workspaces match here from their first launch.
  3. Otherwise no `-n`: a session on the main checkout keeps its prompt-based
     title rather than becoming one more "main · Nirux".
- **Project** is the space name until Projects exist. It is left out for the
  default space while it still has its default name ("main"), and when it
  equals the label.
- **Where:** `claudeCommand` gains a shell-quoted `name` argument. Fresh launches
  go through `launchAgent` (new workspaces and worktrees) and `openClaudeCode`
  (new columns).
- **Duplicates:** if another live session already has the name (two Claude
  columns in one workspace), Claude Code keeps the first and gives the second a
  suffixed variant ([sessions][sessions]).
- **Restores don't pass `-n`**, so they never overwrite a name set with
  `/rename` or from the phone. Sessions already titled ".claude-handover.md"
  keep that title.
- **Codex:** no launch-time name flag (only `/rename` in the TUI), and its
  sessions don't reach claude.ai. Out of scope.

Possible follow-up, for the user to decide: a SessionStart hook can return
`sessionTitle`, with the same effect as `/rename`, on `startup`, `resume` and
`fork`. Its input carries `session_title`, "the current session title if one is
already set, for example via `--name` or `/rename`", so a hook can name a
restored session without overwriting a title the user set ([hooks][hooks]). That
would also fix sessions restored with a handover title. To verify first:
whether an auto-generated title counts as "already set". It needs the hook
receiver to write JSON to stdout, so it waits for in-flight work on the hook
receiver.

Rejected: typing `/rename` into the agent (it races with the handover prompt and
lands in the user's input), and `--remote-control <name>` (it also forces
Remote Control on).

## 2. Model and migration

```swift
struct Project: Codable, Equatable {
    var id: String              // = former WorkspaceProfile.id
    var name: String
    var colorHex: String
    var anchors: [ProjectAnchor] // empty = manual-only project
    var brief: ProjectBrief?
    var defaults: ProjectDefaults?
    var isArchived: Bool
}

enum ProjectAnchor: Codable, Equatable {
    case gitRepository(commonDir: String, fingerprint: RepoFingerprint)
    case folder(path: String)
}
```

`RepoFingerprint` is the origin URL and root commit, used to notice a
repository that moved (section 3). `ProjectBrief` and `ProjectDefaults` are
described in sections 4 and 5.

**Storage.** A new `projects.json` in the state directory, next to
`missions.json`, holds projects plus the ids of deleted projects (tombstones).
It is the source of truth.

- It has a `schemaVersion` and decodes leniently: every field is optional with
  a default, and unknown anchor kinds are kept as-is rather than failing the
  whole file. So a nightly can read a file written by a newer one.
- It is backed up and rotated like `state.json`. A file Nirux can't read is set
  aside and never overwritten. Nirux does not silently rebuild projects over it.
- It is written with mode `0600`, re-applied after every atomic write and to
  the backups, because it can hold env values.

**Migration.** If `projects.json` doesn't exist, it is built from `state.json`'s
`workspaceProfiles`, keeping the same ids. `WorkspaceState.profileID` keeps its
persisted name, so no workspace needs rewriting.

**Rollback to an older nightly.** Nirux ships nightlies with Sparkle and can
roll back.

- `state.json` keeps writing `workspaceProfiles` (id, name, color) as a mirror,
  so older builds keep working.
- New builds also write a top-level marker in `state.json`. Older builds drop
  unknown keys when they save, so a missing marker means an older build saved
  last.
- Only then does the new build reconcile. It imports profile ids it doesn't
  know, unless they are tombstoned. It takes names and colors from the mirror,
  so a rename done in the older build survives.
- With the marker present, the mirror is ignored. A crash between the two
  writes, or a load from a `state.json` backup, can't bring a deleted project
  back.
- Workspaces pointing at a tombstoned or unknown project move to the default
  project.

**Behavior changes:**

- **Empty projects persist.** Today `saveState` only keeps `navigableProfiles`,
  so a space dies with its last workspace. A project keeps its brief and
  defaults, so it must survive.
  - The switcher shows empty projects dimmed; archiving hides them.
  - Selection needs rework: `selectProfile` refuses an empty space, and
    selection moves away from one that empties.
- **The default project** is today's default space (`WorkspaceProfile.defaultID`),
  with whatever name the user gave it. It behaves like any other project
  (rename, recolor, anchors) but can't be deleted. Deleting another project
  moves its workspaces there.
- **Management UI.** Rename already exists ("Rename Space…"). This adds recolor,
  archive, delete, and "Move workspace to project…" in the card menu.
- **`NIRUX_PROFILE_ID`** stays as is; the worktree skill relies on it. Like all
  terminal env, it is fixed when a shell starts, so it goes stale after a move.
  A worktree child therefore takes its parent's *current* project, looked up
  from the parent workspace id. The `profile=` parameter is only a fallback.

## 3. Routing

Repository identity is `git rev-parse --path-format=absolute --git-common-dir`,
with symlinks resolved. It is the same for the main checkout and every linked
worktree (for this repo: `…/nirux-public/.git`). Nirux doesn't use it anywhere
today; `--show-toplevel` returns the worktree's own folder instead.

Routing runs once, **before** the workspace is created, so the first agent
starts with the right project, env and brief. Git detection today is
asynchronous and slower than the 1 s agent launch. Routing makes one bounded
`rev-parse` call on the target folder instead.

A workspace's project is decided in this order:

1. **Explicit parent.** A worktree or mission child joins its parent's current
   project.
2. **Anchor match.** The most specific matching anchor wins: a `folder` anchor
   inside a repository beats that repository's anchor.
3. **The active project**, which is today's behavior for every new workspace.

After that the assignment is sticky. It only changes when the user moves the
workspace.

Anchoring:

- "New Space" from the focused workspace already names the space after the
  folder (`createProfileFromActiveContext`). "New Project" also anchors it to
  that repository.
- After migration, a space whose workspaces all share one repository gets a
  one-click "Anchor to `<repo>`?" suggestion. Nothing is anchored silently.
- An anchor belongs to at most one project.
- **Moved repositories.** If an anchor's folder disappears, Nirux looks for a
  repository with the same fingerprint when routing a new workspace, and offers
  to re-anchor.
- **Submodules** have their own common dir (inside the superproject's
  `.git/modules`), so they are separate repositories. Anchor them separately,
  or cover them with a `folder` anchor.

Side effect worth fixing separately: `GitWorktree.create` names worktrees after
the current worktree's folder, so a worktree created from a worktree nests
names (`nirux-public.feat-projects.feat-x`). Using the common dir fixes it.

## 4. Brief

A short, personal text per project: goals, priorities, workflow rules, links.
It is not `CLAUDE.md` or `AGENTS.md`, which are repository rules shared through
git. The brief is never written into the repository. It is also not a handover:
a handover describes one workspace's task, while the brief is what every
workspace of the project should know.

Typical content is the block of shared rules that parallel-worktree handovers
repeat today, copied into each one. A brief states it once, for example:

```markdown
## Rules for every workspace
- One workspace = one PR. Never merge; the maintainer merges.
- Debug builds use their own state directory.
- Before a PR is final: adversarial review, code review, premortem, fixes,
  confirmation review.
```

**Storage.** The user edits `<state dir>/projects/<id>/brief.md` in Nirux's
editor column. Before each launch, Nirux regenerates
`<state dir>/projects/<id>/brief.injected.md`, which wraps the brief in a short
header:

```text
# Project brief: <Project name> (from Nirux)
Maintained by the user. Repository rules in CLAUDE.md / AGENTS.md take
precedence; if they conflict, ask.
<brief>
```

The brief is sent with every request, so the editor warns above about 4,000
characters (roughly 1,000 tokens). The hard cap is 16,000 characters, the limit
claude.ai uses for Claude Code Project instructions.

**Claude.** Nirux passes `--append-system-prompt-file <absolute path>` on
*every* launch: fresh, restore and Resume ([CLI reference][cli]). The path is
shell-quoted, because the state directory contains a space ("Application
Support").

- By default Claude Code records the system prompt on a conversation's first
  request, and reuses it on `--resume` and `--continue` until the conversation
  is compacted. A later launch's flag text, "or none", takes effect only then
  ([resumed conversations][cli-resume]).
- So a restore must pass the flag too. Otherwise a restored session would lose
  its brief at its first compaction.
- The editor says: "applies to new sessions; open ones pick it up after
  compaction".
- `--system-prompt-snapshot off` (2.1.257+) would rebuild the prompt on every
  request. It is documented as a tool for iterating on prompt text, and its
  effect on prompt caching is unknown, so it is not used.
- To verify: whether subagents receive the appended text.

**Codex.** Nirux passes `developer_instructions`, which Codex documents as
"additional developer instructions injected into the session"
([Codex config][codex-config]).

- The launch command is typed into the shell, so the text can't go inline.
  Nirux writes the brief as a TOML string to
  `<state dir>/projects/<id>/brief.codex.toml`.
- It launches `codex -c "developer_instructions=$(cat '<path>')"`, on fresh
  launches and on `codex resume`.
- This relies on `$(…)`, which bash, zsh and fish 3.4+ support. On other
  shells Nirux leaves the brief out.
- It overrides a `developer_instructions` the user set in `config.toml`. Nirux
  already reads that file for its hooks, so it can detect the key and warn.

Rejected for Codex:

- **`--profile`.** It is a single slot, so it replaces a profile the user
  selects. Nirux is a GUI app and doesn't see a `CODEX_HOME` set in the shell.
  And CLI mode flags would override the profile's values.
- **`model_instructions_file`.** It replaces Codex's built-in instructions.

**Later, if the recording is a problem:** a SessionStart hook can add context on
`startup`, `resume`, `clear` and `compact`, in both Claude Code ([hooks][hooks])
and Codex ([Codex hooks][codex-hooks]). It always delivers the current brief,
but:

- it adds a copy to the transcript on every resume;
- Codex requires the user to trust each hook;
- Codex caps hook output at roughly 2,500 tokens.

**Optional claude.ai doc.** A project can also store the link to a claude.ai
doc, and the injected brief then tells Claude to read it through the Claude
Docs connector. The doc is editable from the phone, but Nirux can't display it
and Codex can't read it. The local file stays the source of truth.

## 5. Defaults

| Default | Applied when | How |
| --- | --- | --- |
| Agent (Claude, Codex, none) | A workspace is created in the project | `launchAgent` |
| Claude permission mode | A Claude column launches | `ClaudeLaunchMode.cliArgs` |
| Codex mode | A Codex column launches | `CodexLaunchMode.cliArgs` |
| Environment variables | A shell starts in the project | `makeTerminalEnvironment` |
| Post-worktree setup script | After a worktree workspace is created, before the agent starts | `sh '<script path>' && <agent command>` |
| Pinned URLs | On demand | Project view and command palette; open as web columns |

Rules:

- **Precedence.** Nirux computes one effective value per launch: an explicit
  choice for this launch, else the project default, else global Settings. It
  passes a single set of flags.
- **Env is fixed when a shell starts.** Changing a project's env, or moving a
  workspace, affects new shells only.
- **Setup scripts** are stored as files in the project's state folder. They
  must be idempotent: `GitWorktree.create` can reuse an existing folder, so a
  script may run twice.
- **Setup scripts and project env are applied only to workspaces Nirux can
  attribute to the user**: created from the UI, or from a `nirux://` request
  authenticated as coming from a Nirux terminal.
- **Secrets.** Env values may hold secrets. The UI suggests referencing a secret
  manager (`op run …`) over pasting values.

## 6. History

Claude Code stores transcripts per directory
(`~/.claude/projects/<encoded cwd>/`), so a repository with many worktrees has
one folder per worktree. The transcript format is internal and may change
between versions ([sessions][sessions]), so Nirux does not parse it.

Instead Nirux keeps its own **session ledger**, from hook events it receives.

- **Fields:** agent kind, session id, project, workspace, cwd, `transcript_path`
  (Claude), the branch at that time (from the workspace's git context), the
  name Nirux passed, and first and last seen.
- **Parsing:** `transcript_path` isn't parsed today. The hook event parser
  gains it.
- **Codex:** thread ids only arrive through `notify`, after the first completed
  turn.
- **Renames** made with `/rename` or from the phone aren't seen.
- **Only real session events** are recorded. Nirux keeps SessionStart and Stop
  from the column's own agent, and ignores tools like CI pipelines that run
  `claude -p` inside a Nirux shell and inherit its env.
- **Pruning:** Claude entries go when their transcript is gone (default
  retention: 30 days). Codex entries go by age. Each project keeps at most a few
  hundred entries.

Using it:

- The project view lists the ledger, newest first, across all worktrees.
- **Resume** opens a column running `claude --resume <id>`, which finds the
  session from any directory since Claude Code 2.1.223 ([sessions][sessions]).
  Codex uses `codex resume <id>`.
- **Where the column opens:**
  - in the original worktree, if it still exists;
  - otherwise Nirux offers to recreate the worktree from the recorded branch;
  - failing that, it opens in the main checkout, with a warning that the
    conversation was about another branch.
- **Browse all sessions** covers sessions Nirux didn't launch. It opens a column
  in the repository running `claude --resume`, whose picker widens to every
  worktree with `Ctrl+W`, or `codex resume --all`.

Rejected: `CLAUDE_CODE_PROJECT_DIR_NAME` could store every worktree's
transcripts under one name. It only works with `CLAUDE_CONFIG_DIR` set, and
auth, settings and plugins follow that directory.

## 7. Project view

A per-project dashboard, opened as a new column type (like the editor and web
columns) from the command palette or a shortcut. Today's Pilot panel is per
workspace, three rows tall, and covers only the active space.

- **Header:** name, color, anchors, brief preview with Edit, pinned URLs.
- **Workspaces** (active and inactive): branch, phase, PR and CI, agent status
  per column, last summary, next step.
- **Worktrees on disk without a workspace** (`git worktree list`), with Open.
- **Recent sessions** from the ledger, with Resume.
- **Later: "Finish".** When a workspace's PR is merged, it removes the
  worktree, deletes the branch and closes the workspace, after confirmation.

The data sources already exist (`GitDetect`, `PRDetect`, `GitWorktree.list`,
workspace context). Sections backed by later PRs (brief, pinned URLs, sessions)
stay hidden until those PRs land.

## 8. Plan

Each PR is reviewable on its own. Several touch code that other in-flight
branches also change; those wait for them to merge, or rebase after.

| # | PR | Depends on | Overlaps with in-flight work on |
| --- | --- | --- | --- |
| 1 | Name Claude sessions | none | launch commands, worktree creation |
| 2 | Project model, `projects.json`, migration, management UI | none | state persistence and backups, restore |
| 3 | Routing and anchors | 2 | worktree creation, git detection |
| 4 | Brief: storage, editing, Claude and Codex injection | 2 | launch commands, restore |
| 5 | Per-project defaults | 2, 4 | settings, terminal env, `nirux://` handling |
| 6 | Session ledger and resume | 2, 3 | hook events, restore |
| 7 | Project view column | 2, 3 | git and PR polling |
| 8 | "Finish" (PR merged, then remove worktree) | 7 | none |

PR 1 needs no project model and can start now. It will likely rebase over
in-flight changes to the Claude launch command.

## Sources

Checked on 2026-09-26 against Claude Code 2.1.283 and Codex CLI 0.151.

- [Claude Code: Remote Control][rc]
- [Claude Code: Manage sessions][sessions]
- [Claude Code: CLI reference][cli], [system prompt flags on resume][cli-resume]
- [Claude Code: Environment variables][env]
- [Claude Code: Hooks][hooks]
- [Claude Code: MCP (claude.ai connectors)][mcp]
- [Claude Code: Projects (beta)][cc-projects]
- [Claude Code: Legal and compliance][legal]
- [Anthropic Consumer Terms][terms]
- [Claude API: Compliance content data][compliance]
- [Codex: Configuration reference][codex-config]
- [Codex: Hooks][codex-hooks]

[rc]: https://code.claude.com/docs/en/remote-control
[sessions]: https://code.claude.com/docs/en/sessions
[cli]: https://code.claude.com/docs/en/cli-reference
[cli-resume]: https://code.claude.com/docs/en/cli-reference#system-prompt-flags-in-resumed-conversations
[env]: https://code.claude.com/docs/en/env-vars
[hooks]: https://code.claude.com/docs/en/hooks
[mcp]: https://code.claude.com/docs/en/mcp
[cc-projects]: https://code.claude.com/docs/en/claude-projects
[legal]: https://code.claude.com/docs/en/legal-and-compliance
[terms]: https://www.anthropic.com/legal/consumer-terms
[compliance]: https://platform.claude.com/docs/en/manage-claude/compliance-content-data
[codex-config]: https://learn.chatgpt.com/docs/config-file/config-reference
[codex-hooks]: https://learn.chatgpt.com/docs/hooks
