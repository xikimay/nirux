# CI Failure Actions

Status: validated by the user on 2026-10-02, implemented.

In three weeks the user typed 16 prompts like "pk la CI fail ?" or "relance le
job qui a fail". Nirux already polls each workspace's pull request and shows
`✗ CI` on its card, but says nothing when it turns red, and the two follow-ups
are typed by hand.

## Shape

- **Detection.** No new `gh` call: the workspace's own pull request poll
  (`PRDetect`, `PullRequestRefreshPolicy`) already reads `statusCheckRollup`.
  A check is red by the definition of [Project Board](project-board.md),
  section 3.2: only the latest run per check name and workflow counts;
  FAILURE, CANCELLED, TIMED_OUT, ACTION_REQUIRED, STARTUP_FAILURE, STALE, or a
  commit status in ERROR or FAILURE. NEUTRAL and SKIPPED aren't red. The
  sidebar's `✗ CI` now follows the same rule (it used to see only FAILURE, and
  a rerun's old failure kept it red).
- **Any red check counts**, required or not: section 3.2 says a red check
  blocks the merge either way, and a workspace isn't tied to a board config.
- **Open pull requests only**, and a failed job waits for the rest of its
  Actions run: until the run ends, it can be neither rerun nor read.
- **Notify once per failure.** A notification names the PR and its red checks.
  "Once" is keyed on each red check's workflow, name, start and URL: a rerun
  that fails again, or a status posted again, notifies again. Like agent
  attention: the card's attention glow and the Dock badge (not for the
  workspace on screen), plus a native notification while Nirux is in the
  background. The first read after launch, or on another branch, only records
  what is red: a pull request that was already red isn't news.
- **Two actions**, in the card's right-click menu while the PR is red, and as
  buttons on the notification. Both act only on Actions runs of the pull
  request's own repository: anyone who can post a check on it chooses the
  check's URL.
  - **Ask Agent Why CI Failed:** types into the workspace's agent (the focused
    column's, else the first column whose agent accepts prompts, through the
    remote prompt path: sanitized, bracketed paste, refused while a dialog is
    open) "CI failed on PR #52. Run `gh run view 123 --repo
    github.com/owner/name --log-failed`, then tell me why it failed." Built
    only from the run id and repository parsed out of a GitHub Actions URL
    (`https://<host>/<owner>/<repo>/actions/runs/<id>`), never from check names
    or other text GitHub returns. Without an agent, or without such a run, it
    opens the check's URL if it is https, else the pull request.
  - **Rerun Failed CI Jobs…:** an outward action, so an alert confirms first,
    naming the PR, the runs and their repository. Then `gh run rerun <id>
    --repo <host>/owner/name --failed` for each red run, and the pull request
    poll goes hot (30 s), as after a push.

## Decided

1. Any red check notifies, required or not.
2. The first pull request read after launch stays silent.
3. Both the card menu and the notification's buttons offer the actions.
4. While the agent shows a dialog, Why Failed types nothing (it would answer
   the dialog): it focuses the column and beeps instead.

## Files

`PRDetect` and `ProjectBoard.latest` (red rule, `PRInfo.checks`),
`WorkspaceState.takeNewRedChecks` (notify-once), `CIFailure` (red checks to
act on, run URL parsing, prompt, rerun),
`NiruxNotifier` (category with two buttons), the card menu in
`SidebarMenuSupport`, `NiruxShellView+CIFailure` for the two actions, and
`ShellSideEffects.rerunFailedJobs`, which tests replace.
Tests: `CIFailureTests`, and `SidebarPanelFlowTests.testCIFailureMenuItems`.
