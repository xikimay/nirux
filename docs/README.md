# Nirux documentation

## User guides

| Page | What it covers |
| --- | --- |
| [Getting started](getting-started.md) | The first launch and the first task |
| [Workspaces and columns](workspaces-and-columns.md) | The sidebar, terminals, the editor, the browser, search |
| [Spaces and tasks](spaces-and-tasks.md) | Spaces and their repositories, `Cmd+N`, worktrees and their cleanup, Space Memory, the Lead |
| [Agent status](agent-status.md) | Status hooks, lights and notifications, resuming after a restart, usage indicators |
| [Mission handoffs](missions.md) | How an agent and the agent it started exchange questions and results |
| [Pull requests](pull-requests.md) | The pull request line, CI failures, review badges, Branch Review, the Board |
| [Agent skills](agent-skills.md) | The instructions Nirux installs for Claude Code and Codex |
| [Terminal appearance](terminal-appearance.md) | Which Ghostty settings the terminals follow |
| [Keyboard shortcuts](keyboard-shortcuts.md) | Nirux's shortcuts and command palette actions |
| [URL scheme](url-scheme.md) | `nirux://` links, for scripts and skills |

## Working on Nirux

| Page | What it covers |
| --- | --- |
| [Development](development.md) | Build, test, run, environment variables, where things are |
| [Release signing](release-signing.md) | The nightly workflow, signing and notarization, rolling back a build |

## Design records

A design record holds the decisions behind one feature, as they were taken. Records are not kept up to date. A header on each says what shipped and links the current guide.

| Record | Status |
| --- | --- |
| [Spaces, anchors and the Lead](design/spaces.md) | Shipped |
| [Projects](design/projects.md) | Shipped in part, partly superseded by Spaces |
| [Project Board](design/project-board.md) | Shipped, except the journal view and Ask Agent to Resolve |
| [Stacked pull requests](design/pr-stacks.md) | v1 shipped |
| [Branch Review](design/branch-review.md) | Shipped |
| [Review badges](design/review-badges.md) | Shipped in part |
| [PR feedback inbox](design/pr-feedback-inbox.md) | Shipped, sidebar part changed since |
| [CI failure actions](design/ci-failure-actions.md) | Shipped |
| [CI failure triage](design/ci-failure-triage.md) | Shipped |
| [Mission tell](design/mission-tell.md) | Shipped |
| [Drafts](design/drafts.md) | Shipped as the `nirux-draft` skill |
| [Second opinion](design/second-opinion.md) | Shipped as the `nirux-second-opinion` skill |
| [Project memory](design/project-memory.md) | Shipped in part, as Space Memory |
| [Project memory tree](design/project-memory-tree.md) | Removed in #180 |
