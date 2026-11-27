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
  main or master, never a checkout's HEAD. A check git or the network
  didn't answer is tried again at the next pass: the tip and the daily
  check are recorded only once every brick of the repository got an answer.
  A commit is off the branch only when git says the object is missing;
  commit proofs are kept as full SHAs, resolved when proposed. A proof that no longer holds
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
- **Corrections**: a sentence the user typed (never a line Nirux typed: a
  Mission's, a pull request round's) in a session that received the brick,
  naming its subject and saying it is wrong ("wrong", "incorrect", "faux",
  "erreur"…, or opening on "No," / "Non,"), is recorded on the brick. A
  plain negation ("the layer is not updating, fix it") never counts.
  Corrections in two different tasks since the brick was last confirmed
  make it **suspect**: not served until the user confirms it or closes it.

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
  and a restarted column gets the brief alone once what agents get changed.
  The launch writes the brief at once and the bricks off the main thread
  (git) as the column starts: a launch line read first gets the brief
  alone. Codex 0.171 has a PostToolUse hook with `additionalContext`,
  behind its own hook trust: not used yet.

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
`uses.jsonl`, `flags.jsonl`, `codex/<task>.toml`. A session's record lives while hooks
read it, and goes 7 days after the last.

## Limits

- The receiver finds the space by the terminal's `NIRUX_PROFILE_ID`, kept
  cheap for a hook that runs at every tool use. A task moved to another
  space keeps its old space's bricks until its shells restart.

## Links

Whatever is built on bricks says which ones it rests on:

- a brick, through `rests_on` (part of its content, so of its id); each
  must be served when it is proposed;
- any item of "What agents know" (a brief rule, a team rule, a memory), by
  citing the brick's id (`b-…`) in its text.

**Flagging in chain**: when a brick stops being served (closed, failing,
suspect, expired, or itself flagged), a brick resting on it is **flagged**,
and not served until the user confirms it after that ("Still True") or
closes it; down the chain too. A rule or memory citing it shows "flagged"
in Space Memory and in `memory_search`'s excerpt, with which brick and why:
the user edits it. An id the space doesn't hold (a CLAUDE.md shared with
another space, a proposal) flags nothing.

## Flags

`flag_knowledge`, for every agent Nirux starts, writes a signal and nothing
else to `knowledge/flags.jsonl` (90 days): a **gap** (a fact the knowledge
lacked), an **error** (a brick proven wrong: a test, CI, the code), a
**contradiction** (two bricks, or a brick and the code, disagree). One line
each; text that looks like a secret or contact details is refused; the
same flag once, five flags at most, per task and day; the newest 1,000
are kept. The space is the one whose bricks the agent was served.

- A flag naming a brick shows on its card (those since its last
  confirmation); an error or contradiction from a task that received the
  brick counts like a correction. Two tasks since the brick was last
  confirmed make it suspect when one of them is the user's correction;
  agents alone need three (a Lead and its task, or one CI failure in a
  train, may share one misreading). That is also how CI breaking on a brick
  reaches it.
- A flag naming no brick is listed in Space Memory for the user, who
  dismisses it or asks the Lead for a brick. No agent proposes bricks from
  flags on its own.
