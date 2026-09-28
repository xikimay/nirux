# Project Board

Status: design, validated by the user on 2026-09-27. B4 (the config), B1 (the
read-only board), B2 (the merge queue's engine) and B3a (starting, following
and stopping the queue) are implemented; B3b (the journal view and Ask Agent
to Resolve) isn't. What B1, B2 and B3a decided along the way is in sections
2.1, 3.7 and 3.8.

On the night of 2026-09-26, one Claude session coordinated about fifteen
parallel pull requests by hand:

- it launched worktree workspaces, each with a handover;
- it followed their agents, pull requests and CI;
- it merged one pull request at a time: update the branch, wait for `test`,
  merge, wait for the nightly, then the next one, stopping at the first problem;
- it noticed agents stuck on a permission prompt or an API error;
- it cleaned up merged worktrees.

Nirux already knows most of that state, spread over sidebar cards, the Pilot
panel and `gh` calls typed by an agent. This document proposes a **Project
Board**: one table per project, and a **merge queue** that runs the merge
routine above after one click.

It builds on [Projects](projects.md): it is the "Project view" of section 7,
brought forward, and its "Finish" action is the worktree cleanup shipped in #46.

## Decided

- **A board column**, not an evolution of Pilot Mode (section 1). A running
  queue belongs to the app, not to the column (section 3.6).
- **A conflict stops the queue**, and the row offers "Ask Agent to Resolve"
  (section 3.3). The agent merges `main` into its branch: a rebase would need a
  force push.
- **Checks that aren't required:** a red one blocks the merge; a pending one
  doesn't (section 3.2).
- **A post-merge run cancelled by a push from outside the queue stops the
  queue**, which reports what moved the base branch (section 3.4).
- **A PR whose agent is working, or waiting on a dialog such as a permission,
  can't join the queue** (section 3.2).
- **No cap** on the number of merges after one Start. Stop is the brake.
- **The config lives in its own `board.json`** per project, not in
  `projects.json` (section 5).
- **Order: config (B4), read-only board (B1), engine (B2), queue UI (B3)**, and
  a CI change keeping more dated nightlies lands before B3 (section 8).

## Summary

| Part | What it gives | Main mechanism |
| --- | --- | --- |
| Board column | One table per project: branches, agents, PRs, checks, last nightly | New column type; existing git, PR and agent state |
| Merge queue | Merge a confirmed list of PRs one at a time, stop at the first problem | Pure state machine driving `gh`, owned by the app |
| Guardrails | Nothing runs without a click; only confirmed heads merge; every merge and branch update is pinned to a SHA | Confirmation sheet, Stop, journal |
| Config | Repository, required checks, post-merge workflow, merge method per project | `<state dir>/projects/<id>/board.json` |

## 1. Shape

**A new column type, "Project Board".** `docs/projects.md` already decided that
the Project view is a dedicated column type.

- It opens from the command palette ("Open Project Board") in the current
  workspace, usually the project's main checkout, next to the agent that
  coordinates the work.
- It stores the id of the project it shows: at first, the space of the
  workspace it was opened in. Moving that workspace to another space doesn't
  change it. A menu in the header switches project. There is no "all projects"
  view.
- A project has at most one board. Opening a second one, or switching to a
  project that already has one, focuses the existing board. A board whose
  project was deleted says so and offers the menu.
- Like any column, it is on screen only while its workspace is active. A
  running queue therefore also shows in the status bar (section 3.6).
- Persistence: `ColumnKind` gains `projectBoard`. An older nightly decodes an
  unknown kind as a terminal (`PersistedColumn` falls back to `.terminal`), so a
  rollback turns the board into a shell in the workspace's folder. Updating
  again doesn't bring the board back: reopen it. That is harmless.

Rejected:

- **Evolve Pilot Mode.** Pilot Mode is a layout mode: up to three live
  workspaces stacked, each with a 200 pt info panel, for the active space only.
  It is for watching terminals, not for reading a table of fifteen branches, and
  it is toggled on and off. Pilot panels could later show a row's queue state.
- **A floating panel**, like Clean Up. It hides the terminals, and closing it
  loses the view.

## 2. Rows and columns

**A row is a branch of the project's repository**, not a workspace. Pull
requests, checks and cleanup are per branch, and a workspace can close while
its worktree and PR live on.

Where rows come from:

- the open PRs of the configured repository (one batched call, section 6),
  including PRs with no local worktree, for example from a cloud session. They
  show with no agent and can be queued;
- the project's workspaces, active and inactive;
- the worktrees of the repository's local checkouts
  (`git worktree list -z --porcelain`), without bare or prunable entries.

How they match:

- A workspace belongs to the worktree that contains its launch folder: the
  longest match on comparable paths, as worktree cleanup does. Worktrees can
  sit inside the main checkout (for example `.claude/worktrees/`).
- A worktree belongs to a PR by branch. The PR's head repository must be the
  configured repository (`WorktreeCleanup.pullRequest(from:headRepository:)`).
- Several workspaces in one worktree share its row.
- A worktree on a detached HEAD, for example in the middle of a merge, keeps
  its row but shows no PR until it is back on its branch. Queue entries are
  keyed by PR number, so the queue isn't affected.

Order:

1. The main working tree (the first `git worktree list` entry), whatever branch
   it is on.
2. Rows with an open PR or a workspace.
3. A collapsed "Other worktrees" group: worktrees with neither, such as scratch
   or leftover worktrees, with Open and Clean Up.
4. Workspaces in another repository, or outside any repository, without PR
   columns.

| Column | Shows | Source |
| --- | --- | --- |
| Name | Workspace title, else branch. Click focuses the workspace | `WorkspaceState`, git context |
| Agent | waiting (permission: Bash) · working · idle · none. With stuck-agent detection: waiting 12m, stopped on error, exited | `AgentStatusMachine`: state and open dialogs, #38's reasons; stuck states from #55 |
| PR | #52, draft, open, merged or closed; conflicting | Batched `gh pr list` (section 6) |
| Checks | Each required check by name; the others as one summary | The batch's `statusCheckRollup`, for display only |
| Queue | Position, current step, or why the PR can't join | Merge queue (section 3) |
| Actions | Focus, Open, Resume, Clean Up, Add to Queue | Existing commands |

- **Agent** shows the most urgent state among every agent column of the row's
  workspaces: waiting, then working, then idle.
  - "Waiting" means the column has an open dialog (permission, question): a
    pending dialog that no later tool event has superseded, while the agent is
    the column's foreground process and its state isn't `.working`. Once the
    user approves a dialog, it stays pending until the tool finishes, and the
    column reads `.working` meanwhile. An agent that died without ending its
    session leaves dialogs behind, hence the foreground rule.
  - "Working" means the column's state is `.working`.
  - The column's state alone can't tell waiting from idle. A focused column
    reads `.idle` while its dialog is open, and an unfocused one that finished
    its turn reads `.needsAttention`. A finished turn shows as "idle".
  - It says "idle", not "done", because `WorkspacePhase.done` means the PR is
    merged or closed.
- **Resume** (#55) sends `continue` to an agent stopped on an API error, only
  if it is back at its prompt, and reopens the conversation of a `claude` that
  exited mid-turn. It uses the sidebar's actions and refusals: a refused Resume
  shows disabled, with the reason.
- **Clean Up** opens the existing cleanup for that worktree (#46). Today its
  single-worktree entry takes a workspace, so B1 adds one that takes a path. It
  never runs by itself.
- **"Behind"** isn't a column: it costs one REST call per PR. The queue computes
  it for queued PRs only (section 3.2).
- **The header** shows the project, its repository, the last run of the
  post-merge workflow on the base branch ("nightly: success 20:27, 60e0ff2"),
  the queue controls, and a Refresh button.
- Left for later: Projects' brief preview and pinned URLs (section 7 there).

### 2.1 Decided while building B1

Choices the design left open, taken as the most conservative option and
documented in B1's pull request:

- **Order inside group 2:** rows with an open pull request by number, oldest
  first, as the queue orders them by default; then the rows with a workspace
  but no open pull request, by name. Groups 3 and 4 follow, by name and by
  sidebar order.
- **A merged pull request** marks its branch's worktree ("#52 merged") when
  no open one does and the worktree is still at its head: a branch name
  reused since has new work. Such a worktree without a workspace goes to
  "Other worktrees", ready for Clean Up.
- **The project's local repositories** are those with a remote naming the
  configured `owner/name`, whatever the host: an SSH host alias
  (`git@github-work:…`) counts.
- **A bare repository** has no main working tree: its first entry gets no
  row, and its linked worktrees sort like any other.
- **A fork's pull request** gets no row: it matches no branch, and the queue
  refuses it anyway.
- **A workspace whose folder is gone** (its worktree was removed under it)
  gets a row of its own in group 4, "folder is gone", with Clean Up, which
  closes it. It doesn't join the checkout around it.
- **Rows show workspaces in sidebar order**, active ones first. A row reads
  "inactive" only when all its workspaces are.
- **Checks, for display:** the latest run of each check counts, a rerun not
  started yet included; a skipped or neutral job doesn't hide a success.
- **Urgency across a row's agent columns:** stopped on error, exited mid-turn,
  waiting past the stuck threshold, waiting, working, idle. Failures come
  first: nothing but the user moves them. "Waiting" follows the stuck-agent
  check's rule (`AgentStatusMachine.visibleDialog`): a dialog of an earlier
  `claude`, or one a keystroke reached since (an answer, or Esc, which fires
  no hook), doesn't read as waiting.
- **Buttons, most urgent first:** Resume, Focus, Open, Clean Up. A column too
  narrow for all of them leaves out the last ones; clicking the name still
  focuses. Focus goes to the most urgent agent column of the row.
- **Open** opens a workspace with a shell in the worktree, in the board's
  project, as "Open Worktree" does. It launches no agent.
- **On screen** means its workspace is shown (selected, or any workspace of
  the space in Pilot Mode), with Nirux in front and its window neither
  minimized nor covered. Periodic reads run only then, on the status
  refresh; in the background they pause, as the sidebar's pull request reads
  do. Opening the board, Refresh and a saved board.json read at once when
  its workspace is shown. Refresh doesn't start a read already running.
- The board reads nothing while board.json is being read again, nor for a
  deleted project or one without a repository. Its clock keeps counting
  while the Mac sleeps, so everything is due after a wake. A pull request that leaves the open list makes the merged
  list due at once. A finished clean-up lists the worktrees again.
- **Without a repository**, or with an unreadable `board.json`, the board says
  so instead of listing rows, and calls no `gh`. Board Settings opens by
  itself only when the board is opened from the palette, not when it is
  restored at launch.
- **Clean Up** runs "Clean Up Worktree…" (#46) on the row's folder
  (`requestWorktreeCleanup(path:)`), with its checks and confirmation.

## 3. Merge queue

### 3.1 Why not GitHub's merge queue or auto-merge

- Neither waits for a workflow that runs **after** a merge. Nirux's nightly runs
  on every push to `main`, publishes a release to every install through
  Sparkle, and uses `cancel-in-progress`. Two merges within its run cancel the
  first nightly, so a failure can no longer be pinned on one PR. Waiting for the
  nightly between merges is the point of the routine.
- Both need GitHub-side settings (branch protection or rulesets, auto-merge),
  which change the repository for every contributor. On 2026-09-27
  `xikimay/nirux` has auto-merge off and **no protection on `main`**: GitHub
  accepts any merge, even with red checks. The queue's own checks are the only
  guard, so they fail closed.

### 3.2 Steps

The user picks PRs ("Add to Queue") and presses Start. Start always opens the
confirmation sheet (section 4), which shows each PR's current head. That head
is the PR's **confirmed head**. The queue merges it, or the merge commits of its
own branch updates on top of it, and nothing else.

Definitions:

- **Only the latest run per check name and workflow counts** (REST
  `filter=latest`, GraphQL `LATEST`), for green and red alike. A rerun replaces
  the run it reran.
- **A green check** is a check run with the configured name (optionally
  `Workflow / job`) that concluded SUCCESS on the PR's current head. If jobs of
  several workflows match the name, the latest run of each must be SUCCESS.
  NEUTRAL and SKIPPED aren't green.
- **A red check** concluded FAILURE, CANCELLED, TIMED_OUT, ACTION_REQUIRED,
  STARTUP_FAILURE or STALE, or is a commit status in ERROR or FAILURE. NEUTRAL
  and SKIPPED aren't red: CodeQL adds a NEUTRAL "CodeQL" check to every PR.
- **Checks are read by commit**, for example with GraphQL `object(oid:)` on the
  head, or REST `commits/{sha}/check-runs` and `commits/{sha}/status`. The
  rollup from `gh pr list` carries no SHA, so the board only displays it.
- **`mergeable: UNKNOWN`** is normal after every push to the base branch, while
  GitHub recomputes it. The queue re-reads with back-off for up to 2 minutes.
  Only CONFLICTING is a conflict.

For each PR, in order:

1. **Preflight.** Re-read the PR:
   - open, not a draft, based on the configured base branch, with the
     configured repository as head repository (no forks);
   - not set to auto-merge and not in GitHub's merge queue (`autoMergeRequest`,
     `isInMergeQueue`): such a PR could merge itself mid-queue;
   - its head is the confirmed head, or the confirmed head plus the queue's own
     updates. Otherwise the queue stops: "#52 changed since you confirmed it",
     with a link comparing the two heads;
   - no agent working or waiting on a dialog (section 2), in any workspace of
     the row, or in any other workspace with a shell inside the worktree (as
     cleanup's foreign agents). If one is, the queue waits up to 10 minutes
     for it to go idle, then stops;
   - if the branch has a local worktree: no unpushed commits, and no changes to
     tracked files. Untracked files, such as the handover, don't count. Unpushed
     means REST `compare/{PR head}...{local HEAD}` answers `ahead_by > 0`, or
     404 because GitHub doesn't have the local commit. After the queue's own
     update the local repository may lack the PR head, so a local ancestry check
     can't decide.
2. **Update the branch, if it is behind.**
   - Behind means REST `compare/{base tip}...{head}` reports `behind_by > 0`.
     Nirux doesn't use `mergeStateStatus`, whose `BEHIND` depends on branch
     protection.
   - The update merges the base branch into the PR branch:
     `PUT /repos/{owner}/{repo}/pulls/{n}/update-branch` with
     `expected_head_sha`. The call is asynchronous (202). Nirux waits up to 5
     minutes for a new head committed by GitHub (`web-flow`), whose first
     parent is the previous head and whose second parent is a commit of the
     base branch (the base may have moved since the compare). Then it checks
     "behind" again. Any other new head, such as an agent's own merge, means
     someone pushed: the queue stops.
   - A 422 has several causes, so Nirux re-reads the PR. If the head moved, it
     stops. "There are no new commits on the base branch" means not behind: go
     on. CONFLICTING goes to section 3.3. Anything else stops with GitHub's
     message.
   - Never `gh pr update-branch --rebase`: it rewrites the branch on GitHub,
     which is a force push.
   - The local worktree is then one merge commit behind its remote, and the
     agent's next plain push is rejected until it pulls. The row says "local
     behind".
   - At most two updates per PR per Start. Then the queue stops.
3. **Wait for the required checks** on the current head:
   - When all are green, go to step 4. A required check still missing after the
     timeout (default 30 minutes) stops the queue, so a misspelled name can't
     pass.
   - **Flaky tests:** a failed required check is rerun once
     (`gh run rerun <run id> --repo <owner/name> --failed`), once per PR per
     Start. Right after a
     rerun the old failure still shows, so the queue waits for a new check run
     (a new id) before judging. A second failure stops the queue. The journal
     records the rerun.
   - A rerun keeps its run's original commit and merge ref. If the base moved
     since, step 4 notices.
4. **Merge.** Just before, re-read and check:
   - the PR is still open, with the same head and the same base branch (a
     retargeted PR keeps its head SHA);
   - every required check is green and no check is red on that head. Pending
     checks that aren't required don't block: CodeQL's Swift analysis takes
     about 18 minutes;
   - `mergeable` is MERGEABLE;
   - the branch isn't behind the current base tip. If it is, back to step 2;
   - no run of the post-merge workflow is unfinished on the base branch (any
     status but completed: queued, waiting, pending, requested, in progress),
     whatever its event: a manual dispatch shares the nightly's concurrency
     group. So the runs are listed without `--event`. If one is unfinished, the
     queue waits for it, up to the post-merge timeout. If that run fails, the
     queue stops; otherwise it runs all of step 4's checks again. This covers
     the first merge after Start, and merges made from outside the queue;
   - step 1's local checks, again: an agent may have gone back to work in the
     worktree while the checks ran. A busy agent is waited for (10 minutes at
     most); tracked changes or unpushed commits stop the queue (decided with
     the user on 2026-09-28).

   Then run `gh pr merge <n> --repo <owner/name> --<method>
   --match-head-commit <sha>` from a folder outside every worktree, so `gh`
   never touches a local checkout. Never `--admin`, `--auto` or
   `--delete-branch`: deleting branches is Clean Up's job, on its own click.

   Then re-read the PR. It must be MERGED. On a base that requires GitHub's
   merge queue, `gh pr merge` enables auto-merge or enqueues the PR instead,
   which would merge it later without waiting for the nightly. Start refuses
   such a base: a `merge_queue` rule in `rules/branches/{base}`, or a non-null
   GraphQL `repository.mergeQueue(branch:)`, which also covers classic branch
   protection. If it happens anyway, the queue stops and says how to disable
   auto-merge or dequeue the PR.

   The merge commit comes from `mergeCommit.oid`. Its first parent must be the
   base tip checked above. Otherwise the queue stops with "merged onto an
   untested base".
5. **Wait for the post-merge workflow**, when the project has one (Nirux:
   `nightly.yml`):
   - Find its run with `gh run list --repo <owner/name> --workflow <file>
     --branch <base> --event push --commit <merge sha>`.
   - Success: next PR.
   - Failure: stop. If the base tip moved after the merge, the queue reports
     that rather than blaming the PR: `nightly.yml` fails a run whose commit is
     no longer the tip of `main` ("Refuse to publish a stale commit").
   - Cancelled: see section 3.4.
   - No run within 5 minutes, or no result within the timeout (default 30
     minutes): stop.
   - The nightly updates the local Nirux too, but `SUAutomaticallyUpdate`
     installs on quit, so it doesn't interrupt the queue.

**Stop at the first problem.** Anything unexpected stops the queue and marks
the row with the reason. The queue only retries read calls (section 4), the
single rerun of a flaky check, `mergeable: UNKNOWN`, and the waits for a busy
agent or an unfinished post-merge run.

**Order.** By default, oldest PR first (ascending number). The user can reorder
the list in the confirmation sheet. Nirux never changes the order.

**No cap.** The queue goes through the whole confirmed list. A green nightly
only proves that `swift test` and the build passed, and each one ships to every
install, so the confirmation sheet shows how many nightlies the run will
publish.

**Duration.** On 2026-09-27, `test` took about 3 minutes and the nightly 4 to 6
minutes (once 13), so about 10 minutes per PR, plus an update and a test run
when the branch is behind.

### 3.3 Conflicts

A PR conflicts when its update returns 422 and a re-read says CONFLICTING, or
when preflight reads CONFLICTING. Nirux never resolves conflicts itself. The
queue stops, the row reads "conflict", and it offers **Ask Agent to Resolve**:

- On click, Nirux focuses the agent's column and types a prepared prompt
  without pressing Return. The user reads it and submits it, so a half-typed
  draft is never sent along with it.
- The prompt, with the configured base branch: "PR #52 conflicts with `main`.
  Run `git pull`, then `git merge origin/main`, resolve the conflicts, run the
  tests, commit and push. Don't rebase or force-push."
- It targets one column: the row's agent column when there is exactly one,
  otherwise the one the user picks from a menu. The button is enabled only if
  that column's foreground process is the agent and it is back at its prompt,
  the same rule as Resume. Otherwise it is disabled and says why.
- The next Start shows the PR's new head in the confirmation sheet, so the
  resolution is confirmed before it is merged.

Rejected:

- **Skipping the PR and going on with the next one.** It is faster, but the
  order the user confirmed would change without asking.
- **Asking the agent to rebase.** Rebasing a pushed branch needs a force push.

### 3.4 Concurrency

- **The post-merge workflow.** Nirux's nightly uses one concurrency group with
  `cancel-in-progress: true`. That is why the queue merges the next PR only once
  the nightly of the previous merge has finished. Step 4's check (no unfinished
  run) extends this to the first merge after Start, and to merges made from
  outside.
- **Merges from outside the queue** can't be prevented: the user on
  github.com, another session running `gh pr merge`.
  - Before a merge, the PR is behind again: back to step 2.
  - While the queue waits for its nightly, a newer run cancels it: the queue
    stops and reports what moved `main` (commit, PR). Rejected: following the
    newer run when its commit contains the queue's merge, and taking its result
    as the queue's.
  - A manual dispatch of the workflow on the same commit can cancel the push
    run without moving `main`. The queue stops with "cancelled by a manual run".
- **One queue per repository.** Another project's queue on the same
  repository refuses to start. Across Nirux processes (the installed app, an
  older release left beside it, a build with `NIRUX_MERGE_QUEUE_LIVE=1`):
  - a live queue holds an exclusive `flock` on one file per repository in a
    fixed folder, `~/Library/Application Support/nirux/locks/`, which doesn't
    follow `NIRUX_STATE_DIR`. The kernel releases it when the process dies, so
    a reused pid can't leave it stale;
  - a second live queue on that repository refuses to start;
  - a dry-run queue takes no lock, and tests inject their own folder.
- **Sleep.**
  - While a queue runs, Nirux holds the keep-awake assertion (#57). Its
    controller has a "queue running" input, under the same setting.
  - Nirux also opts out of App Nap
    (`ProcessInfo.beginActivity(.userInitiatedAllowingIdleSystemSleep)`), so
    its polls aren't throttled in the background. That option leaves idle sleep
    to the keep-awake setting.
  - Closing a laptop's lid still puts the Mac to sleep. Timeouts count
    `systemUptime`, which stops during sleep, and every wait re-reads GitHub
    after a wake.

### 3.5 Engine

The queue is a pure state machine: `(state, event) -> (state, [command])`.

- **PR states:** waiting, preflight, updating, waiting for checks (SHA),
  rerunning, merging, waiting for the post-merge run (merge SHA), done; or
  stopped (reason) at any step. Each entry keeps its confirmed head.
- **Queue states:** idle, confirming, running, paused (rate limit), stopping,
  stopped (reason), finished.
- **Commands:** read PR, read checks, compare, update branch, list runs, rerun,
  merge, wait. A driver runs them through a `GitHubClient` protocol: the real
  one spawns `gh` through `BoundedProcess` off the main thread, tests use a
  fake. The clock is injected.
- **Mutating calls are never resent.** After a mutation that failed or timed
  out (a merge call that times out may have merged), the engine re-reads. If
  the mutation took effect, it goes on; otherwise the queue stops. The one
  exception is `update-branch`'s 422, which step 2 classifies ("no new commits"
  goes on). A mutation refused by a rate limit stops the queue; only reads
  pause.
- **Dev builds can't merge.** A build gets a dry-run client unless it is the
  release, an app bundle signed with a Developer ID and notarized with the
  ticket stapled, as the nightly is, and runs on the real state (no
  `NIRUX_STATE_DIR`, which the installed app never sets), or
  `NIRUX_MERGE_QUEUE_LIVE=1` is set.
  - A bundle next to a `Package.swift` (`scripts/bundle.sh`'s, in a checkout)
    is a dry run whatever its signature: `docs/release-signing.md` describes
    notarizing one by hand. Builds from `swift build` or `bundle.sh` aren't
    notarized otherwise, even signed on a Mac that holds the Developer ID, so
    they stay dry runs wherever they are copied and however they are opened:
    LaunchServices passes no variable at all. A bare executable is never live.
  - Nirux checks its running code only when the rest doesn't decide, off the
    main thread as it launches (a queue opened before that ends checks it
    itself, in about a tenth of a second). A definitive answer is kept; a passing failure (a busy
    system service, a bundle replaced mid-check) is checked again for the next
    queue. The log, and a dry run's stop, say why a build is a dry run.
  - The nightly runs `scripts/check-release-signature.sh` on the app it
    publishes: a copy outside the checkout, without the dev variables, decides
    as it would at launch, and a release whose queue would stay a dry run
    doesn't ship. On failure it prints the app, the requirement, the Security
    status (telling a misused check from a build that isn't the release), the
    decision and each clause of the requirement, read from the app.
    `Nirux --check-release-signature <path>` checks another app's files, such
    as a downloaded nightly.
  - Nirux's terminals get an empty `NIRUX_MERGE_QUEUE_LIVE`, so a live Nirux
    never passes it on to the builds its agents run. Don't set it with
    `launchctl setenv`: every app LaunchServices opens would get it, agents'
    bundles included. A self-built install goes live by being notarized.
  - Decided with the user on 2026-09-28 and 2026-09-29; the design first made
    any app bundle live.
  - The dry-run client reads GitHub and journals the mutations it would make.
  - It writes its own `queue.dry-run.log` and `queue-state.dry-run.json`, so it
    never touches a live queue's files.
- **Restarts.** A queue never resumes by itself after a quit or a crash. Its
  state is saved in `<state dir>/projects/<id>/queue-state.json`. At the next
  launch the board shows "Interrupted while waiting for the nightly of #52",
  with the PRs re-read from GitHub. Start opens a new confirmation.

### 3.6 Owner

- A running queue belongs to an app-level `MergeQueueController`, one per
  project, owned by the shell. The board column only shows it.
- Closing the board, or the workspace that holds it, or cleaning up its
  worktree, doesn't stop the queue. Reopening the board shows it again.
- While a queue runs, the status bar shows it ("Queue: #52 waiting for the
  nightly, 3 of 7"). Clicking it opens or focuses the board.
- Quitting Nirux while a queue runs asks first. The queue stops before its next
  command.

### 3.7 Decided while building B2

B2 is the engine alone: nothing in the app starts a queue until B3's Start.
Choices the design left open, taken as the most conservative option and
documented in B2's pull request:

- **Requests.** The engine waits on at most one request. A read request is a
  batch of reads after a delay, so every poll and back-off is a request too.
  The driver sends a request before anyone hears of the step that made it, so a
  Stop from a listener never lands between a decision and its call. Stop drops
  a pending read at once; a mutation already sent is awaited, and the queue
  reads "stopping" meanwhile. A merge that answers then says to check the PR on
  GitHub.
- **The confirmation is B3's.** The engine has no "confirming" state: it starts
  from a confirmed list, with the settings the sheet showed. `start` checks
  those settings again with `BoardConfig.problems`: no required check would
  make every head green.
- **Checks by commit through GraphQL**, not REST: REST check runs don't name
  their workflow, which `Workflow / job` needs, nor the run to rerun. Each read
  costs 1 point, so a PR waiting for its checks costs about 360 points an hour
  (PR and checks every 20 s). A missing field, or a second page of check suites
  or runs, fails closed.
  - Only the latest run per workflow (by id, since two workflow files may share
    a name) and job counts.
  - A required name needs a check run: a commit status of that name can make
    it red or pending, never green alone.
  - A required check that ends NEUTRAL or SKIPPED stops at once: without a new
    run it can't turn green. A pending required check says whether it is
    queued: at the timeout, the queue suggests a misspelled name only for a
    check that never started.
- **The one rerun** happens only when every failed required check belongs to
  one workflow run, and once all that run's jobs are finished (GitHub reruns a
  finished run only). Other failures stop. The runs it replaces (its failed
  jobs, required or not, and the required jobs it skipped, such as one that
  needs the failed job) read as pending until their new runs show, and the
  checks timeout starts again at the rerun. If `gh run rerun` fails, the checks
  are read once: new runs mean it went through.
- **A branch update that GitHub refuses without a 422** re-reads the PR once:
  an unchanged head stops the queue. One with no clear answer (a timeout) is
  watched like an accepted one, for 5 minutes, since GitHub applies it later. A
  new head must pass the update's checks (committed by `web-flow`, per REST
  `commits/{sha}`, since GraphQL shows no user for GitHub's commits). A rerun
  with no clear answer gets 20 s before its checks are read.
- **After `gh pr merge`**, whatever it answered, the PR is read again. A
  refusal stops at once; otherwise the PR is read every 5 s for a minute until
  it is MERGED. A PR merged at another head than the confirmed one stops the
  queue: it was merged outside it. The journal records what the queue saw at
  each merge: the required checks with their runs, the checks still running,
  the base tip.
- **Post-merge runs on the base.** The queue looks at the workflow's last 50
  runs on the base branch. Before each merge, a run that failed (failure, timed
  out, startup failure, action required) stops the queue unless that attempt
  had already failed at Start: a run still going at Start, or rerun since,
  counts. One that had failed before Start is the sheet's warning (section 4),
  not a stop, so a PR fixing the nightly can merge; a run the queue waited for
  stops it whatever. A cancelled or skipped run doesn't stop it. While it waits
  for an unfinished run, the queue polls the base's runs only, then runs all of
  step 4's checks again.
- **Whether the base moved after a merge**: `compare/{merge commit}...{base}`
  ahead or behind. The newer run on the base names the commit that moved it.
- **Local checks**: the branch's worktrees in the project's local repositories
  (a remote naming the configured repository, whatever the host). Tracked
  changes first; then a local HEAD other than the PR's head is compared on
  GitHub. A project folder in a checkout git can't list, or refuses, fails
  closed, before any wait for an agent. Busy
  agents are the agent columns of the workspaces in the worktree (not in a
  worktree nested inside it) and of other workspaces whose shell is inside it,
  working or waiting on a dialog, as the Agent column reads them.
- **Pauses and retries.** A primary rate limit reads `rate_limit` for the reset
  of the exhausted pool (plus 5 s; a minute when it can't tell). A secondary one
  waits 60 s, doubled each time, up to 16 minutes. A pause doesn't count toward
  any timeout. Other failed reads, server errors included, retry after 5, 10,
  20, 40 then 60 s, for 5 minutes from the first failure. `gh auth status`
  checks the active account only; one that can't reach GitHub is retried too.
- **A dry run stops at its first mutation** ("Dry run: … stopped before
  running: gh pr merge …"): nothing changed on GitHub, so it can't go further.
- **Files.** The journal's previous file is `queue.log.1`. Tokens an error
  could echo (`ghp_…`, `gho_…`, `github_pat_…`) are masked, in the journal and
  in the saved queue. A queue saved as running reads as interrupted at the next
  launch, unless another Nirux holds the repository's lock: it still runs there.
  That Nirux writes its last state before letting go, and the lock is held
  while the file is read again and marked interrupted. The state is written
  only when it changed. A queue interrupted, or stopped by failing reads, says
  when a merge or branch update was sent and GitHub didn't show its effect
  yet.
- **For B3**, `MergeQueueController` (one per project, from
  `NiruxShellView.mergeQueue(projectID:)`) offers `start(settings:entries:)`,
  which returns why it refuses, `stop()`, the engine with its entries and
  `statusText`, the saved queue and `reloadSaved()`, `isRunning`, `isDryRun`,
  `runsElsewhere` and `onChange`. `onChange` is a single closure: B3 fans it
  out to the board, the status bar and the quit confirmation.

### 3.8 Decided while building B3

Choices the design left open: those marked were decided with the user on
2026-09-29, the others are the most conservative option, documented in B3a's
pull request.

- **Two pull requests** (with the user): B3a starts, follows and stops the
  queue (Add to Queue, the Queue column, Start and Stop, the confirmation
  sheet, the status bar, the quit confirmation, keep-awake); B3b adds the
  journal view and Ask Agent to Resolve.
- **The list.** "Add to Queue" sits in the Queue column, not in Actions, whose
  last buttons hide on a narrow board. It adds to the next Start's list, by
  number, oldest first, until the user reorders one in a sheet; later additions
  go at its end, and an emptied list starts over by number. The list belongs
  to the project's `MergeQueueController`, in memory: closing the board keeps
  it, and a relaunch proposes what the saved queue didn't merge, in its order.
  It is the list of one repository: once board.json names another, it is
  empty, and the board no longer marks rows with the last queue's steps. A row
  the queue would stop on at once (a draft, another base, a conflict, a busy
  agent) says why instead; the sheet checks the rest. The list doesn't change
  while a queue runs, here or in another Nirux, nor while the sheet is open or
  Nirux is quitting. A Start makes it the confirmed list: what the sheet left
  out leaves it, and each pull request leaves it once merged. A pull request
  the sheet reads merged or closed leaves it at once: it may have no row left
  to remove it from.
- **What the sheet reads**, off the main thread, four pull requests at a time:
  `gh auth status`, `rate_limit`, whether the base needs GitHub's merge queue,
  the post-merge runs on the base; then each pull request's snapshot, its title
  and first 100 files (GraphQL, which gives a renamed file's new path only),
  the checks of its head, its comparison with the base and its worktrees.
  Nothing is guessed: a pull request that couldn't be read, a head GitHub can't
  compare, a worktree that can't be checked is left out; checks, files or a
  comparison that couldn't be read are shown as unknown.
- **Order** (with the user): ↑ and ↓ on each pull request, no drag and drop.
- **Start** in the sheet doesn't answer Return. It reads board.json again and
  refuses settings changed since the sheet read GitHub. Every Start opens a new
  sheet; one sheet at a time. A quit that was asked refuses it, and closes the
  sheet once confirmed.
- **The local checks keep the project's folders at Start**, plus those opened
  since: a workspace closed or moved mid-queue doesn't turn them off. A space
  whose queue runs can't be deleted: stop it first. The board keeps its queue
  line, and Stop, while a queue runs, even when board.json can't be read.
- **Warnings and refusals.** Besides section 4's: a post-merge run going on the
  base (the first merge waits for it), a red check that isn't required (the
  queue never merges with one), a required check that ended skipped or neutral,
  more than 100 changed files. "The last post-merge run" is the last completed
  one. Nothing that can join refuses Start too.
- **Nightlies**: one per merge. A dry run says how many a real queue would
  publish, and that it publishes none. Another post-merge workflow is said to
  run once per merge, not to publish.
- **Status bar** (with the user): the queue comes first, with Stop, then the
  crash or update notice. Once the queue ends, "Queue stopped: …" or "Queue
  finished: …" stays until its ✕, so a stop overnight is seen. A click shows
  the board, opening one in the project's first workspace if there is none.
  With several queues, the first in sidebar order shows, with "+1 other
  queue", and its Stop becomes Stop All. Only the queues of this launch show
  there; an interrupted one shows on its board. A dry run reaching its first
  mutation isn't shown as a failure.
- **Quitting** (with the user): Nirux comes to the front and asks, in a sheet
  on the window, or an alert when the window isn't on screen, with Keep
  Running first; a dry run is said to be one. "Stop Queue and Quit" stops
  every queue and waits for a call already sent to answer, 2.5 minutes at most,
  so the journal records it. The main window's close button quits Nirux, so it
  asks the same question. The queue's files are written before Nirux exits.
- **Keep-awake**: `KeepAwakeController.update(mergeQueueRunning:)`, under the
  same setting and grace period as agents; the indicator's tooltip says why.
- **A dry run shows everywhere**: a DRY RUN badge on the board's queue line,
  "Start Dry Run…", the sheet's orange title and banner, "Queue (dry run)" in
  the status bar, and a journal line that says the mutation wasn't sent.

## 4. Guardrails

- **Nothing without a click.** The board only reads. The queue runs after Start
  and a confirmation. Resume, Clean Up and Ask Agent to Resolve are each one
  click on one row, and the last one doesn't even submit.
- **The confirmation sheet** lists, in order, each PR with its head SHA and
  checks, and what will happen:
  - update if behind;
  - the required checks, the post-merge workflow, the merge method;
  - one rerun per flaky check;
  - how many nightlies the run will publish;
  - the queue stops at the first problem.

  PRs that can't join are listed apart, with the reason, and left out: draft,
  fork, conflict, agent working or waiting on a dialog, unpushed commits or
  tracked changes in its worktree. A PR that changes `.github/workflows/` can
  join, with a warning: its checks ran its own version of the workflows.
- **No post-merge workflow by accident.** The queue refuses to start until the
  config names one, or says `"none"`.
- **A failed last post-merge run** on the base branch shows as a warning at the
  top of the sheet: the base may already be broken.
- **Start refuses a base with GitHub's merge queue** (section 3.2, step 4).
- **Stop** is always visible while the queue runs: in the board and from the
  status bar. It stops before the next command. A `gh` call already sent
  finishes, since a merge can't be undone, and the journal says what ran.
- **Never:**
  - force-push, or update a branch by rebase;
  - `--admin`, `--auto` or `--delete-branch`;
  - merge with a required check red or missing, or any check red;
  - merge a draft, a PR from a fork, or a head the user didn't confirm.
- **Every merge and branch update is pinned to the SHA it was decided on**
  (`expected_head_sha`, `--match-head-commit`). A push between the check and the
  merge makes GitHub refuse the merge, and the queue stops.
- **Journal.** One JSON line per action in
  `<state dir>/projects/<id>/queue.log`: time, PR, step, command, result. It
  never holds tokens. The board shows it, copyable for an agent. It is capped at
  1 MB, keeping one previous file.
- **`gh` limits.** REST allows 5,000 requests an hour and GraphQL 5,000 points,
  shared with the user's own `gh` and every agent.
  - While waiting, the queue reads the current PR every 20 s (GraphQL, about
    1 point), its checks by commit every 20 s (1 or 2 REST requests) and the
    current run every 30 s (REST). That is about 200 points and 500 requests an
    hour, plus the board's reads (section 6).
  - Before Start, Nirux reads `gh api rate_limit`, which costs nothing, and
    refuses below 500 remaining in either pool.
  - When the primary limit is hit, the queue pauses until the reset time
    `rate_limit` gives. `gh`'s high-level commands don't expose `retry-after`.
  - A secondary limit (too many requests too fast) doesn't show in
    `rate_limit`: the queue waits at least 60 s, with exponential back-off.
  - The board shows the pause, and Stop still works.
- **Transient errors.** Read calls retry with back-off for up to 5 minutes,
  then stop. Mutating calls are never resent (section 3.5).
- **`gh` missing or signed out:** the queue refuses to start and says so
  (`gh auth status`).

## 5. Config per project

One file per project, `<state dir>/projects/<id>/board.json`, next to the brief
and the journal:

```json
{
  "schemaVersion": 1,
  "repository": "xikimay/nirux",
  "baseBranch": "main",
  "requiredChecks": ["test"],
  "postMergeWorkflow": "nightly.yml",
  "mergeMethod": "merge",
  "checksTimeoutMinutes": 30,
  "postMergeTimeoutMinutes": 30
}
```

| Key | Default | Notes |
| --- | --- | --- |
| `repository` | The push remote of the project's workspaces, when they share one | Asked for otherwise |
| `baseBranch` | The repository's default branch, as the local checkout knows it | Asked for otherwise |
| `requiredChecks` | `["test"]` | Check run names, or `Workflow / job`. A name missing on the PR fails closed |
| `postMergeWorkflow` | None: must be set | A workflow file, or `"none"` to merge the next PR right after a merge |
| `mergeMethod` | `merge` | `merge` or `squash`, among the methods the repository allows. Not `rebase`: its last commit's first parent isn't the base tip, so step 4's check can't hold |
| timeouts | 30 min | `checksTimeoutMinutes`, `postMergeTimeoutMinutes`: 1 to 240 |

- **Why not `projects.json`:** `ProjectStore` treats a file with unknown keys as
  read-only. A `board` key there would stop an older nightly from deleting
  spaces after a rollback. A separate file leaves `projects.json`, and
  rollbacks, as they are.
- The file follows `ProjectStore`'s rules (`BoardConfigStore`):
  - lenient decoding: a missing key gets its default, and invalid values are
    kept as read, so a rewrite loses nothing;
  - a file this build can't write back as it found it is read but never
    written: a newer `schemaVersion`, keys it doesn't know, or a merge method
    other than `merge` and `squash` (`rebase` included). The merge queue
    refuses to start with such a file, since the settings it doesn't know
    would be ignored (decided with the user on 2026-09-27). Rebase, for
    instance, is shown as it is, read-only, and never runs as `merge`;
  - an unreadable file is copied aside (`board.corrupt.<time>-<random>.json`)
    when Save replaces it, not when it is read, so opening the form doesn't
    pile up copies. If the copy fails, the file stays as it is;
  - anything but a regular file (a folder, a link) or a file over 1 MB is
    neither read nor replaced;
  - Save refuses values `BoardConfig.problems` rejects, and a file another
    Nirux saved since the form read it;
  - writes are atomic, and the file is 0600. Deleting the space leaves it, like
    the brief.
- **The queue starts only** when the file is writable and complete: a
  repository, a base branch, at least one required check, timeouts in range,
  and a post-merge workflow chosen, a file or `"none"`. B2 and B3 read
  `BoardConfigStore(spaceID:).load().queueSettings`, which is nil otherwise
  (`queueStartProblems` says why). Every value in it is set; a nil
  `postMergeWorkflow` there means None.
  - GitHub ignores case in `owner/name`: compare
    `QueueSettings.gitHubRepository`, for "one queue per repository" and a
    PR's head repository.
  - `gh --repo owner/name` follows `GH_HOST`, which a terminal may set: pass
    `github.com/owner/name`.
  - A base branch may hold `#` or `%`: percent-encode it in REST paths.
- `BoardConfigStore.didSaveNotification` announces each save, with the
  space's id, for the board to reload.
- **Editing:** "Board Settings…" in the space's menu (B4), a small form in a
  sheet. B1 adds it to the board header, and opens it the first time a board
  lacks a repository.
  - Fields show the saved values, else values read from the local checkouts,
    never from the network: the repository every workspace in a repository
    pushes to (github.com only, spelled as its remote spells it), and the
    branch its remote's `HEAD` points to, if that branch is there. A pasted
    github.com URL is saved as `owner/name`. Nothing is written before Save.
  - The post-merge workflow is never preselected. The form lists the
    `.github/workflows/*.yml|yaml` files of the base branch as that
    repository's main checkout last fetched it (else of the checkout's own
    files), None, and Other file… for a name typed by hand.
  - Required checks go one per line: matrix job names hold commas.
  - A read-only file is shown as it is, without suggestions, and Save is
    disabled.

## 6. Data

What exists:

- `PRDetect` runs one `gh pr list --head <branch>` per workspace (a second one,
  with `--state all`, when none is open). It accepts a PR whose head repository
  is the branch's push remote, a fork included.
- #31 made git and PR refreshes event-driven. PR refreshes run every 30 s
  (checks pending) or 2 min for the focused workspace, 2 or 10 min in the
  background, and never for inactive workspaces.
- `WorktreeCleanup.worktreeListing` reads `git worktree list --porcelain -z`.
  `GitWorktree.list` keeps bare entries, so the board extends the former with
  branch, HEAD, bare and prunable.
- Agent state is in process (`AgentStatusMachine`, hooks).

What the board adds:

- **One batched call per repository:** `gh pr list --repo <owner/name>
  --state open --limit 100 --json number,state,headRefName,headRefOid,
  headRepositoryOwner,headRepository,baseRefName,isDraft,mergeable,
  statusCheckRollup,url`. It costs about 2 GraphQL points (measured with
  `rateLimit(dryRun: true)` on 2026-09-27). Recently merged PRs
  (`--state merged --limit 30`) are read every 10 minutes, for the "merged,
  clean up" rows.
- **Cadence:** every 60 s while the board is on screen, 30 s while a row has
  pending checks, nothing while it is hidden. The sidebar's `PRDetect` keeps
  running as today. Refresh reads now.
- **The last post-merge run:** `gh run list --repo <owner/name>
  --workflow <file> --branch <base> --event push --limit 1` (REST), every 5
  minutes on screen, and at each queue step.
- **Worktrees:** `git worktree list` when the board opens, on Refresh, and every
  60 s on screen. It is local and cheap. It runs again at the next refresh when
  a project workspace opens in a folder not listed yet, or a listed worktree's
  folder is gone (cleaned up).
- **Cache:** in memory, in the board, for its repository, dropped when the
  board closes or changes project or repository. A
  running queue makes its own reads.
- Later: feed `PRDetect` from the batch, so the sidebar and the board make one
  call. That changes #31's code paths, so it waits.

## 7. Tests

- **The engine is pure.** Table tests cover every transition:
  - the happy path, with and without an update;
  - a head that changed since confirmation, and a head moved by the queue's own
    update;
  - `mergeable: UNKNOWN` then MERGEABLE, and then CONFLICTING;
  - each 422 cause of `update-branch`, and a new head that isn't the update
    (another committer, or unexpected parents);
  - a PR already set to auto-merge or in GitHub's merge queue;
  - a stale green check on the old head, a flaky check rerun once (waiting for
    the new run id, which replaces the failure), then a second failure;
  - a head or base change at merge, a merge that timed out but happened,
    auto-merge enabled instead of a merge, a merge commit on an untested base;
  - the post-merge run: success, failure, failure after `main` moved,
    cancelled by a push, cancelled by a dispatch, not found, timeout;
  - a busy agent that goes idle in time, and one that doesn't; an open dialog in
    a focused column;
  - an unfinished post-merge run before a merge, a base with GitHub's merge
    queue, a lock held by another process;
  - Stop in every state, a rate-limit pause, a restart.
- **A fake `GitHubClient`** returns scripted answers and records calls. A
  test fails if any recorded call is forbidden: `--admin`, `--auto`,
  `--delete-branch`, `--rebase`, or a merge or branch update without its SHA.
  Another checks that dev builds get the dry-run client.
- **Parsers** are tested on fixtures of real `gh` output, anonymized: `pr list`,
  check runs, `run list`, `compare`, `update-branch` errors.
- **No network and no `gh` in tests.** GitHub runners have `gh` installed, so
  the client is injected into `NiruxShellView`, and tests never build the real
  one. No fixed sleeps: the clock is injected. The journal and the queue state
  go to a temporary `NIRUX_STATE_DIR`.
- **A flow test drives the real driver** with a fake client that answers on a
  background queue, like `WorktreeCleanupPanelFlowTests`. The #48 crash came
  from exactly that path: a closure written in `@MainActor` code called back off
  the main thread, which CI's Swift 6.1 traps.
- **UI:** the board column, the confirmation sheet and Stop open in a window
  like the other panel tests, with `@MainActor`, clicks through `hitTest` and
  `mouseDown`, and `isReleasedWhenClosed = false`. Today's confirmations use
  `NSAlert.runModal`, so the sheet gets a path tests can drive without a modal
  loop.

## 8. Plan

In delivery order:

| Order | PR | Depends on | Content |
| --- | --- | --- | --- |
| 1 | B4: config | #45 | `board.json` model and storage, Board Settings form |
| 2 | B1: read-only board | B4 | Column type, rows, batched PR fetch, last post-merge run, Focus, Open, Clean Up by path, Resume (once stuck-agent detection lands) |
| 3 | B2: queue engine | B4, B1's data types | State machine, `GitHubClient` (real and dry-run), driver, `MergeQueueController`, journal. No UI |
| 4 | Nightly retention (CI) | none | Keep the dated nightlies of the last 7 days, and at least 20. Shipped |
| 5 | B3a: queue UI | B2, retention | Add to Queue, confirmation sheet, Start and Stop, status bar item, quit confirmation, keep-awake input |
| 6 | B3b: journal and conflicts | B3a | Journal view, Ask Agent to Resolve |

- **Config first:** B1 needs the repository, the required checks and the
  post-merge workflow, and the queue must never run with a guessed workflow.
- **Retention before B3:** `nightly.yml` kept only the last 20 dated releases.
  On 2026-09-27 it published 34, so a busy day left about 12 hours to roll
  back, and a queue publishes several nightlies in a row. It now keeps a week.
- B2 can start in parallel with B1 if it defines its own PR type.
- B3's keep-awake input needed `feat/keep-awake` (#57), which shipped first.
- **Session history** (Projects, section 6: ledger and resume) becomes a
  "Recent sessions" section of the board, after B3.
- **Later:** launching a worktree workspace with a handover from the board. The
  worktree skill does it today from an agent.
- Projects' plan rows 8 (Project view) and 9 (Finish) are replaced by this plan
  and #46.

## Sources

Checked on 2026-09-27 with `gh` 2.100.0.

- [GitHub REST: update a pull request branch][update-branch]
- [GitHub Actions: re-running workflows and jobs][rerun]
- [GitHub REST: rate limits][rate-limits]
- `gh pr merge --help` (`--match-head-commit`, auto-merge on merge-queue
  bases), `gh run list --help` (`--commit`, `--event`), `gh run rerun --help`
  (`--failed`)
- `gh api repos/xikimay/nirux` (auto-merge off, merge commits allowed) and
  `gh api repos/xikimay/nirux/branches/main/protection` (not protected)
- `.github/workflows/nightly.yml` (concurrency, stale-commit guard,
  `KEEP_DATED_RELEASES`) and `.github/workflows/tests.yml`

[update-branch]: https://docs.github.com/en/rest/pulls/pulls#update-a-pull-request-branch
[rerun]: https://docs.github.com/en/actions/managing-workflow-runs-and-deployments/managing-workflow-runs/re-running-workflows-and-jobs
[rate-limits]: https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api
