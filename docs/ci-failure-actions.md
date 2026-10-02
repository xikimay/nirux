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
  sidebar's `✗ CI` follows the same rule (today it only sees FAILURE, and a
  rerun's old failure keeps it red).
- **Any red check counts**, required or not: section 3.2 says a red check
  blocks the merge either way, and a workspace isn't tied to a board config.
- **Notify once per failure.** A notification names the PR and its red checks.
  "Once" is keyed on the red check runs' URLs: a rerun that fails again is a
  new run, so it notifies again. Like agent attention: the card's attention
  glow and the Dock badge, plus a native notification while Nirux is in the
  background. The first poll after launch only records what is red: no burst of
  notifications at launch.
- **Two actions**, in the card's right-click menu while the PR is red, and as
  buttons on the notification:
  - **Why Failed:** types into the workspace's agent (the first column whose
    agent accepts prompts, through the remote prompt path: sanitized, bracketed
    paste, refused while a dialog is open) "CI failed on PR #52. Run `gh run
    view 123 --repo github.com/owner/name --log-failed`, then tell me why it
    failed." Built only from
    the run id and repository parsed out of a GitHub Actions URL
    (`https://github.com/<owner>/<repo>/actions/runs/<id>`), never from check
    names or other text GitHub returns. Without an agent, or for a check that
    isn't an Actions run (external CI), the item opens the check's URL.
  - **Rerun Failed:** an outward action, so an alert confirms first, naming
    the PR and the runs. Then `gh run rerun <id> --repo github.com/owner/name
    --failed` for each red Actions run (the merge queue's own arguments), and
    the pull request poll goes hot (30 s), as after a push.

## Decided

1. Any red check notifies, required or not.
2. The first pull request read after launch stays silent.
3. Both the card menu and the notification's buttons offer the actions.
4. While the agent shows a dialog, Why Failed types nothing (it would answer
   the dialog): it focuses the column instead.

## Files

`PRDetect` (red rule, `PRInfo.redChecks`), `WorkspaceState.takeNewRedChecks`
(notify-once), `CIFailure` (run URL parsing, prompt, rerun arguments),
`NiruxNotifier` (category with two buttons), the card menu in
`SidebarMenuSupport`, `NiruxShellView+CIFailure` for the two actions.
Tests: `CIFailureTests`, and `SidebarPanelFlowTests.testCIFailureMenuItems`.
