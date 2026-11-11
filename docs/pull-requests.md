# Pull requests

Nirux follows the pull request of each workspace's branch and shows its state in the sidebar. It reads GitHub through the GitHub CLI: `gh` must be installed with Homebrew (`/opt/homebrew/bin/gh` or `/usr/local/bin/gh`) and signed in.

## The pull request line

A workspace whose branch has an open pull request shows it in its status line: `#39 · checks passed`, `#39 · checks failed`, `Ready to merge`. Once the pull request is merged, the row reads `Merged`, followed by `Clean up` when its worktree can be removed (see [Cleaning up merged worktrees](spaces-and-tasks.md#cleaning-up-merged-worktrees)).

The selected row also has a PR link and, while the pull request is open, a CI link. Each opens in a browser column of the same workspace. CI opens the failed check, else the pull request's Checks tab.

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

The selected workspace's row shows which review passes you ran in its Claude Code sessions: the slash commands `/code-review`, `/premortem` and `/code-style-review`, and an adversarial review, as `CR ✓  PM ✓  CS ·  ADV ·`.

| Mark | Meaning |
| --- | --- |
| green check | run on the current commit |
| grey check | run on an earlier commit |
| dot | not run |

Nirux keeps the pass's name, never the prompt.

## Review feedback

For an open pull request, Nirux counts the feedback nobody has dealt with yet: unresolved review threads, and comments newer than both the head commit and your last reply. Only people with a role on the repository (owner, member, collaborator) and apps installed there count.

The selected row shows the counts, people and bots apart. A click on them lists up to ten items, each opening on GitHub. Below them, **Address** types a prompt into the workspace's Claude Code session that starts with `/receiving-code-review` and names every item.

## Branch Review

`Review Branch`, in the command palette or a workspace's menu, opens a Branch Review column next to the agent: the whole branch on one page. It reads the branch checked out in the workspace's folder, from where it left the base branch to the working tree, uncommitted changes included, and writes nothing to the repository. The page shows:

- the pull request's description, the handover file and the commits, each labeled with its source;
- risk signals from fixed rules (persistence, security, concurrency, launch, CI, side effects, dependencies), and how the tests compare with the code;
- the files grouped by path, with lockfiles, generated files, pure renames, whitespace-only changes and binary files folded.

A row opens into its diff. The column follows its worktree, and reads the branch again a moment after the agent stops writing. A new commit waits behind a **Reload** banner, so the page doesn't change while you read it.

### Explain

**Explain** asks Claude Code, on your Claude account, to read the branch and a read-only copy of its files, with secrets and instruction files left out. The model and effort are set in **Settings › Agents › Branch Review**.

- The first time in a space, an alert says what is sent, with which model and under which account. It asks again when the account changes, and every time for an account billed per call.
- Claude's overview shows above the author's own description of the change. It lists the claims in that description that the code contradicts, and questions for the author. Files are regrouped by intent, and each gets a sentence.
- In an open diff, Claude's notes sit under the hunks they explain. **Mark wrong** flags a note, and the page's bar shows how often notes were marked wrong.
- The next Explain sends only the files changed since and those not explained yet. **Explain All Again** sends every file.
- The same bar shows the day's runs on the branch, their tokens and what they would cost at API prices.

One Explain runs at a time in the whole app, and **Cancel** stops it. Explain is disabled, with the reason, when no `claude` 2.1.284 or later is found or it isn't logged in.

## The Board

`Ctrl+Cmd+B`, or `Open Board` in the command palette, opens a table of the current space's branches with their agents, pull requests and checks.

From the Board you can queue pull requests to merge one at a time. Nothing merges without your confirmation. The queue reruns a failed required check once, then stops at the first problem. Its rules are written down in the design record [Project Board](design/project-board.md).
