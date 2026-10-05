# Project Memory

Status: decided with the user on 2026-10-05. The list shipped first, read-only;
changing it (section 4) came second. The History tab, greyed for now, is
designed separately.

Agents learn about a repository from several files: the Nirux project brief,
the repository's `CLAUDE.md` and `AGENTS.md`, and the auto-memory Claude Code
keeps for itself under `~/.claude`. **Project Memory…** shows all of it as one
list, **What agents know**, whatever file holds an item.

![Project Memory, with demo data](images/project-memory.png)

## 1. Opening it

- **⌘P › Project Memory…**: the active workspace's repository.
- **The project menu › Project Memory…**: the repository of that project's
  active workspace, else of its first workspace.

The workspace's own folder decides, not where its focused terminal has
`cd`'d. The panel reads the files each time it opens, off the main thread. It
never writes: **Open in Editor** (Return, or a double click) opens the
selected item's file, at its line, in the editor of that workspace, brought
forward. The editor's own save and disk-conflict rules apply. The panel
changes the brief and Claude Code's memory itself only when asked (section 4).

## 2. The list

Each item has a scope, in a chip:

- **Always**: a rule of the [project brief](projects.md#4-brief). Every
  Claude and Codex session Nirux starts in the project gets it, in every
  worktree.
- **Team** (locked): a rule of the repository's `CLAUDE.md`, `.claude/CLAUDE.md`
  or `AGENTS.md`, at its checkout's top. It changes there, in a commit.
- **When relevant**: a memory of Claude Code's auto-memory (section 3), one
  file each, which a session reads when it needs it. A `MEMORY.md` line whose
  file is gone shows last, in red.

A file's rules are its top-level bullets, their indented lines with them, and
its paragraphs. Headings, blank lines, a frontmatter and `<!-- -->` comments
aren't rules; a fenced code block stays whole. A rule's title is its bold
lead, else its first sentence or clause.

- **The filters**: words (all of them, anywhere in the item, case and accents
  ignored) and a scope: All, Always (the team's rules too: they apply
  always), When relevant.
- **The preview**: the title; the scope and what it means; for a memory, its
  type, date (`metadata.modified`, else the file's), description, and whether
  `MEMORY.md` lists it or lists it past what Claude Code reads; then the
  text. `**bold**` and `` `code` `` show as such; a `[[name]]` link to a
  memory selects it, clearing the filters that hide it; a link to no memory
  stays grey. At the bottom, in small, the file it comes from.
- **A notice** above the list when Claude Code doesn't use its memory
  (section 3), or when a setting moved it.

## 3. Where Claude Code keeps its memory

Claude Code's documentation doesn't give these rules; they come from its code
(version 2.1.289), and `ProjectMemory+Location.swift` follows them:

- **The folder** is `<config>/projects/<encoded root>/memory/`. `<config>` is
  `CLAUDE_CONFIG_DIR`, else `~/.claude`. In the root's path every UTF-16 unit
  but an ASCII letter or digit becomes `-`; past 200 characters, the first 200
  and a hash of the whole path.
- **The root** is the repository's main checkout. From the launch folder,
  Claude Code finds the nearest `.git`; for a linked worktree, it follows its
  `gitdir` and `commondir`, once the worktree's git folder points back at it.
  No git process runs. So every worktree and every subfolder of a repository
  shares one memory, while transcripts stay per worktree. Outside a
  repository, the launch folder is the root.
- **`MEMORY.md`** indexes the memories, one `- [Title](file.md) — hook` line
  each. Sessions read it at their start, trimmed, up to line 200 and 25,000
  characters; Nirux leaves its comments out.
- **`autoMemoryDirectory`**, in the first settings scope that sets it
  (managed, then `.claude/settings.local.json`, `.claude/settings.json`,
  `~/.claude/settings.json`), moves every repository's memory to that folder.
  A value Claude Code refuses (relative, `~/` itself, `~/..`, a network
  volume) leaves the default; it doesn't fall through to the next scope.
- **Off**: `CLAUDE_CODE_DISABLE_AUTO_MEMORY` (`1`, `true`, `yes`, `on`),
  `CLAUDE_CODE_SIMPLE` (`claude --bare`), `CLAUDE_CODE_SAFE_MODE`, or
  `autoMemoryEnabled: false` in the first scope that sets it. A false
  `CLAUDE_CODE_DISABLE_AUTO_MEMORY` (`0`, `false`…) turns it on whatever the
  settings say.

Nirux reads its own environment, not the one a terminal's shell builds from
the user's startup files: a variable exported in `~/.zshrc` doesn't show. Nor
does it see `claude --settings`, a session's own toggles, the server's feature
flags, or whether the repository's settings are trusted (Claude Code reads a
repository's settings only once its folder is trusted).

Codex reads the brief (as `developer_instructions`) and `AGENTS.md`, not
Claude Code's memory.

## 4. Changing it

- **Always / When relevant**: the switch above an item of the brief or of
  the memory moves it to the other. A rule becomes a memory titled after its
  bold lead or first sentence, of type `feedback`; a memory becomes a rule,
  its title in bold ahead of its text (unless the text starts with it), its
  file to the Trash, once confirmed. While auto-memory is off, nothing moves
  to When relevant, and "+ Add" offers only Always.
- **Edit** shows the item's text as written, Markdown and all, without
  smart quotes or dashes; **Save** (⌘S) writes it, **Cancel** (Escape)
  leaves it. Meanwhile no other item can be picked and the panel stays open:
  the edit never goes unsaved by a stray click. A memory keeps its
  frontmatter, its `modified` date updated. An emptied text isn't saved:
  Delete… asks first.
- **+ Add**: a title, where it goes (When relevant by default: a memory, its
  kebab-case file name shown, with a type and a description; or Always: a
  rule of the brief, its title in bold), and the text. A title already taken
  gets a number, `MEMORY.md` included; one without a letter a file name can
  use is filed as `note.md`.
- **Delete…**, once confirmed: a memory's file goes to the Trash and its
  `MEMORY.md` lines go; a rule leaves the brief; a `MEMORY.md` line whose
  file is gone leaves the index.
- The team's `CLAUDE.md` and `AGENTS.md` change only in the editor, in a
  commit.
- A write that fails says why at the bottom of the panel; an edit stays as
  typed.

**Safe writes.** Sessions write the memory folder at any time, with no lock
shared with Nirux.
- What a write acts on is the item the user picked, by its file or its
  lines, never its place in the list. Nirux runs its writes one at a time,
  and takes no other action until one ends.
- Before writing, Nirux checks the item still reads as the panel showed it:
  a memory an agent changed since, or a brief rule that moved, is left
  alone, with a message.
- Every write goes to a hidden temporary file beside its target (a link's
  target), synced to disk with the target's permissions, then a rename; a
  new file never replaces one that appeared meanwhile.
- Right before the rename, Nirux reads the file again: changed meanwhile, it
  starts over from what is there. `MEMORY.md` gets its line added or
  removed, every other line kept as written, with its own line breaks.
- A rule that shares its lines with a `<!-- -->` comment, a file that is
  read-only, not UTF-8, or past 4 MB, and a brief that would pass the 16,000
  characters sessions get are left alone, with a message.
- Nirux writes only the files the user acted on: the brief, the memory's
  file, `MEMORY.md`.
