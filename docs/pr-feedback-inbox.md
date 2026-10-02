# PR Feedback Inbox

Status: validated by the user on 2026-10-02, with the three proposals below, and
implemented.

In three weeks the user asked an agent about 20 times to "check the comments"
on its pull request (Claude bot findings, github-actions, reviewers), then
typed `/receiving-code-review` 13 times. Nirux already reads each workspace's
pull request, but not its feedback.

This proposes one line on the sidebar card, "💬 2 · 🤖 3", for the feedback
nobody has dealt with yet, humans and bots apart, and an **Address** action
that sends `/receiving-code-review` to the workspace's agent.

## Summary

| Part | What it gives | Main mechanism |
| --- | --- | --- |
| Feedback read | Unresolved threads and new comments of the workspace's open PR | One `gh api graphql` call per PR, on the existing PR refresh |
| Card line | "💬 2 · 🤖 3", hidden at zero, a menu on click | One more row under the PR rows of the card |
| Address | Types `/receiving-code-review …` into the agent | `sendRemotePrompt(agentUUID:prompt:)`, the Telegram path |

## 1. What counts as feedback

Only on an **open** pull request. Comments by the PR's author don't count: the
agent posts with the user's `gh` account.

- **Review threads** with `isResolved == false`, outdated ones included (they
  read "outdated" in the menu). The thread's first comment decides who it is
  from.
- **Conversation comments and review bodies** (non-empty, not pending) have no
  resolved state. One counts when it is newer than both the head commit and
  the author's last conversation comment: a push or a reply deals with it. No
  state is stored.
- **Bot** = `author.__typename == "Bot"`. GraphQL gives `claude`, not
  `claude[bot]` (checked on anthropics/claude-code-action#1867), so the
  `[bot]` suffix only matters if a REST source is added later. Everything else
  is human.

Source: [PullRequestReviewThread](https://docs.github.com/en/graphql/reference/objects#pullrequestreviewthread),
[PullRequest](https://docs.github.com/en/graphql/reference/objects#pullrequest).

## 2. Data

- One query per open PR: `reviewThreads(first: 100)` with the first comment of
  each, `comments(last: 50)`, `reviews(last: 50)`, the head commit's date.
  It costs 1 point of the 5000 per hour (measured).
- It runs right after `PRDetect` applies an open PR, so it follows the PR
  refresh cadence (focused 2 min, 30 s while hot; background 10 min) and never
  runs for an inactive workspace. `PRDetect` itself doesn't change.
- `WorkspaceState.prFeedback`, cleared with `prInfo`. A failed read keeps the
  last value.
- New code in `Util/PRFeedback.swift` (fetch and a pure classifier), so the
  shared card renderer only gains the row.

## 3. Card line and menu

- Under the PR's CI and review rows: "💬 2 · 🤖 3", either half hidden at zero,
  the line hidden when both are. Human first: it is the one that blocks a merge.
- Click opens a menu:
  - the items, newest first, at most 10: author, `file:line` or "comment",
    first line of the body. Each opens its URL;
  - **Address** (all of it), then **Address bot feedback** when both groups
    exist.

## 4. Address

- Sends `/receiving-code-review Address the unresolved review threads and new
  comments on PR #52 (<url>).`, scoped to bots for the second item.
- Target: the workspace's focused agent column, else its first live agent.
  The guard is `sendRemotePrompt`'s: a live recognized agent process, no open
  dialog. Disabled, with the reason, when there is no agent or a dialog is
  open.
- feat/review-ritual-badges needs the same injection. Both call the existing
  `sendRemotePrompt` unchanged, so neither branch touches it.

## 5. Not now

- Replying to or resolving threads from Nirux.
- A Project Board column. The same `prFeedback` can feed it later.
- A notification when new feedback arrives.

## Decided

- **Agent working:** Address is refused until it is idle. A queued message
  would land in the middle of a turn.
- **Claude only:** `/receiving-code-review` is a Claude skill. A workspace
  with only Codex agents reads "no Claude agent running".
- **Noisy bots** (Vercel, codecov): nothing for now. The "newer than the head
  commit" rule already drops comments created once and edited after.

## 6. Tests

- Classifier on JSON fixtures: resolved, outdated, author's own, bot vs human,
  comment before and after the head commit, after an author reply, pending
  review.
- Prompt text for both scopes.
- Menu state: disabled reasons for no agent and an open dialog.
