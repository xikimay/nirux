# Pull requests

Nirux follows the pull request of each workspace's branch and brings its state to the sidebar. It reads GitHub through the GitHub CLI: `gh` must be installed with Homebrew (`/opt/homebrew/bin/gh` or `/usr/local/bin/gh`) and signed in.

## The pull request line

A workspace whose branch has an open pull request shows it in its status line: `#39 · checks passed`, `#39 · checks failed`, `Ready to merge`. Once merged, the row reads `Merged · Clean up` (see [Cleaning up merged worktrees](spaces-and-tasks.md#cleaning-up-merged-worktrees)).

A click on that line, or on the PR and CI links of the selected row, opens the page in a browser column of the same workspace. CI opens the failed check, else the pull request's Checks tab.

## CI failures

When a workspace's open pull request turns red, its row reads `#N · checks failed` in red. Only the latest run of each check counts. While Nirux is in the background, it also notifies once per failed job, once the job's run has ended.

The row's menu and the notification offer two actions:

- **Ask Agent Why CI Failed** types `gh run view <id> --repo <repository> --log-failed` into the workspace's agent.
- **Rerun Failed CI Jobs…** runs `gh run rerun <id> --failed` once you confirm.

Both act only on GitHub Actions runs of the pull request's own repository.

### Failures that look flaky

When a failure looks flaky, the row reads `#N · checks failed · likely flaky`, the notification says why, and the rerun comes first. Nirux never reruns by itself.

A failure looks flaky when a job never ran, a dependency download failed, the failing tests passed on a rerun before, or the failing tests have nothing to do with the pull request. Fixed rules read the failed log with `gh` first. What they leave open goes to Claude Sonnet through `claude -p`, on a Claude subscription only, and only for a workspace whose Claude Code runs on that account.

It reads XCTest and Swift build logs only. **Settings › Notifications** turns it off.

## Review badges

The selected workspace's row shows which review passes ran in its Claude sessions: `/code-review`, `/premortem`, `/code-style-review` and an adversarial review, as `CR ✓  PM ✓  CS ·  ADV ·`. A green check ran on the current HEAD, a grey one on an earlier commit, and a dot never ran. Nirux keeps the pass's name, never the prompt.

## Review feedback

For an open pull request, Nirux counts the feedback nobody has dealt with yet: unresolved review threads, and comments newer than both the head commit and your last reply. Only people with a role on the repository (owner, member, collaborator) and apps installed there count.

The selected row shows the counts, people and bots apart. Its menu lists up to ten items, each opening on GitHub, then **Address**, which types a `/receiving-code-review` prompt naming those items into the workspace's Claude agent.

## Reading a branch on one page

`Review Branch`, in the command palette or a workspace's menu, opens a Branch Review column next to the agent. It reads the branch checked out in the workspace's folder, from its merge base with the base branch to the working tree, uncommitted changes included, without writing to the repository. The page shows:

- the pull request's description, the handover and the commits, each labeled with its source;
- risk signals from fixed rules (persistence, security, concurrency, launch, CI, side effects, dependencies), and how the tests compare with the code;
- the files grouped by path, with lockfiles, generated files, pure renames, whitespace-only changes and binary files folded.

A row opens into its diff. The column follows its worktree: a moment after the agent stops writing, it reads the branch again. A new commit waits behind a **Reload** banner, so the page you are reading isn't rewritten under you.

### Explain

**Explain** asks Claude Code (`claude -p` on your Claude account) to read the branch and a read-only copy of its files, with secrets and instruction files left out. The model and effort are set in **Settings › Agents › Branch Review**.

- The first time in a space, an alert says what is sent, with which model, and under which account. It asks again when the account changes, and every time for an account billed per call.
- Claude's overview shows above the author's own account, with the author's claims the code doesn't match and questions for the author. Files are regrouped by intent, and each gets a sentence.
- In an open diff, Claude's notes sit under the hunks they explain. **Mark wrong** records a note as wrong, and the bar says how often notes were.
- The next Explain sends only the files changed since. **Explain All Again** sends every file.
- The bar shows the day's runs on the branch, their tokens and what they would cost at API prices.

One Explain runs at a time in the whole app. **Cancel** stops it. Explain is disabled, with the reason, when no `claude` 2.1.284 or later is found or it isn't logged in.

## The Board

`Ctrl+Cmd+B`, or `Open Board` in the command palette, opens a table of the current space's branches with their agents, pull requests and checks. From it you can queue pull requests to merge one at a time; the queue stops at the first problem and nothing merges without your confirmation. The design record [Project Board](design/project-board.md) has the rules.
