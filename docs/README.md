# Nirux documentation

Guides say how to use Nirux today. Design records say why it is the way it is.

## User guides

| Page | What it covers |
| --- | --- |
| [Getting started](getting-started.md) | The first launch and the first task |
| [Workspaces and columns](workspaces-and-columns.md) | The sidebar, terminals, the editor, the browser, search |
| [Spaces and tasks](spaces-and-tasks.md) | Spaces and their repositories, `Cmd+N`, worktrees and their cleanup, space memory, the Lead |
| [Agents](agents.md) | Status hooks, lights and notifications, resuming after a restart, usage indicators |
| [Mission handoffs](missions.md) | How a parent agent and the agent it started exchange questions and results |
| [Pull requests](pull-requests.md) | The pull request line, CI failures, review badges, Branch Review, the Board |
| [Terminal appearance](terminal-appearance.md) | Which Ghostty settings the terminals follow |
| [Keyboard shortcuts](keyboard-shortcuts.md) | Every shortcut and command palette action |
| [URL scheme and agent skills](url-scheme.md) | `nirux://` links and the skills that use them |

## Working on Nirux

| Page | What it covers |
| --- | --- |
| [Development](development.md) | Build, test, run, environment variables, where things are |
| [Release signing](release-signing.md) | The nightly workflow, signing and notarization, rolling back a build |

## Design records

Each record was written before or while its feature was built, and validated by the maintainer. They are kept as decision history and are not updated as the app changes: a header at the top of each says what shipped and where the current guide is.

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
