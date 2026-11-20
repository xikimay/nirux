# Task Dependencies

> **Design record:** in three parts: the wait and the held message (part 1), waiting tasks (part 2), the Board's order (part 3).\
> **Differs today:** only part 1 is built: `tell`'s `after`. `start_task`'s `after`, `set_task_after` and the Board's order are still to come.\
> **User guide:** [Spaces and tasks](../spaces-and-tasks.md#the-lead).

Status: addition 3 of the factory-article review, approved by the user on
2026-11-21 ("suite logique"); this plan was approved by the Lead the same
day. Lane 2: Lead MCP, task start, persistence. Nothing here merges a pull
request.

## 1. The primitive: a merge wait, two actions

One persisted record, `MergeWait`: "when task A's pull request merges, do X".
It is kept **on the workspace it acts on** (`WorkspaceState.waits`, saved with
the layout in `PersistedWorkspace`, lenient decode). Two actions:

- **tell** (`tell` gains `after:`): type a message into an existing task once
  A's PR merges. This is the deferred tell, and it covers the case of
  2026-11-20 (#651 → #657 → #660 → #666, each told by hand to merge
  origin/main). On release it goes through the normal tell path (the Lead's
  Mission, the task's own Mission with `leadSender`, or a one-way Mission),
  so it then waits a day for a free prompt, sends held notices, and follows a
  resumed conversation like any tell.
- **start** (`start_task` gains `after:`): a waiting task with no worktree and
  no agent, which starts once A's PR merges.

**Answer to the handover's question: both, on one primitive.** `start_task`'s
`after:` can't be built on a deferred tell, because before the merge there is
no agent to type into. The shared part is the wait itself: resolving A,
following its PR, persistence, the failure path and the row wording.

`after:` names a task of the space, resolved by `spaceTask`. It is refused for:

- the Lead, the task itself, or a cycle (B after A after B);
- a task without a repository (it has no PR);
- a task whose PR already closed unmerged.

When A's PR is already merged, it releases at once and the answer says so.
Chains work: C after B, where B is still waiting, follows B's PR once B
starts and opens one. The wait keys on workspace ids, and a waiting task
keeps its id when it starts.

## 2. States and persistence

`MergeWait` holds:

- `awaited`: A's workspace id;
- `pullRequest`: A's PR url and number, recorded at each read that sees it
  open (A may have none yet);
- `action`: `.tell(message)` or `.start(PendingStart)`;
- `failure`: the reason and the time, once failed.

`PendingStart` holds the description, the template (a copy taken when the
wait is created) and the repository's anchor key. Nirux reads the agent and
the space's Lead at release, not before.

States:

- **waiting**;
- **released**: the tell goes to the Mission ledger, or the task starts, and
  the record is removed;
- **failed**.

A failed tell is removed and the Lead gets a notice. That notice lives in
memory, like the held and given-up notices of tells today; this is a known
gap. A failed start stays, and its row turns **Needs you** (amber) until the
Lead or the user acts.

Everything survives a relaunch: it is in state.json with its workspace, and
saved at once (`saveState`) when a wait is added or settles. Nothing goes in
missions.json before release: an instruction there starts its 24 h clock
when it is written.

## 3. How a merge is detected (no new poller)

- **The existing per-workspace PR read** (`refreshPRInfo`, next to
  `followUpPullRequest`), when it updates A:
  - OPEN: record url and number;
  - MERGED: release (also when first seen merged after a relaunch, as
    `clearLeadContext` does);
  - CLOSED: fail.
- **One `gh pr view <url> --json state` read** when the poll stops showing
  the recorded PR: OPEN → nil, a new url, or the first read after a relaunch.
  This is needed because `PRDetect` drops a merged PR whose head isn't the
  local HEAD, which is the case after a merge queue's update-branch or a
  dirty tree. It is one read per change of what the poll sees, not a timer.
- **A closes:**
  - by `close_task`: its `WorktreeCleanup` inspection already holds the
    verdict;
  - by any other close: one read of the recorded url; no PR ever recorded
    means it fails.
- **Cadence:** a workspace that a wait follows is read at the "hot" cadence
  (120 s in the background instead of 600 s), and still read while archived.
  Both changes are in `PullRequestRefreshPolicy` and `PRDetect.shouldRefresh`,
  one predicate.
- **Asking again:** while reads keep saying the same thing (no pull request,
  say, for a branch pushed under another name), GitHub is asked again at most
  every 10 minutes (`MergeWait.lookUpInterval`), and only when a read happens.
  A look-up GitHub doesn't answer is asked again at the next read. Once A is
  gone, there is no next read, so the wait fails and says why.

## 4. Release (start) and failure

On release, the same workspace (same id, row, parent and place) gets its
worktree and its agent column. Nirux:

1. fetches origin's base, then and there;
2. picks the branch with `unusedBranch`;
3. writes the handover: the description, plus "started once #657 merged";
4. launches the space's default agent;
5. creates the Mission to the space's current Lead.

`WorkspaceState.cwd` becomes `private(set)`, set once, before any shell runs.

**Failure turns the row to Needs you and sends the Lead one notice**, for any
of these reasons:

- A's PR closed unmerged;
- A closed without a merge;
- the fetch failed (no fallback to the last fetch: starting from a stale base
  would defeat the point);
- the worktree couldn't be made;
- the repository left the space.

**The Lead's options when a start fails:**

- `set_task_after` (new tool) with `after` left out: start it now;
- `set_task_after` with another task: re-point it;
- `close_task`: drop it (no worktree to clean).

The row's menu offers Start Now and Close.

**Refusals for a waiting task:** tell ("it hasn't started"), sub-tasks under
it, and the PR follow-up.

**Guards:** `isTask` stays false until it starts; the Board doesn't take its
missing folder for "folder is gone"; Clean Up, lazy restore and Resume All
skip it.

**`after:` is refused while "Starts tasks without asking" is off.** The New
sheet can't hold a wait, and a sheet popping up hours later is worse.

## 5. Wording

**Sidebar, waiting task:**

- grey, blocked mark: "Waits for #657 · Fix login", or "Waits for “Fix login”
  to merge" while A has no PR;
- amber: "Needs you · #657 closed without merging", "Needs you · “Fix login”
  closed without merging", "Needs you · couldn’t fetch origin/main".

Its column (no terminal) shows what it waits for, the description, and Start
Now.

**Sidebar, task holding a deferred tell:** "After #651 · a message from the
Lead", in the slot of today's "1 message waiting" line.

**Board:**

- a waiting line sits right after the task it waits for, in that task's
  section;
- state `.waiting`, phrase "Starts after #657 merges" or "Starts after “Fix
  login” merges";
- amber when failed, with the same words as the row;
- no station lit, no Clean Up.

**list_tasks:**

- "waits for “Fix login” (#657) to merge, then starts from origin/main";
- "1 message held until #651 merges".

**Lead's instructions:** untouched (2,030/2,048). The guidance goes in the
`after` descriptions and the new tool's schema.

## 6. Pull requests

1. **The wait and the deferred tell:** `MergeWait` and its verdicts, storage
   on the workspace, the PR-read and close hooks, the cadence, `tell`'s
   `after`, the receiving row's line, list_tasks, notices.
2. **Waiting tasks:** `start_task`'s `after`, the waiting workspace and its
   column, the release, Needs you, `set_task_after`, Start Now and Close, the
   guards.
3. **The Board shows the order:** waiting lines after their task, phrase and
   state, amber on failure.

## 7. Tests (each fix proven by reverting it once)

**PR 1:**

- `MergeWaitTests` (pure):
  - OPEN→MERGED and OPEN→CLOSED;
  - OPEN→nil, then the read gives MERGED, CLOSED or OPEN;
  - first read merged after a relaunch;
  - url changed;
  - A closed with and without a PR;
  - chains and cycles.
- `PersistenceTests`: round trip, plus an unknown action decoded leniently.
- Lead tool flow tests:
  - `tell` with `after` answers and stores;
  - a simulated merge puts the instruction in the ledger;
  - a close without a merge sends the notice;
  - the receiver closing first drops the wait.
- `NiruxMCPServerTests` and `LeadChannelTests`.

**PR 2:**

- `WaitingTaskTests`: release with a stub creator, each Needs-you reason,
  Start Now, re-point.
- A new UI flow class for the row and its column, which takes the 10-run
  flake gate.
- Persistence.
- `LeadChannelTests`: the new tool, in the definitions' order.

**PR 3:**

- `BoardStages` unit and line tests (order, phrase, amber);
- an offscreen render for the Lead.

Every test waits on state, never on a fixed delay.
