# Pull requests

Nirux follows the pull request of each workspace's branch and shows its state in the sidebar. It reads GitHub through the GitHub CLI: `gh` must be installed with Homebrew (`/opt/homebrew/bin/gh` or `/usr/local/bin/gh`) and signed in.

## The pull request line

A workspace whose branch has an open pull request shows it in its status line: `#39 · checks passed`, `#39 · checks failed`, `Ready to merge`. Once the pull request is merged, the row reads `Merged`, followed by `Clean up` when its worktree can be removed (see [Cleaning up merged worktrees](spaces-and-tasks.md#cleaning-up-merged-worktrees)).

The selected row also has a PR link and, while the pull request is open and has checks, a CI link. Each opens in a browser column of the same workspace. CI opens the failed check, else the pull request's Checks tab.

## CI failures

When the checks of a workspace's open pull request fail, its row reads `#N · checks failed` in red once no agent there is working. Only the latest run of each check counts. While Nirux is in the background, it also sends a notification that names the checks that newly failed.

The row's menu and the notification offer two actions:

- **Ask Agent Why CI Failed** asks the workspace's agent to run `gh run view <id> --repo <repository> --log-failed` and say why the run failed.
- **Rerun Failed CI Jobs…** runs `gh run rerun <id> --repo <repository> --failed` once you confirm.

Both act only on GitHub Actions runs of the pull request's own repository.

### Failures that look flaky

A failure looks flaky when a job never ran, a dependency download failed, the failing tests passed on a rerun before, or the failing tests have nothing to do with the pull request. The row then reads `#N · checks failed · likely flaky`, and the menu and the notification say why and offer the rerun first. Nirux leaves the rerun to you.

Nirux judges from the failed log. When tests fail that the pull request doesn't touch, it asks Claude Sonnet, on a Claude subscription only, and only for a workspace whose Claude Code runs on that account. Only XCTest and Swift build logs are supported. **Settings › Notifications** turns this off.

## Review badges

The selected workspace's row shows which review passes ran in its Claude Code sessions, typed by you or started by Claude: the slash commands `/code-review`, `/premortem` and `/code-style-review`, and an adversarial review, as `CR ✓  PM ✓  CS ·  ADV ·`.

| Mark | Meaning |
| --- | --- |
| green check | run on the current commit |
| grey check | run on an earlier commit |
| dot | not run |

Nirux keeps the pass's name, never the prompt.

## Review feedback

For an open pull request, Nirux counts the feedback nobody has dealt with yet: unresolved review threads, and comments newer than both the head commit and your last reply. Only people with a role on the repository (owner, member, collaborator) and apps installed there count.

The selected row shows the counts, people and bots apart. A click on them lists up to ten items, each opening on GitHub. Below them, **Address** types a prompt into the workspace's Claude Code session that starts with `/receiving-code-review` and names every item.

## Automatic follow-up

**Space Settings › Defaults › Follow up on pull requests** is on by default; only turning it off in a space stops it. From the first launch that follows a pull request, or from switching it on, feedback posted before is left to you; checks still red count. While it's on, Nirux keeps the pull requests of the space's tasks mergeable while their Claude Code sits idle. It types the prompt each one needs, in this order:

- a conflict with the base: merge `<remote>/<base>`, resolve the conflicts, run the checks, push. Never a rebase.
- a failed check (FAILURE or TIMED_OUT in the pull request's own Actions runs, not a likely flake), 2 minutes after it failed: find why, fix it, push, or say the branch didn't cause it.
- new review feedback (review threads, and what people write besides an approval), 3 minutes after the last item: the Address prompt for the new items.

It waits while the agent works, asks you something, has text in its prompt, or a Mission message waits for it; while you're on its terminal; while the checkout has uncommitted changes to tracked files (untracked files don't count) or isn't at the pull request's head; and while a merge queue holds the pull request or auto-merge is on. A review thread whose last comment is yours waits on its reviewer. One round runs at a time across tasks; the row reads `Auto follow-up 1/3 · failed checks` meanwhile.

The row reads `Needs you · …` in amber with the reason when a fourth round would be due, when a round pushed nothing while its problem is still there, or when the checkout still isn't at the pull request's head 10 minutes after a round. No round goes until the pull request's head moves or the problem goes away; a prompt into the agent clears the amber line. Your own **Address** or **Ask Agent Why CI Failed** takes that feedback or failure out of its hands. Tasks only: never the main checkout or the Lead. A Claude Code resumed after a relaunch takes no round until it has taken a prompt, as with Mission messages. Its decisions go to the `followUp` log category.

## Branch Review

`Review Branch`, in the command palette or a workspace's menu, opens a Branch Review column next to the agent: the whole branch on one page. It reads the branch checked out in the workspace's folder, from where it left the base branch to the working tree, uncommitted changes included, and writes nothing to the repository. The page shows:

- the pull request's description, the handover file and the commits, each labeled with its source;
- risk signals from fixed rules (persistence, security, concurrency, launch, CI, side effects, dependencies), and how the tests compare with the code;
- the files grouped by path, with lockfiles, generated files, pure renames, whitespace-only changes and binary files folded.

A row opens into its diff. The column follows its worktree, and reads the branch again a moment after the agent stops writing. A new commit waits behind a **Reload** banner, so the page doesn't change while you read it.

From the column’s **⋯** menu, choose **Attach Report…** to import a JUnit XML file up to 2 MB. Its test counts and result appear under **Verification receipts** with the source **Local**. From an isolated test browser’s **Screenshot Saved** or **Browser Diagnostics** sheet, choose **Attach to Branch Review** to attach that workspace’s capture as a **Local browser** receipt with its URL, timestamp, error counts, and a safe preview/reveal action. **Current** means the commit and working tree match the snapshot shown when you attached the report or capture. A later commit or local edit makes the receipt **Stale**.

### Explain

**Explain** asks Claude Code, on your Claude account, to read the branch and a read-only copy of its files, with secrets and instruction files left out. The model and effort are set in **Settings › Agents › Branch Review**.

- The first time in a space, an alert says what is sent, with which model and under which account. It asks again when the account changes, and every time for an account billed per call.
- Claude's overview shows above the author's own description of the change. Below that description, **Checked by Claude** lists the claims in it that the code doesn't fully match, then Claude's questions for the author. Files are regrouped by intent, and each gets a sentence.
- In an open diff, Claude's notes sit under the hunks they explain. **Mark wrong** flags a note, and the page's bar shows how often notes were marked wrong.
- The next Explain sends only the files changed since and those not explained yet. **Explain All Again** sends every file.
- The same bar shows the day's runs on the branch, their tokens and what they would cost at API prices.

One Explain runs at a time in the whole app, and **Cancel** stops it. Explain is disabled, with the reason, when no `claude` 2.1.284 or later is found or it isn't logged in.

## The Board

`Ctrl+Cmd+B`, or `Open Board` in the command palette, opens the Board of the current space: a section per repository, one line per task. A repository that isn't one of the space's (Space Settings) but holds one of its workspaces has a read-only section: its tasks there and their pull requests, without a merge queue.

- Each line shows the task's state, a rail of four stations (Code, Reviews, Checks, Merge), a phrase saying what the task waits for, its pull request and a time. A sub-task sits under its task; a stack of pull requests shares a numbered rail.
- A click on a line opens the task. A right click shows its menu: Open Pull Request, Add to Queue, Retarget, Resume, Clean Up…, Open.
- With Full Keyboard Access on (System Settings › Keyboard), Tab moves from line to line; Space or Return opens the task, Control-Return shows its menu.
- Pull requests without a task and other worktrees are folded at the end of each repository, then the pull requests merged today.
- The switch at the top orders the lines as the sidebar does, or by progress.
- The Board belongs to its workspace's space: move that workspace to another space and the Board follows. A space has one Board: if it has its own already, the moved one closes and that one comes forward. While the space's merge queue runs, the workspace of its Board stays where it is.
- A repository's header shows its last post-merge run, or what went wrong reading it, and its merge queue: Start… and Stop. Once a queue has run, Journal… shows its stop cause and recent steps. Open on GitHub takes you to the relevant run or pull request. Copy includes the status and entries, and labels a dry run.

From the Board you can queue pull requests to merge one at a time: a click on a line's Merge station adds its pull request to the queue, a second one takes it back. Nothing merges without your confirmation. The queue reruns a failed required check once, then stops at the first problem. The Train cadence lands the batch in one CI run; when that run fails, the batch rides again in two halves, one train at a time, until the pull request that breaks it is alone, and the queue stops on it once the others landed. Its rules are written down in the design record [Project Board](design/project-board.md).
