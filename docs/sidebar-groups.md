# Sidebar Groups

Status: v1 implemented. Direction validated by the user on 2026-10-07:
"faire des sortes de dossier, en dessous de celui-ci pourraient vivre des
workspaces". Shape validated on 2026-10-08, with the folded state saved and
red checks counted.

A **group** is a workspace and the workspaces nested under it, inside a
project's sidebar. A parent that opens four review worktrees through
`nirux-worktree` lists five cards today, flat, in opening order: nothing
says which ones it opened, and they push the rest of the project down.

What Nirux already knows: a workspace opened as a Mission child keeps its
`missionID` (state.json), and its Mission records `parentWorkspaceID`
(missions.json). No new data is needed for v1.

## Shape

**1. One order for everything.** `WorkspaceStore.visibleWorkspaceIndices`
lists each workspace followed by its children, depth first, siblings in
store order. The sidebar cards, the rail, the workspace strip, ⌘↑/↓ and the
close fallback already follow that list, so they agree without changes.

- A workspace's **parent** is its Mission's `parentWorkspaceID`, when that
  workspace is open in the same project and the same section (ACTIVE or
  INACTIVE). Otherwise it sits at the top level: a parent closed, moved to
  another project or parked in INACTIVE lets its children go.
- Read from `MissionStore` on each pass, not cached. Missions load before
  the workspaces are restored, so the first layout is already grouped.
- The store keeps that order: a new Mission child goes after its parent's
  group, and a move carries a whole group. A parent closed, parked or
  moved away leaves its children in its place, at the top level.
- A grandchild follows its own parent (depth first), drawn at the same
  indent as a child: one level of indent in a 260pt sidebar.

**2. Show it.**

- A child card is indented by 12pt, the same card otherwise.
- Under a parent card, a toggle row: `▾ 3 workspaces`. Folded, where they
  stand, most pressing first: `▸ 3 · 1 waiting · ✕ 1 · 2 done · 1 working`,
  each count in its state's color. ✕ counts open pull requests with red
  checks; done, children whose Mission completed or whose PR merged. With
  no count, `▸ 3 workspaces`.
- A folded group still lists a child on screen or one that asks the user
  (waiting, broken): the rule the folded INACTIVE section follows
  (`listsWorkspace`), without Allow / Deny buttons there too. ⌘↑/↓ steps
  over a folded group as over one card (⌘J still reaches a waiting child),
  and closing a folded parent selects the next card, not a hidden child.
- A new child unfolds its parent: it would hide under a fold left from
  earlier children.
- A parent listed only for being on screen or asking the user, in the
  folded INACTIVE section, has no summary row: its children can't show.
- Folding is saved in state.json, on the parent (`isGroupFolded`): a
  parent with many reviews stays folded across launches.
- **Rail** (collapsed sidebar, #106): same order, no indent and no toggle
  tile; a folded group hides its quiet children there too.

**3. Move.**

- Move Up / Move Down and drag-reorder move a workspace among its
  siblings; its children follow. A top-level drag slides over whole groups
  (the card and its listed children are one drop target).
- A Mission child can't leave its parent in v1: that is step 2.

## Not in v1

- **Manual folders** (step 2, own PR): "Nest Under ▸" in the card menu, or
  a drop onto a card, persisted in state.json as the workspace's chosen
  parent, which wins over the Mission's. A nest that would make a loop is
  refused.
- **PR stacks** ([pr-stacks.md](pr-stacks.md)) as groups: only if step 2
  makes it fall out.

## Decided

- **Approval text wraps at 26 characters**, not 28: an indented card's box
  is 12pt narrower, and the request text is never clipped. Every card uses
  the same width so a card doesn't reflow when its parent closes.
