# Daily pass

> **Design record:** approved by the Lead on 2026-11-19. PR 1 ships `record_review` and `daily_pass`; PR 2 adds the daily schedule, the Space Settings switch and the Lead row's note.

Once a day, each space with a Lead looks back at what happened and proposes the rules that would have prevented the friction, through the learned-rules flow (`propose_rule`, the Lead row's "Rule proposed", the user's Add or Dismiss). Nothing reaches the brief without the user.

## Who runs it: the Lead, with facts Nirux gathers

Nirux types one line into the Lead's prompt. The Lead calls `daily_pass`, which returns the facts below and what to do with them, then proposes rules with `propose_rule`.

Why the Lead rather than a headless `claude -p` run:
- **Context:** it holds what Nirux can't see. That is the reviews it sent, the user's corrections (the user talks to the Lead) and what it already told tasks.
- **Guards:** `propose_rule` refuses what the brief already says, what waits and what the user decided in the last 90 days, and the Lead hears each decision.
- **Discussion:** the user can ask it "why this rule?" in its terminal.
- **No new model path:** no billing or account checks, and no first-use notice.

The facts come from Nirux, not from the Lead's memory, which idle compaction trims ("state lives in Nirux", spaces.md).

## `record_review(task, findings)`

- **One call per review**, holding all its findings. Each finding is `{kind, text}`:
  - `kind` is a short class name the Lead reuses across tasks, e.g. `test-waits-on-sleep`, slugged to lowercase letters, digits and dashes (40 characters at most);
  - `text` is one line of 300 characters at most;
  - 20 findings at most per review.
- **Which tasks:** any task of the space, the user's included (#613's reach). A workspace that isn't a task is refused, as `set_task_context` refuses it.
- **Rounds:** each record is the next round of its task. A task is its workspace plus its branch, so it stays one task when its pull request opens, and a checkout moved to another branch is another task. While HEAD is detached (a rebase) or not read yet, it keeps its last review's name, else its Mission's branch. A kind names each task by its latest handle (its pull request once it has one). Each record keeps the repository folder it was made in (the deepest anchor when anchors nest), so its rounds count for that repository's pull requests only; records from before that count for any.
- **Answer when nothing is written:** the log is full, or it can't be written.
- **The answer** lists the space's other kinds, so the Lead reuses them. When a kind now shows up in a second task, it says so: that is `propose_rule`'s trigger, made visible at once.
- **Stored** in `<state dir>/projects/<space id>/review-findings.jsonl` (0600, kept 30 days, 2 MB at most). It shares its file handling with `loop.jsonl` (SpaceLog) and is deleted with the space.
- **The Lead's role** gains "Record each review you send with record_review". To stay under Claude Code's 2,048-character cap, "After a /clear, list_tasks shows where things stand." went: list_tasks' own description says it.

## `daily_pass()`

What happened since the last pass, at most 40,000 characters (Claude Code saves a longer MCP result to a file). The rules come right after the instructions, because a cut takes the end:

1. **Review findings by kind:** each kind seen in the window, with where it showed up in the last 30 days (`#594 round 1`, `#611 round 3`). The kinds seen in the most tasks come first.
2. **Pull requests merged** in the window, in each GitHub repository of the space (from each repository's base remote). The repositories are read at once. One `gh pr list --state merged --limit 40` per repository gives:
   - the number, title and branch;
   - the review rounds: the highest review round its commit headlines name ("review round 2", "the Lead's round 1", "round 2 review", "round 1 of …", "the Lead's review of #586, round 1"; at most 10; never "round 60 seconds"), or the rounds recorded for its branch in that repository if higher;
   - the Why section on one line;
   - the round commits' headlines.
3. **CI:**
   - the runs Nirux triaged in the window (`ci-triage.json`, #323), with their verdict, reason, failing tests and pull request (a new field of RunRecord);
   - the tests learned flaky;
   - reruns, meaning runs whose latest attempt (past the first) started in the window, from one `gh run list` per repository.

   Past 40 pull requests, gh's query (each commit's authors) passes GitHub's 500,000-node limit: it reads the 40 most recently updated, and the digest says when it reached them.
4. **Mission messages** of the Lead's Missions and of the space's workspaces:
   - **held:** typed an hour or more after they were sent, or still waiting;
   - **given up;**
   - **crossed:** a tell typed after the task's result, or an answer typed after a newer question;
   - **held answers:** a question to the Lead answered an hour or more late, never typed (Nirux types one for an hour only; another parent may have read it with `receive`);
   - **the user's answers:** questions handed to the user (with the reason and the answer, the user's or the Lead's), dated by their answer, else by when they were handed over (`handedToUserAt`, new in the ledger); and questions the user answered in Nirux without being asked.

   Mission messages belong to the space through its workspaces, and those its session history names (closed since), unless they are open in another space now. Lines that look like a secret are withheld, as `read_task` withholds them.
5. **Rules:**
   - the rules decided since the last pass;
   - the rules waiting;
   - the brief's "Rules learned" as sessions read them now (the Lead's copy dates from its start);
   - the rules dismissed in the last 90 days.
6. **What GitHub didn't say**, shown even on a day with nothing else. It isn't news on its own: a signed-out gh would make every day one. Errors are read as the merge queue reads them: no answer (no network, a timeout, a 5xx, what gh never said) and rate limits leave the window to read again, and so does a repository whose remote git or ssh couldn't read; anything GitHub or gh said (signed out, refused) holds until someone acts. Three reads in a row that may be read again at most: the third marks the window read all the same.

   The store compares wording; the Lead compares meaning.

- **Instructions:** the text opens with what to propose. That is at most the free pending slots (3 minus those waiting), the strongest first, citing the facts' handles. A Nirux bug or a flaky test is a task to start, not a rule. When nothing happened, it says so.
- **Read up to the first fact left out, and always later:** each section lists at most 30 facts, fewer (15, 8, 4) while the digest passes 40,000 characters, cut in time order (a kind by when the window first saw it; its older sightings are context). The tests learned flaky all show, on one line. Sections still too long at the smallest lists go whole. The window is marked read up to the first fact left out, never at its own start (a window that can't move shows the same facts every day); the digest says so, and the next call reads the rest. `isDue` goes by when the last read was, not up to where.
- **Window:** a call reads from where the last one ended (the last day for the first, a week at most). A call within 2 h of the last reads the same window again, longer, without saving it, so the Lead asking again after a compaction or a timeout sees the same facts; only after a read that showed all (not after one cut short, a quiet check, or a typed line). The window is kept in `daily-pass.json` beside the brief (0600, deleted with the space). A call that outlives its wait tells the Lead to call again in a minute.

## When (PR 2)

- **Due:** once a day, at the first quiet moment after the space's hour (default 06:00, local time). A pass that read, a line typed, or a check that found nothing after the hour all count for the day, and none comes within 12 h of the last (an hour moved later, or a pass asked for just before it). A minute's timer on the app's shell checks.
- **Quiet means all of these:**
  - the Lead's prompt is free (the Mission typing gate), and its last turn didn't end on a question for the user (typing would clear it);
  - its last hook event was 30 min ago or more;
  - nothing waits to be typed into it: a Mission message, a Lead notice, a rule decision;
  - the user has been away from Nirux for 10 min or more, counted from the Mac's last wake at the earliest.

  A resumed Lead takes no typed line until it took a prompt (#483); the resumed-delivery work lifts that.
- **Only if something happened.** Nirux reads the facts from the last read (GitHub included), then asks again whether the pass is on, due and quiet before typing "[Nirux Mission] Daily pass: call daily_pass…". The pass is recorded before the line is typed; one that can't be recorded isn't typed, and checks wait 15 min. A day with nothing marks its window read. A gh that didn't answer (no network after a wake, a timeout, a 5xx) waits 15 min and tries again. If the Lead never calls `daily_pass`, the next pass covers both days; the Lead's call after a typed line is a new pass, not a second read.
- **Settings:** Space Settings › Lead gets a "Daily pass" switch (on by default, the user's call), an hour menu and a "Last pass" line. They are kept in `defaults.json` (`leadDailyPass`, `leadDailyPassHour`); a file Nirux can't read turns the pass off.
- **The note:** after each `daily_pass` call, the Lead row shows a grey line for 24 h, "Daily pass · 6 PRs, 1 flaky test, 2 rules proposed". It counts the pull requests merged, the flaky tests (learned or called so), the messages held or given up, and the rules proposed within an hour of the call, its pass's turn (a second read keeps the first read's time). The Lead's reply in its terminal says why.

## Cost

- **Model:** the Lead's own (Opus 5.5 today), on the user's subscription.
- **Per run:** 3–8k tokens of facts, plus the Lead's compacted context (30–60k tokens) written to the cache once and read by about 5 requests, plus 3–5k tokens of output.
- **API-equivalent:** about $0.45–0.60 per run, up to about $1.50 for a 150k-token context. A day with nothing to read costs nothing.

## Forgotten tasks

The digest also lists the tasks the Lead forgot. It only reports: it never
closes or tells anything.

**Which tasks.** list_tasks' tasks: the space's open workspaces, without the
Lead, archived or closing ones.

**Activity.** A task's last activity is the latest of these three. Each
comes from a source Nirux already has:
- a turn: `WorkspaceState.lastActivityAt`, the time of its last agent hook
  event. It is saved with the workspace, and it is the age the sidebar row
  shows;
- a commit: the committer date of the task folder's HEAD (`git log -1
  --format=%ct`). It is read off the main thread beside the pass's GitHub
  reads, as a read-only git call. A failed read counts as no commit;
- a push: the newest `startedAt` among the checks of its pull request
  (`PRInfo.checks`, the sidebar's state). A push starts them.

**Kinds**, checked in this order:
- **closable**: the pull request is MERGED or CLOSED (`PRInfo.state`), or the
  work is finished. Finished means the newest event of the task's own Mission
  (not the Lead's one-way Missions) is its `completed` result, with no
  question or tell after it. `Mission.status` is not used: a held tell typed
  after the result turns it back to active. A finished task also needs no
  open pull request and a day without activity since the result. A merged or
  closed pull request needs no delay;
- **waiting**: an open pull request that is green (ciStatus SUCCESS) and
  MERGEABLE, not a draft, and on its repository's base branch as the Board
  reads it (a stacked one waits for its parent), with a day without
  activity;
- **quiet**: three days without activity, with an open pull request that
  isn't waiting, or with no pull request.

**Thresholds.** `DailyPass.unattendedAfter` = 1 day (waiting, finished).
`DailyPass.quietAfter` = 3 days.

**Moves.**
- closable: close_task;
- waiting: ask the user to merge it (merging stays the user's call);
- quiet, when its agent waits on the user: ask the user;
- quiet, when the task isn't the Lead's: ask the user;
- quiet, when the task is the Lead's: tell it what comes next, or close_task
  if it was dropped.

**News.** A task counts as news once, in the window where it became
forgotten: last activity + 1 or 3 days. A merged pull request is already news
in the window GitHub lists it in. A task reported once is not news again, so
a forgotten task that stays forgotten doesn't bring a daily line every day.
Every digest still lists all forgotten tasks, the "Nothing happened" one too.
The section is a snapshot of now, not a fact of the window. It stays outside
the cut and `readUntil`, and it lists `maxItems` tasks at most.

**Wording** (after the rules sections):

    ## Tasks you may have forgotten
    Nirux only lists them: nothing was closed or told. Make each move, or tell the user why not.
    - “Glass sidebar” · branch feat/glass-sidebar · PR #600 merged · last activity 11-18 22:40 (a turn) → close_task
    - “Slider test” · result sent 11-19 09:12, nothing since, no pull request · last activity 11-19 09:15 (a turn) → close_task
    - “Depth P5” · PR #640 green and mergeable, unmerged · last activity 11-19 10:20 (a push), 1 d 20 h ago → ask the user to merge it
    - “Haiku H6” · PR #602 open, checks failing · quiet: last activity 11-17 18:02 (a commit), 3 d 12 h ago → tell it what comes next, or close_task if it was dropped
    - “Stale rows” · not yours (started by the user) · no pull request · quiet: last activity 11-16 08:40 (a turn), 4 d 21 h ago → ask the user

**Lead instructions.** They don't change (2,030/2,048). The `daily_pass`
description gains "the tasks you may have forgotten".

**Lane 2.** It changes when the daily line is typed into the Lead's terminal,
and it adds git reads to the pass.

**Tests.** Each fails when its behaviour is reverted:
- DailyPassTests, on pure functions:
  - merged or closed is closable;
  - a finished task (result, then nothing) is closable after a day, and a
    tell or question after the result undoes it;
  - each source (turn, commit, push) alone keeps a task off the list, and the
    line names the latest one;
  - waiting needs green, MERGEABLE, not a draft and the base branch; else
    the task is quiet after 3 days;
  - the moves follow ownership and a wait on the user;
  - a task is news in the window where it crossed, and listed without news
    after;
  - the quiet digest lists the section;
  - the section leaves `readUntil` alone.
- LeadToolsFlowTests (an existing class, so no flake gate): `daily_pass`
  lists a task whose PR merged, with close_task, and leaves out the Lead and
  archived tasks.
- Runs NiruxMCPServerTests and LeadChannelTests.

## Later

- **Tasks recording their own reviews.** Their adversarial reviews, `/code-review` and premortems find most defects. Today only their round commits reach the digest.

## The 3-pending limit: kept

- Each added rule costs every later session part of the brief's budget, and an unreviewed pile is noise.
- A held-back candidate isn't lost: its findings stay 30 days and the next pass finds it again.
