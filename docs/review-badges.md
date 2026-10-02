# Review Badges

Status: design validated on 2026-10-03. The badges are implemented; Run
review pipeline (section 5) is a second pull request.

Over three weeks, `/code-review` and `/premortem` were typed 52 times, and
"did we run /code-review and /premortem in that session?" was asked at least 4
times. Nirux already sees every Claude turn through its hooks, but kept no
trace of which review passes ran, nor on which commit.

**Review badges** show, per workspace, which review passes ran on the current
HEAD, going stale after a new commit.

## Decided

- **No new hook event**: the existing `UserPromptSubmit` and `PostToolUse`
  hooks are enough (section 2).
- **Adversarial review** is any prompt that says "advers…", whatever the
  spelling after it (decided with the user): only the flag is kept.
- **Run review pipeline** is a second pull request. It types the prompt
  without Return, behind the Telegram guard (section 5).

## Summary

| Part | What it gives | Main mechanism |
| --- | --- | --- |
| Detection | Knows a review pass started in a column | `UserPromptSubmit` and `PostToolUse` hooks |
| Record | Pass, HEAD SHA, time, per workspace | `WorkspaceState.reviewRuns`, persisted |
| Badges | `CR ✓  PM ✓  CS ·  ADV ·` on the card | One sidebar card row |
| Run pipeline | Types the review prompt into the agent | Second pull request |

## 1. Passes

| Badge | Pass | Detected by |
| --- | --- | --- |
| CR | Code review | command `code-review` |
| PM | Premortem | command `premortem` |
| CS | Code style review | command `code-style-review` |
| ADV | Adversarial review | "advers" anywhere in the prompt or skill name, any case |

A command matches on its last `:` segment, so `plugin:code-review` counts. No
settings: a list the user edits waits for a second user who asks.

## 2. Detection

Two paths reach a skill, and Nirux already receives both:

- **Typed by the user**: `UserPromptSubmit` carries the submitted text in
  `prompt` ([hooks reference][hooks]). A command counts only at the start of
  the prompt, where Claude Code expands it. Typing `/skill` bypasses
  `PreToolUse`, so this path is needed.
- **Invoked by the agent** (a handover that says "run /code-review"): the
  `Skill` tool's `PostToolUse`, with `tool_input.skill`.

Privacy, as the README promises for transcripts: `AgentHookEvent` gains
`reviewPasses`, computed in the hook receiver. The prompt itself is never
stored, never written to `hook-events.jsonl`, never logged.

Rejected: the newer `UserPromptExpansion` event, which gives `command_name`
directly. An unknown event name makes older Claude Code ignore the whole
settings file, the reason `StopFailure` needs a version gate.

Events reach the workspace only once `AgentHookCenter` admitted them as the
column's own agent: a `claude -p` review run from a shell doesn't count.
Codex has no prompt hook: its reviews aren't seen.

## 3. Record and staleness

- On the event, the workspace stores, per pass, `{head, at}`: the HEAD its git
  context reads at that moment. That context follows HEAD within 1 s on
  screen, 5 s in the background (`GitRefreshPolicy`).
- An event older than the stored run doesn't replace it (launch replay). An
  event that arrives before the first git read is dropped.
- **Fresh** when the stored HEAD is the current HEAD, **stale** otherwise. A
  review run before the commit that follows it goes stale at that commit: the
  commit isn't what was reviewed. A confirmation pass makes it fresh again.
- Persisted with the workspace in `state.json` as `reviewRuns`, keyed by the
  pass's raw value. A pass this build doesn't know is dropped on load; an
  older build drops the key after a rollback, which only loses badges.

## 4. Display

- One row on the sidebar card, under the PR rows, when the workspace has a PR
  or a recorded run: `CR ✓  PM ✓  CS ·  ADV ·`. Green: ran on HEAD. Orange:
  ran on an earlier commit. Dot: never ran.
- The tooltip says, per pass, when it ran and on which commit, or "not run".
- Built by `SidebarReviewBadgesRow`, so the card renderer, which other
  in-flight branches touch, gains one call.
- Not on the Project Board for now.

## 5. Run review pipeline (second pull request)

Typing into an agent exists only for Telegram (`sendRemotePrompt`): it
re-verifies a live Claude or Codex column and refuses while a dialog is open.
The button reuses that guard and, like the board's Ask Agent to Resolve,
types the prompt **without Return**: the user reads it and submits it.

The prompt chains the passes missing on HEAD, plus the follow-up list the user
retypes (useless tests, dead code, verbose comments, code that exists in
utils, deletion-first).

[hooks]: https://code.claude.com/docs/en/hooks#userpromptsubmit-input
