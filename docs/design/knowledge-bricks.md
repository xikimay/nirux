# Knowledge bricks

What agents learn in a space, kept as facts that prove themselves and
reach an agent only when they serve. Shown in Space Settings › Memory
("What agents know"), beside the brief, the team's files and Claude Code's
memory; no new place.

## The pieces

- **Proof**: something outside the base that a machine checks without a
  model. A merged pull request or a commit on the base branch, a file, words
  a file holds (line breaks and comment marks aside), a committed test (its
  function), words a web page shows, or what the user said on a day.
- **Brick**: one sentence on at least one proof, about files of one
  repository or folder (paths, folders or `*`/`**` patterns), with a subject
  of a few words. Never edited: its file under `bricks/` is named by the
  hash of its content and written once. When it stops being true it closes,
  and a new brick replaces it (`replaces`).
- **Recheck**: Nirux checks each standing brick again whenever its
  repository's base branch moves, every 5 minutes at most, and all of them
  once a day, pages included. It reads git objects at the tip (through the git dir,
  bare repositories too), never a working tree, and runs nothing a brick
  holds. The base is `origin`'s default branch as fetched, else the local
  main or master, never a checkout's HEAD. A proof that no longer holds
  makes its brick **failing** (not served); the next check closes it, with
  why, or clears it: a page down once or a stray tip never closes a brick for
  good.

## Up to date

- A pull request, a commit or the user's words prove a fact *was* true.
  A brick with no file, text, test or page proof expires 90 days after its
  validation or its last confirmation, and isn't served until the user
  confirms it again ("Still True").
- A brick about something macOS may change (`macos`) expires on another
  major version until confirmed there.
- **Suspect**: when the user's own prompt names a brick's subject and says
  something is wrong ("no", "not", "wrong", "non", "pas", "faux"…) in a
  session that received it (Claude's UserPromptSubmit, agy's first model
  call of a turn; never a line Nirux typed: a Mission's, a pull request
  round's), that counts as a correction: the brick is no longer served until
  confirmed or closed.

## Who writes

The Lead proposes (`propose_brick`). Nirux refuses a proposal whose proofs
don't all hold at the base branch's tip, a brick that exists or was
dismissed, more than 3 waiting, more than 20 standing in the space. The user
validates or dismisses each proposal in Space Memory; validating checks the
proofs once more. Nothing else creates a brick.

## Reaching agents

Nothing is loaded by default. A brick reaches an agent when it reads or
edits a file under its paths, once per session (a compacted Claude
conversation may get it again), within 3,000 bytes per session (about 750
tokens):

- **Claude Code**: the PostToolUse of Read, Edit, MultiEdit, Write and
  NotebookEdit returns the bricks as `additionalContext` (measured on
  2.1.332).
- **agy**: a file tool's PostToolUse sets them aside, and the next
  PreInvocation injects them as a system message (measured on 1.5.18). Both
  hooks are guarded on the space serving bricks, so a model call doesn't
  start Nirux for nothing.
- **Codex** opens files through its shell, where Nirux doesn't see them. It
  gets, at a new thread's start, the bricks about the files its branch
  already changes, after the brief in its `developer_instructions` (unless
  the user's Codex config sets its own); a resumed thread keeps what it got,
  and a restarted column gets the brief alone once what agents get changed. Codex 0.171 has a PostToolUse hook
  with `additionalContext`, behind its own hook trust: not used yet.

`memory_search` finds the bricks agents may get now; the rest is found by
search too. Space Settings › Defaults › "Give agents the space's bricks"
turns it all off: nothing is served, searched or rechecked.

## Measure

`uses.jsonl` (90 days, the newest 10,000 lines) records each brick reaching a task and each
correction after it, never a prompt's text. Space Memory shows, per brick,
how many tasks it reached and in how many a correction followed.

## Files

Under `<state dir>/projects/<space id>/knowledge/`, 0700/0600:
`bricks/<id>.json` (immutable), `state.json` (checks, closing, suspicion,
confirmation, proposals), `served.json` (what the hook receiver hands out,
absent when nothing is), `sessions/` (what each agent session got, 7 days),
`uses.jsonl`, `codex/<task>.toml`.

## Later

Links from rules, procedures and other bricks to the bricks they rest on,
flagged when one closes; an agents' flag tool (a gap, an error, a
contradiction) with no right to write; CI failures making a brick suspect.
