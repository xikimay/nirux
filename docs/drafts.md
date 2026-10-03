# Drafts

Status: design, validated by the user on 2026-10-02. Implemented as the
`nirux-draft` skill.

## Problem

Agents write many texts the user pastes elsewhere: Slack messages, review
comments, Linear tickets, PR descriptions, emails, SQL to run in Drizzle Studio
or Supabase. Copying them from the terminal is lossy: Claude's rendering adds
`▎` quote bars, wraps lines and indents, and a long draft scrolls away.

## Shape

No new panel. A draft is a file opened in the editor column, which already
does what a draft needs:

- `nirux://open-editor` opens any absolute text file, without a dialog when
  it carries `launch=`. It brings Nirux forward but leaves keyboard focus in
  the terminal;
- Monaco shows the raw text. The user can edit it, then click into it:
  `⌘A ⌘C` copies it verbatim;
- `⌘W` dismisses it, without asking even when it was edited.

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
   no headings or tables), so no converter is needed. Paragraphs are never
   hard-wrapped: the target keeps every newline.
5. Asked to post a draft, the agent reads the file back first: the user may
   have edited it.

No new URL, no CLI flag.

## Decided

- **No Copy button** in v1: `⌘A ⌘C` is enough.
- **Ephemeral**: drafts live in `$TMPDIR`, which macOS cleans up. A restored
  editor tab whose draft is gone doesn't open, silently (restore is
  non-interactive), and can leave an empty editor column.

## Measured

Copying from Nirux's editor (its real page, in a `WKWebView`) puts the draft
byte for byte on the pasteboard as plain text. Monaco also writes `public.html`
(dark background, monospace, colored spans) because `copyWithSyntaxHighlighting`
is on by default.
