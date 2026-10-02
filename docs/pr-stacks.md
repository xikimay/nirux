# Stacked Pull Requests

Status: v1 implemented. Validated by the user on 2026-10-02, with the
recommendations below.

A **stack** is a series of pull requests where each one targets the previous
one's branch: #52 on `main`, #53 on #52's branch, #54 on #53's. On a 6-PR
stack the user kept asking where they were ("PR 3 of what?"), and after each
merge had to bring the next PR back onto `main` by hand.

What the [Project Board](project-board.md) does today:

- Rows with an open PR sort by number. Nothing says #53 sits on #52.
- The Queue column reads "targets feat/x" for every PR but the first, and the
  queue refuses them (`MergeQueue.openExclusion`, `.otherBase`).
- After #52 merges, #53 still targets #52's branch, forever. GitHub retargets a
  PR only when its base branch is **deleted** after the merge ([GitHub
  docs][merging]). Nirux never deletes a remote branch (the queue never passes
  `--delete-branch`, Clean Up never touches the remote), and `xikimay/nirux`
  has `delete_branch_on_merge` off.

## Proposed shape

**1. Detect stacks from data the board already has.** The open batch reads
`headRefName` and `baseRefName`; the merged list (every 10 minutes, at once
when a PR leaves the open list) reads both too. No new call.

- A stack is a chain of open PRs from the configured repository where a PR's
  base is another open PR's head. Its root targets the configured base branch,
  or a branch whose PR merged.
- Pure function in `ProjectBoard`, table-tested like `rows`.

**2. Show it.**

- PR column: `#53 · 2/4`. Tooltip: `Stack: #52 → #53 → #54 → #55, on main`.
- A stack's rows stay together, in chain order, at the place of its root
  (group 2 stays oldest first for everything else).
- Queue column of a PR whose base is still open: "after #52" instead of
  "targets feat/x". Still refused.

**3. After a base merges: Retarget.** An open PR whose base is the head of a
merged PR reads "base #52 merged", and offers **Retarget to main**:

- One click on one row, in the Queue column (where Add to Queue sits):
  `gh api --hostname github.com --method PATCH repos/<owner/name>/pulls/53 -f
  base=<merged PR's base>`, REST like the queue's mutations, then the board
  reads the open pull requests again. The new base is the merged PR's base,
  as GitHub itself would pick. A failure shows in the header until Refresh.
- A draft can be retargeted too; the cell still says why it can't join.
- Then the PR can join the queue like any other. The queue's step 2 already
  merges `main` into the branch (`update-branch`, no rebase, no force push),
  and a conflict stops it as today (section 3.3, Ask Agent to Resolve).
- A dry-run build doesn't send it: the button is disabled and says what it
  would run, like the queue.

**Not in scope:** follow-up PRs, the sidebar card, the queue engine (v1).

## Decided

- **v1 leaves the queue engine alone.** The queue still refuses a PR until it
  targets the base, so a 6-PR stack takes 6 Retarget + Start. v2, its own PR:
  the engine retargets the next entry in preflight when its base is the head
  of a PR it just merged in this run, then updates it as usual.
- **Retarget has no confirmation sheet.** It changes no code and can be
  undone. Its tooltip says the exact command.
- **A fork** (two PRs on one branch) reads `on #52`, without `n/N`.
- **`n/N` counts open pull requests.** Merged ones leave the stack: once #52
  merged, #53 reads `1/2`, its tooltip naming the merged base.
- **A loop** (PRs based on each other) has no root: no stack.
- **A PR on the base branch is never retargeted**, even if a merged PR once
  had that branch as its head.

[merging]: https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/merging-a-pull-request
