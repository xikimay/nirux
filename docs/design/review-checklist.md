# Review checklist

> **Design record:** approved by the Lead on 2026-11-27. Shipped for Claude Code; see [Spaces and tasks](../spaces-and-tasks.md#the-daily-pass).

The space knowledge base study audited the 18 review findings that came back across tasks: about 13 were forgotten checks (a listed change left untested, a wait without end, a diagnostic that hides its result), not missing knowledge. Those belong to code review. So each review gets, as it starts, the kinds of finding the space's reviews keep recording.

## What the reviewer sees

At most 7 lines under one header, about 1,700 characters on 2026-11-27:

    Review checklist from Nirux: this space's reviews recorded these kinds of finding in two tasks or more over the last 30 days, the most tasks first. Check the change for each of them too.
    - listed-change-untested · 11 tasks (#828, #811, #824, #818, #804 and 6 more) · latest: “#864: loading the saved flag, the click wiring and the Fresh start / Close branches are untested.”
    - unbounded-wait · 8 tasks (fix/queue-merge-stale-open-prs, #816, #808, #799, #798 and 3 more) · latest: “The waiter is answered only by a read nothing reset while it ran…”

- **Derived, never written by hand:** the kinds `record_review` kept in the last 30 days (`review-findings.jsonl`) that showed up in two tasks or more, ordered as `ReviewFindings.kinds` orders them (most tasks, then the latest seen). Each line holds the kind, its tasks (by their latest sighting, the latest first, 5 at most: a task's pull request, else its branch) and its latest finding. The list changes as the findings do. No new `record_review` field.
- **Nothing at session start:** workers load nothing more. The brief, the handover, the templates and `propose_rule` don't change.

## Where it reaches the reviewer

Claude Code 2.1.332 runs `/code-review` as a background fork (a `general-purpose` subagent), typed or through the Skill tool. Measured with canary hooks in 6 interactive runs:

| Hook context | Reaches the forked reviewer |
| --- | --- |
| UserPromptSubmit (typed `/code-review`) | yes |
| PreToolUse / PostToolUse of the Skill call | no: only the session that called it |
| SubagentStart | yes, both paths |

So the receiver (`Nirux --hook claude`) gives the list at **SubagentStart** only, once per reviewer. That event carries no prompt and no skill name. But by then Claude Code has already written `<session>/subagents/agent-<id>.forked-skill.json` beside the transcript, holding `{"skillName": "code-review"}`. A fork whose skill is exactly `code-review` or `premortem` (the last `:` segment, as `ReviewPass` reads commands) gets the list; any other subagent costs one file lookup. The space is the launch's `NIRUX_PROFILE_ID`, else the one Nirux saved for the workspace in state.json: SubagentStart is a synchronous hook, so the receiver reads state.json only when it must. A workspace moved since its shell started gets its old space's list.

SubagentStart (Claude Code 2.0.43) joins the installed hook events; it is older than PermissionRequest's 2.0.56.

## When the file goes away

`forked-skill.json` isn't documented. If Claude Code stops writing it, or runs a review without a fork, the list stops reaching reviewers, so that loss is said:

- The receiver notes each `/code-review` start the hooks name by documented means (typed, or a Skill call), while a list is due, and each list it gives. Both go to `review-checklist.jsonl` (SpaceLog, 8 days). Receivers only append to it: a trim replaces the file another receiver may be appending to, so the app trims it at launch. Not noted: `/code-review` with `ultra` among its arguments (it runs in the cloud), a Skill call whose result says it ran otherwise than as a background fork (`status` other than `forked` with `background: true`), and `/premortem` (only `/code-review` was measured running as a fork; a premortem may run inline). A forked premortem still gets the list, but isn't noted as given either: its list would otherwise pair with a missed `/code-review` in the same session.
- The daily pass counts, per session, the starts a list reached (one list per start, in either order: a fork may start before its Skill call's PostToolUse). When one was missed, the digest gives the counts in a kept section ("The review checklist reached 1 of 3 /code-review starts in this window (an approximate count: nothing to do)."), and that alone isn't news. Only none reached across two sessions or more, what a broken hook looks like, is news and asks for a task: "…reached none of 3 /code-review starts in this window, in 2 sessions: Nirux may no longer tell a review's fork from other subagents. Start a task to find out."
- The count is approximate, on purpose:
  - a typed `/code-review` is noted at UserPromptSubmit, before any fork exists: Esc or a command that fails leaves a start with no list;
  - the app's launch trim can drop a line a receiver appends while it rewrites the file;
  - starts and lists pair per session (the smaller count), not start by start;
  - a start and its list split by the window's edge count as missed once.

## Settings

**Review checklist** in Space Settings › Lead, on by default (`reviewChecklist` in `defaults.json`). Off, or with a `defaults.json` Nirux can't read, no list is given and no start is noted.

## Not covered

- Codex and Antigravity: they get no list (no hook reaches their reviewers).
- A `/code-review` a foreground subagent runs (a foreground fork): Claude Code writes no forked-skill file for it (none of 31 on 2.1.321–2.1.331, by the transcripts on this Mac). On 2.1.332 a background subagent's Skill call ran as a background fork, with the file, and got the list.
- A review Claude Code runs inline (no fork) gets no list; the daily pass counts a `/code-review` run inline as missed.
- Adversarial reviews by agents a task starts itself: SubagentStart doesn't say what they are, and a loose match on their prompt would fire on ordinary prompts.
