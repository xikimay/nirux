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
- **Only fresh launches are named.** Restores keep whatever name the session
  has, including names set by hand.

## Summary

| Part | What it gives | Main mechanism |
| --- | --- | --- |
| Session names | Readable titles on claude.ai, the phone and `claude --resume` | `claude -n "<workspace> · <project>"` |
| Model | Projects persist, carry settings, survive with zero workspaces | `projects.json`, migrated from `workspaceProfiles` |
| Routing | New workspaces land in the right project automatically | Repo identity via `git rev-parse --git-common-dir` |
| Brief | Every agent starts with the project's goals, priorities and rules | `--append-system-prompt-file` (Claude), `developer_instructions` (Codex) |
| Defaults | Agent, modes, env, setup script, pinned URLs per project | Applied at launch; override global Settings |
| History | Past sessions of the project, across worktrees, resumable | Ledger built from hook `session_id`; `claude --resume <id>` |
| Project view | One screen for worktrees, PRs, CI, agents, sessions | Existing git/PR detection, aggregated per project |

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
- **Claude Code Projects (beta, announced 2026-09-17) are not a sync target
  either.** They live at claude.ai/code, the desktop app and the mobile app, not
  in the CLI. A session started locally cannot be added to one. A project
  reaches a machine only by running a "Work locally" thread through Remote
  Control ([Claude Code Projects][cc-projects], Limitations).

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
4. claude.ai connectors (for example Claude Docs) are available inside
   interactive Claude Code sessions, not in `claude -p` ([MCP][mcp]). That makes
   a claude.ai doc possible as an optional brief (section 4).

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

- **Format:** `<workspace> · <project>`, for example `feat/projects · Nirux`.
  The distinctive part comes first because phone lists truncate.
  - *workspace* is the workspace title: the manual title if set, otherwise the
    branch. Worktree workspaces get their branch as title at creation
    (`createWorktreeWorkspace`), so the name is right from the first launch.
    If the title is still the placeholder, the folder name is used.
  - *project* is the space name until Projects exist. It is omitted for the
    default space.
- **Where:** `claudeCommand` gains a `name` argument, shell-quoted like the
  prompt. Every fresh launch passes it: `launchAgent` (new workspaces and
  worktrees) and `openClaudeCode` (new columns).
- **Duplicates:** if another live session already has the name (two Claude
  columns in one workspace), Claude Code keeps the first and gives the second a
  suffixed variant ([sessions][sessions]). Nirux doesn't need to handle it.
- **Restores don't pass `-n`.** Passing it again on `--continue` would also
  rename the sessions already titled ".claude-handover.md", but it would
  overwrite, at every Nirux restart, a name the user set with `/rename` or from
  the phone.
- **Codex:** no launch-time name flag (only `/rename` in the TUI), and its
  sessions don't reach claude.ai. Out of scope.

Rejected: typing `/rename` into the agent (it races with the handover prompt and
lands in the user's input), and `--remote-control <name>` (it names only the
claude.ai side, while `-n` also names the local picker).

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
    case gitRepository(commonDir: String) // absolute, symlinks resolved
    case folder(path: String)             // for non-git folders
}
```

`ProjectBrief` and `ProjectDefaults` are described in sections 4 and 5.

Storage: a new `projects.json` in the state directory, next to `missions.json`.
It is the source of truth for projects.

- **Migration.** If `projects.json` is missing, it is built from
  `state.json`'s `workspaceProfiles`, with the same ids. `WorkspaceState.profileID`
  keeps its persisted name, so no workspace needs rewriting.
- **Rollback safety.** Nirux ships nightlies with Sparkle and can roll back.
  Older builds would drop unknown fields if they lived in `state.json`, so
  `state.json` keeps writing `workspaceProfiles` (id, name, color) as a mirror
  and older builds keep working. On load, any profile id found in `state.json`
  but not in `projects.json` (created by an older build) is imported.
- **Empty projects persist.** Today `saveState` only keeps
  `navigableProfiles`, so a space dies with its last workspace. A project keeps
  its brief and defaults, so it must survive. The switcher shows empty projects
  dimmed; archiving hides them.
- **Default project.** `WorkspaceProfile.defaultID` becomes the **Inbox**: the
  fallback for workspaces that match no anchor. It cannot be deleted or
  anchored.
- **Management UI** (missing today): rename, recolor, archive, delete (moves
  its workspaces to Inbox), and "Move workspace to project…" in the card menu.
- `NIRUX_PROFILE_ID` stays as is; the worktree skill already relies on it.

## 3. Routing

Repository identity is `git rev-parse --path-format=absolute --git-common-dir`,
with symlinks resolved. It is the same for the main checkout and every linked
worktree (for this repo: `…/nirux-public/.git`). Nirux doesn't use it anywhere
today; `--show-toplevel` returns the worktree's own folder instead.

A workspace's project is decided in this order:

1. **Manual choice.** Once the user moves a workspace, it stays put.
2. **Explicit parent.** A worktree or mission child inherits its parent's
   project (`nirux://new-worktree&profile=…` already does this).
3. **Anchor match.** A matching `gitRepository` anchor wins; otherwise the
   longest matching `folder` prefix.
4. **Inbox.**

Routing runs when a workspace is created, and once more when an Inbox
workspace's git context first resolves (detection is asynchronous). It does not
re-run afterwards: a workspace whose shell later `cd`s into another repository
stays where it is.

Anchoring:

- "New Project" from the focused workspace already names the project after the
  folder (`createProfileFromActiveContext`). It also anchors it to that repo.
- After migration, a space whose workspaces all share one repository gets a
  one-click "Anchor to `<repo>`?" suggestion. Nothing is anchored silently.
- An anchor belongs to at most one project.

Side effect worth fixing separately: `GitWorktree.create` names worktrees after
the current worktree's folder, so a worktree created from a worktree nests
names (`nirux-public.feat-projects.feat-x`). Using the common dir fixes it.
That code belongs to another open PR, so it is not part of this plan.

## 4. Brief

A short, personal text per project: goals, priorities, workflow rules, links.
It is not `CLAUDE.md` or `AGENTS.md`, which are repository rules shared through
git. The brief is never written into the repository. It is also not a handover:
a handover describes one workspace's task, the brief is what every workspace of
the project should know.

Typical content is the block of shared rules that parallel-worktree handovers
repeat today. During the last audit it was copied into 12 handovers; a brief
states it once:

```markdown
## Rules for every workspace
- One workspace = one PR. Never merge: a push to main ships a nightly.
- Debug builds always run with NIRUX_STATE_DIR=/tmp/nirux-dev-<branch>.
- GUI smoke runs take the /tmp/nirux-smoke.lock lock and restore the hook
  config files afterwards.
- Before a PR is final: adversarial review, /code-review, premortem, fixes,
  confirmation review.
```

**Storage:** `<state dir>/projects/<id>/brief.md`, edited in Nirux's editor
column. Capped at 16,000 characters, the same limit claude.ai uses for Claude
Code Project instructions. Agents receive it wrapped in a short header:

```text
# Project brief: <Project name> (from Nirux)
Maintained by the user. Repository rules in CLAUDE.md / AGENTS.md take
precedence; if they conflict, ask.
<brief>
```

**Injection:**

- **Claude:** `--append-system-prompt-file <path>` on fresh launches
  ([CLI reference][cli]). Caveat: Claude Code records the system prompt on a
  conversation's first request and reuses it on `--resume`/`--continue` until
  the conversation is compacted ([resumed conversations][cli-resume]). So an
  edited brief reaches new conversations and compacted ones, not a resumed
  one. Nirux restores Claude columns with `--continue`, so this matters.
- **Codex:** `developer_instructions` ("additional developer instructions
  injected into the session") ([Codex config][codex-config]). The launch
  command is typed into the shell, so the text can't go inline. Nirux writes
  `$CODEX_HOME/nirux-<id>.config.toml` and launches `codex --profile
  nirux-<id>`, which layers that file on top of the user config. The same
  file can carry the project's Codex defaults. `model_instructions_file` is
  not used: it replaces Codex's built-in instructions.
- **Later, if the freeze is a problem:** a SessionStart hook can print context
  for `startup`, `resume`, `clear` and `compact` in both Claude Code
  ([hooks][hooks]) and Codex ([Codex hooks][codex-hooks]). It would always
  deliver the current brief, but it adds a copy to the transcript on every
  resume, and Codex requires the user to trust each hook. Not in v1.

**Optional claude.ai doc.** A project can also store the link to a claude.ai
doc. The injected brief then tells Claude to read it through the Claude Docs
connector. The doc is editable from the phone, but Nirux can't display it,
Codex can't read it, and `claude -p` has no connectors. The local file stays
the source of truth.

## 5. Defaults

| Default | Applied when | How |
| --- | --- | --- |
| Agent (Claude, Codex, none) | A workspace is created in the project | `launchAgent` |
| Claude permission mode | A Claude column launches | `ClaudeLaunchMode.cliArgs` |
| Codex mode | A Codex column launches | `CodexLaunchMode`, or the Codex profile above |
| Environment variables | Any terminal in the project | `makeTerminalEnvironment` |
| Post-worktree setup script | After a worktree workspace is created, before the agent starts | Typed as `<script> && <agent command>` |
| Pinned URLs | On demand | Project view and command palette; open as web columns |

Precedence: explicit choice for this launch, then project default, then global
Settings. Env values may hold secrets: `projects.json` is written `0600`, and
the UI suggests referencing a secret manager (`op run …`) over pasting values.

## 6. History

Claude Code stores transcripts per directory
(`~/.claude/projects/<encoded cwd>/`), so this repository alone has 19 folders,
one per worktree. The transcript format is internal and may change between
versions ([sessions][sessions]), so Nirux does not parse it.

Instead Nirux keeps its own **session ledger**, filled from hook events it
already receives: agent kind, `session_id` (Codex: `thread-id`), project,
workspace, cwd, branch, name, first and last seen.

- The project view lists the ledger, newest first, across all worktrees.
- **Resume** opens a column running `claude --resume <id>`, which finds the
  session from any directory since Claude Code 2.1.223 ([sessions][sessions]).
  The column opens in the original worktree if it still exists, otherwise in
  the repository's main checkout. Codex uses `codex resume <id>`.
- **Browse all sessions** covers sessions Nirux didn't launch. It opens a column
  in the repository running `claude --resume`, whose picker widens to every
  worktree with `Ctrl+W`, or `codex resume --all`.
- Entries whose transcript no longer exists (Claude's default retention is 30
  days) are pruned.

Rejected: `CLAUDE_CODE_PROJECT_DIR_NAME` could store every worktree's
transcripts under one name, but it requires a separate `CLAUDE_CONFIG_DIR`, and
with it separate auth, settings and plugins.

## 7. Project view

A per-project dashboard. Today's Pilot panel is per workspace and shows at most
three rows of the active space.

- **Header:** name, color, anchors, brief preview with Edit, pinned URLs.
- **Workspaces** (active and inactive): branch, phase, PR and CI, agent status
  per column, last summary, next step.
- **Worktrees on disk without a workspace** (`git worktree list`), with Open.
- **Recent sessions** from the ledger, with Resume.
- **Later: "Finish".** When a workspace's PR is merged, it removes the
  worktree, deletes the branch and closes the workspace, after confirmation.

It is a new column type, like the editor and web columns, opened from the
command palette or a shortcut. The data sources already exist (`GitDetect`,
`PRDetect`, `GitWorktree.list`, workspace context).

## 8. Plan

Each PR is reviewable on its own. Several touch files owned by PRs that are
open right now; those wait for them to merge.

| # | PR | Depends on | Waits for |
| --- | --- | --- | --- |
| 1 | Name Claude sessions `<workspace> · <space>` | none | none |
| 2 | Project model, `projects.json`, migration, management UI | none | `fix/state-backups`, `fix/claude-resume-session-id` |
| 3 | Repo anchors and routing, Inbox | 2 | `perf/git-polling`, `fix/url-scheme-auth` |
| 4 | Brief: storage, editing, Claude and Codex injection | 2 | none |
| 5 | Per-project defaults | 2 | `fix/url-scheme-auth`, `fix/codex-default-mode` |
| 6 | Session ledger and resume | 2 | `fix/claude-resume-session-id` |
| 7 | Project view | 2, 3 | `perf/git-polling` |
| 8 | "Finish" (PR merged, then remove worktree) | 7 | none |

PR 1 needs no project model. It touches `claudeCommand`, which
`fix/claude-resume-session-id` may also change; whichever lands second rebases.

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
