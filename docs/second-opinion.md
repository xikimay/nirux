# Second Opinion

Status: design, validated on 2026-10-03. Implemented as the bundled `nirux-second-opinion` skill.

The user runs Codex next to Claude for a second opinion, then pastes its answer
back into Claude ("codex me dit: ...", long verification reports). Each round
trip is a manual copy of the question one way and of the answer the other way.

## Proposed shape

**A bundled skill, `nirux-second-opinion`**, installed with `nirux-worktree` and
`nirux-show-code` (`agentSkills` in `NiruxShellView+ExternalTools.swift`). No
new Nirux code path.

- **Trigger:** the user asks for it ("second opinion", "demande à Codex",
  "qu'en pense Codex", `/nirux-second-opinion`). Claude never asks Codex on its
  own.
- **Brief:** Claude writes a self-contained brief to a `mktemp` file: the
  question, its own answer or claim, and the files, diff or commands that
  support it. Codex sees the same worktree, so the brief points at files rather
  than pasting them.
- **Run:** `codex exec -s read-only -C "$PWD" -o "$out" - < "$brief"`, in the
  background (a run can take minutes). Read-only: Codex checks, it doesn't edit.
  The user's Codex config (model, effort) applies.
- **Answer:** Claude shows Codex's reply verbatim, as a quote labelled "Codex",
  then says where it agrees, where it doesn't (with evidence), and what it would
  change. It applies nothing without the user's go.
- **Follow-up:** a new `codex exec` whose brief includes the previous reply. No
  `codex exec resume --last`: it could pick the user's own Codex column in the
  same folder.

Already true today (README, session restore): a `codex exec` launched from a
Claude column keeps its own session and doesn't drive the column's status,
notifications or restore. Checked on 2026-10-03 with Codex CLI 0.154: its
`notify` fires with the column's `NIRUX_AGENT_UUID` (`"client":"codex_exec"`),
and Nirux drops it (`AgentHookCenter.isNestedCodexHook`): the reply reaches
neither Activity nor the workspace summary.

**Not the Codex plugin for Claude Code** (`/codex:rescue`). That one hands a
task to Codex, write-capable by default, and returns its output verbatim with
no comment. Here Codex only checks, and Claude weighs the reply against its
own answer. The skill doesn't need the plugin.

## Rejected for now

- **Reusing a live Codex column.** Nirux would have to type into its TUI and
  read the reply back: guarded injection, which `feat/mission-tell` decides.
  This can be revisited on top of it.
- **A palette action.** Starting it from Nirux means typing into the Claude
  column, the same injection. `/nirux-second-opinion` is already one step.
- **Showing the reply in Activity or a Draft.** The answer is input for Claude,
  so it belongs in Claude's turn.

## Open questions

- Also the reverse (`claude -p` from a Codex column)? Not asked for, left out.
