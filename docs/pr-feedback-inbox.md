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

## Decided

- **Agent working:** Address is refused until it is idle. A queued message
  would land in the middle of a turn.
- **Claude only:** `/receiving-code-review` is a Claude skill. A workspace
  with only Codex agents reads "no Claude agent running".
- **Only bots and roles count** (added after the security review): anyone can
  comment on a public repository, and Address hands the comments to an agent
  that has the user's tools (section 1).
- **Noisy bots** (Vercel, codecov): nothing for now. The "newer than the head
  commit" rule already drops comments created once and edited after.

## Summary

| Part | What it gives | Main mechanism |
| --- | --- | --- |
| Feedback read | Unresolved threads and new comments of the workspace's open PR | One `gh api graphql` call per PR, on the existing PR refresh |
| Card line | "💬 2 · 🤖 3", hidden at zero, a menu on click | One more row under the PR rows of the card |
| Address | Types `/receiving-code-review …` into the agent | `sendRemotePrompt(agentUUID:prompt:)`, the Telegram path |

## 1. What counts as feedback

Only on an **open** pull request.

- **Ours never counts:** comments by the PR's author or by the `gh` user. The
  agent posts with that account, and a workspace can sit on a teammate's PR.
- **Who counts:** a bot (`author.__typename == "Bot"`) or someone with a role
  on the repository (`authorAssociation` OWNER, MEMBER or COLLABORATOR).
  Anyone can comment on a public repository, and Address hands what counts to
  an agent. A comment a maintainer hid (`isMinimized`) doesn't count either.
  GraphQL gives `claude`, not `claude[bot]` (checked on
  anthropics/claude-code-action#1867).
- **Review threads** with `isResolved == false`, outdated ones included (they
  read "outdated" in the menu). The thread's first comment decides who it is
  from.
- **Conversation comments and review bodies** (non-empty, not pending) have no
  resolved state. One counts when it is newer than both the head commit and
  our last non-empty conversation comment or review: a push or a reply deals
  with it. An inline reply comes as a review with an empty body, so it doesn't
  move that cutoff. No state is stored. A merge of `main` into the branch
  counts as a push: comments before it drop, answered or not.

Source: [PullRequestReviewThread](https://docs.github.com/en/graphql/reference/objects#pullrequestreviewthread),
[PullRequest](https://docs.github.com/en/graphql/reference/objects#pullrequest),
[CommentAuthorAssociation](https://docs.github.com/en/graphql/reference/enums#commentauthorassociation).

## 2. Data

- One query per open PR, on the PR's own host: `viewer`,
  `reviewThreads(last: 100)` (the newest) with the first comment of each,
  `comments(last: 50)`, `reviews(last: 50)`, the head commit's date. It costs
  1 point of the 5000 per hour (measured).
- It runs after each read of an open PR, changed or not, so it follows the PR
  refresh cadence (focused 2 min, 30 s while hot; background 10 min, 2 min
  while hot) and never runs for an inactive workspace. `PRDetect` itself
  doesn't change.
- `WorkspaceState.prFeedback`, cleared when the PR changes or stops being
  open. A failed read keeps the last value; a read started before a newer one
  is dropped.
- The sidebar gets only the summary string, so the shared card renderer gains
  one row.

## 3. Card line and menu

- Under the PR's CI and review rows: "💬 2 · 🤖 3", either half hidden at zero,
  the line hidden when both are. Human first: it is the one that blocks a merge.
- Click opens a menu (the card's workspace is found by id):
  - the items, newest first, at most 10: author, `path:line` or "comment",
    first line of the body. Each opens its URL. "N More on GitHub" opens the
    PR;
  - **Address**, then **Address Bot Feedback** when both groups exist.

## 4. Address

- Sends `/receiving-code-review Address this feedback on PR #52 (<url>): <item
  URLs>`. The URLs are the scope's items, so the agent addresses what the user
  saw, not whatever else the PR holds.
- Target: the workspace's focused Claude agent, else its first one, among
  those whose folder is in the PR's checkout. The menu disables Address, with
  the reason, when there is none, when it is working or when a dialog is open.
  The click drains the hook queue and checks again, then `sendRemotePrompt`
  checks the dialog once more before typing.
- feat/review-ritual-badges needs the same injection. Both call the existing
  `sendRemotePrompt` unchanged, so neither branch touches it.

## 5. Not now

- Replying to or resolving threads from Nirux.
- A Project Board column. The same `prFeedback` can feed it later.
- A notification when new feedback arrives.

## 6. Tests

- Classifier on JSON fixtures: resolved, outdated, ours (author and viewer),
  roles and bots, minimized, bot vs human, before and after the head commit,
  after our comment or review, an inline reply's empty review, pending and
  empty reviews.
- The query's host, the prompt, the refusals.
- The card row, its menu action and its height; feedback cleared with the PR.
