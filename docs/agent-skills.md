# Agent skills

Agent skills are instruction files that Nirux installs for Claude Code and Codex. They teach an agent to use Nirux, for example to open a workspace for a new task or to show you a file in the editor.

`Install Agent Skills`, in the command palette or the Getting Started list, writes four skills. Each goes to `~/.claude/skills/<name>/SKILL.md` and `~/.agents/skills/<name>/SKILL.md`.

| Skill | What it lets an agent do |
| --- | --- |
| `nirux-worktree` | Open a separate Nirux workspace, in a new worktree, when you ask it to start a feature, a fix or a parallel piece of work |
| `nirux-show-code` | Open code in an editor column when you ask to see it, instead of pasting it in the terminal |
| `nirux-draft` | Put text you will paste elsewhere (a Slack message, a pull request description, a ticket, a SQL query) in an editor column, where `Cmd+A` then `Cmd+C` copies it exactly |
| `nirux-second-opinion` | When you ask Claude Code for a second opinion, send its answer to a read-only `codex exec` in the same folder and show Codex's reply |

The first three reach Nirux through its [URL scheme](url-scheme.md).

## Updates

At launch, Nirux updates the skills it installed. A skill you edited, or one reached through a symbolic link, is left alone until you press **Update** in Getting Started or run `Install Agent Skills` again.

The launch update never adds back a skill you deleted from a folder. `Install Agent Skills` does.
