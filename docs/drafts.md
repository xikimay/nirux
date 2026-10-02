# Drafts

Status: design validated on 2026-10-02, implemented as the `nirux-draft` skill.

## Problem

Agents write many texts the user pastes elsewhere: Slack messages, review
comments, Linear tickets, PR descriptions, SQL to run in Drizzle Studio or
Supabase. Copying them from the terminal is lossy: Claude's rendering adds
`▎` quote bars, wraps lines and indents, and a long draft scrolls away.

## Shape

No new panel. A draft is a file opened in the editor column, which already
does what a draft needs:

- `nirux://open-editor` opens any absolute text file, without a dialog when
  it carries `launch=`, and without taking keyboard focus;
- Monaco shows the raw text, `⌘A ⌘C` copies it verbatim, and the user can
  edit it before copying;
- `⌘W` dismisses it.

What ships is one bundled skill, `nirux-draft`, next to `nirux-show-code`:

1. Triggered when the agent drafts text the user will paste elsewhere, or
   when the user asks for a draft.
2. The agent makes a private folder with
   `mktemp -d "${TMPDIR:-/tmp}/nirux-draft-XXXXXX"` (`$TMPDIR` is per user on
   macOS, the folder is `0700`), and writes `<slug>.md` or `<slug>.sql` in it.
   Outside the worktree, so it never shows in `git status` nor blocks a cleanup.
3. It opens it with `nirux://open-editor` and replies with one line instead
   of the text.
4. Slack drafts are written in Slack's markup directly (`*bold*`, `•` lists,
   no headings or tables), so no converter is needed.

No new URL, no CLI flag.

## Decided

- **No Copy button** in v1: `⌘A ⌘C` is enough.
- **Ephemeral**: drafts live in `$TMPDIR`, which macOS cleans up. A restored
  editor tab whose draft is gone doesn't open, silently (restore is
  non-interactive).

## Measured

Copying from Nirux's editor (its real page, in a `WKWebView`) puts the draft
byte for byte on the pasteboard as plain text. Monaco also writes `public.html`
(dark background, monospace, colored spans) because `copyWithSyntaxHighlighting`
is on by default.
