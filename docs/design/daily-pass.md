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
- **Rounds:** each record is the next round of its task. A task is known by its workspace and branch, so it stays one task when its pull request opens, and a second branch in the same worktree is another task. A kind names each task by its latest handle (its pull request once it has one).
- **Answer when nothing is written:** the log is full, or it can't be written.
- **The answer** lists the space's other kinds, so the Lead reuses them. When a kind now shows up in a second task, it says so: that is `propose_rule`'s trigger, made visible at once.
- **Stored** in `<state dir>/projects/<space id>/review-findings.jsonl` (0600, kept 30 days, 2 MB at most). It shares its file handling with `loop.jsonl` (SpaceLog) and is deleted with the space.
- **The Lead's role** gains "Record each review you send with record_review". To stay under Claude Code's 2,048-character cap, "After a /clear, list_tasks shows where things stand." went: list_tasks' own description says it.

## `daily_pass()`

What happened since the last pass, at most 40,000 characters (Claude Code saves a longer MCP result to a file). The rules come right after the instructions, because a cut takes the end:

1. **Review findings by kind:** each kind seen in the window, with where it showed up in the last 30 days (`#594 round 1`, `#611 round 3`). The kinds seen in the most tasks come first.
2. **Pull requests merged** in the window, in each GitHub repository of the space (from each repository's base remote). The repositories are read at once. One `gh pr list --state merged --limit 40` per repository gives:
   - the number, title and branch;
   - the review rounds: the highest "round N" in the commit headlines, or the rounds recorded for its branch if higher;
   - the Why section on one line;
   - the round commits' headlines.
3. **CI:**
   - the runs Nirux triaged in the window (`ci-triage.json`, #323), with their verdict, reason, failing tests and pull request (a new field of RunRecord);
   - the tests learned flaky;
   - reruns, meaning runs whose latest attempt (past the first) started in the window, from one `gh run list` per repository.

   Past 40 pull requests, gh's query (each commit's authors) passes GitHub's 500,000-node limit; the digest says when it was reached.
4. **Mission messages** of the Lead's Missions and of the space's workspaces:
   - **held:** typed an hour or more after they were sent, or still waiting;
   - **given up;**
   - **crossed:** a tell typed after the task's result, or an answer typed after a newer question;
   - **held answers:** a question to the Lead answered an hour or more late, never typed (Nirux types one for an hour only; another parent may have read it with `receive`);
   - **the user's answers:** questions handed to the user (with the reason and the answer, the user's or the Lead's), and questions the user answered in Nirux without being asked.

   Mission messages belong to the space through its workspaces, and those its session history names (closed since), unless they are open in another space now. Lines that look like a secret are withheld, as `read_task` withholds them.
5. **Rules:**
   - the rules decided since the last pass;
   - the rules waiting;
   - the brief's "Rules learned" as sessions read them now (the Lead's copy dates from its start);
   - the rules dismissed in the last 90 days.
6. **What GitHub didn't say**, shown even on a day with nothing else. It isn't news on its own: a signed-out gh would make every day one. Only a gh that didn't answer in time leaves the window to read again; what gh said (signed out, no access) holds until someone acts.

   The store compares wording; the Lead compares meaning.

- **Instructions:** the text opens with what to propose. That is at most the free pending slots (3 minus those waiting), the strongest first, citing the facts' handles. A Nirux bug or a flaky test is a task to start, not a rule. When nothing happened, it says so.
- **Window:** a call reads from where the last one ended (the last day for the first, a week at most). A call within 2 h of the last reads the same window again, longer, without saving it, so the Lead asking again after a compaction or a timeout sees the same facts. The window is kept in `daily-pass.json` beside the brief (0600, deleted with the space). A call that outlives its wait tells the Lead to call again in a minute.

## When (PR 2)

- **Due:** once a day, at the first quiet moment after the space's hour (default 06:00).
- **Quiet means all of these:**
  - the Lead's prompt is free (the Mission typing gate);
  - its last hook event was 30 min ago or more;
  - no Mission message is waiting for it;
  - the user has been away from Nirux for 10 min or more.
- **Only if something happened.** If the Lead never calls `daily_pass`, the next pass covers both days.
- **Settings:** Space Settings › Lead gets a "Daily pass" switch (on by default, the user's call), an hour menu and a "Last pass" line.
- **The note:** the Lead row shows a grey line for 24 h, "Daily pass · 6 PRs, 1 flaky test, 2 rules proposed".

## Cost

- **Model:** the Lead's own (Opus 5.5 today), on the user's subscription.
- **Per run:** 3–8k tokens of facts, plus the Lead's compacted context (30–60k tokens) written to the cache once and read by about 5 requests, plus 3–5k tokens of output.
- **API-equivalent:** about $0.45–0.60 per run, up to about $1.50 for a 150k-token context. A day with nothing to read costs nothing.

## Later

- **Tasks recording their own reviews.** Their adversarial reviews, `/code-review` and premortems find most defects. Today only their round commits reach the digest.

## The 3-pending limit: kept

- Each added rule costs every later session part of the brief's budget, and an unreviewed pile is noise.
- A held-back candidate isn't lost: its findings stay 30 days and the next pass finds it again.
