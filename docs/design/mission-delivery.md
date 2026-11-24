# Mission Delivery

> **Design record:** how Mission messages reach an agent without typing them into its terminal. PR 1 (#804) added the NiruxCore primitives; PR 2 delivers to Claude Code through them (section 4).

Status: study approved by the user on 2026-11-23. Study page (French, with the probe evidence):
https://claude.ai/artifact/8iWz1hVfqPXM91adogYMFS

Nirux types each Mission message (a tell, a reply, a question, a result) into
the receiving agent's prompt: a bracketed paste, then Enter, behind draft and
turn guards. Typing caused #483, #635, #645 and #776, and holds messages for
hours behind a running turn or a draft. Each agent CLI now has a way to take a
message while its TUI stays the user's: the user can still type to any agent.

## 1. Transports

`MissionTransport`, from the most to the least wanted:

- **push**: the agent's own interface starts the message, idle or mid-turn
  (Codex app-server `turn/start` / `turn/steer`; agy's local RPC). Options only.
- **hook**: a hook of the agent takes it from its mailbox (below).
- **queue**: the agent's own queue starts it once its turn ends
  (`codex queue --thread`, #664).
- **typed**: the paste and Enter of today, kept as the fallback.

`MissionDeliveryPolicy.transport(carriers:typingRefused:)` takes the most
wanted transport the recipient has now, and typing only when none other does
and its prompt takes it (the guards of today decide `typingRefused`).

| Agent | Carrier | Idle | Mid-turn | Resume |
|---|---|---|---|---|
| Claude Code 2.1.331 | hook: `asyncRewake` on SessionStart and Stop | wakes the model | absorbed at the next model call | SessionStart "resume" |
| Codex 0.171 | queue (today); push via app-server (option) | yes | after the turn; push steers | `codex resume` |
| agy 1.5.15 | hook: PreInvocation `injectSteps` + Stop `continue`; `-i` at relaunch | typed | next model call | `-i` |

A draft in the prompt stays untouched by every carrier but typing.

## 2. Mailbox

`MissionMailbox` keeps the letters waiting for a conversation's hook (a Claude
session, a Codex thread, an agy conversation id):

    <root>/<conversation>/waiting/<event id>.json
    <root>/<conversation>/claimed/<claimed ms>-<event id>.json

- `post` writes the letter under `.drafts`, then renames it into `waiting`
  without replacing anything: a reader never sees half a letter, and a letter
  waiting or claimed (not yet forgotten) isn't posted twice.
- `claim` (the hook) reads each waiting letter, then renames it into
  `claimed`; a letter another claim took is skipped, and one it can't read
  stays waiting, for typing.
- `retract` (Nirux, before typing) renames it out of `waiting`; false means
  a hook has it (or it never was there), and Nirux doesn't type it. Any other
  failure throws, so a disk error never reads as "a hook has it".
- `claims` lists what hooks took, for Nirux to record the delivery (today's
  `parentTypedAt`); `forget` drops a recorded one.

rename(2) moves each letter once, so it is delivered once: by a hook, or by
typing after a retract. Letters go by conversation, so a resumed session gets
its own, and a new one never gets another's (the "restarted" rule of today).

## 3. Plan

1. NiruxCore: transports, policy, mailbox, tests. No caller.
2. Claude: a waiter hook (`--hook claude --mission-wait`, under an existing
   hook kind) with `asyncRewake`, `timeout: 86400` and `rewakeSummary` in the
   space's `claude-settings.json`; claims recorded in `MissionStore`; typing
   only when no waiter is armed. The pilot. A claim is the hook's, not yet
   the agent's: record it as delivered once the agent shows the turn it
   started (the woken turn's Stop), and post a claim whose session ended first
   again.
3. After a week of the pilot: "Type it now" (#635) and the 20 s hand-off (#483)
   only without a waiter.
4. agy: PreInvocation + Stop `continue` capped by `executionNum`, pending
   letters in `-i` at relaunch; an idle agy stays typed.
5. Options: Codex app-server (`turn/steer`), agy's RPC for an idle agy.

## 4. Claude Code (PR 2)

- **The waiter.** The space's `claude-settings.json` (ClaudeSpaceSettings) runs
  `Nirux --hook mission-wait <state>/mission-mailbox` on SessionStart and Stop,
  with `asyncRewake`, `timeout: 86400`, `rewakeSummary` and `rewakeMessage`.
  It goes in only when every `claude` a terminal could run is 2.1.331 or later
  (`MissionWaitHook.claudeVersion`): one that ran it in the foreground would
  hold each session start for a day. An older Nirux reads `mission-wait` as a
  hook kind it doesn't know, and exits.
- **One waiter per session.** `MissionMailbox.arm` takes the session's lock
  (flock), and a second waiter, as each turn end starts one, leaves at once.
  `isArmed` is that lock, seen from Nirux. The waiter waits on the session's
  `waiting` folder (kqueue) and on its `claude` (`NOTE_EXIT`), claims what
  comes, prints it to stderr and exits 2.
- **Nirux's side** (`NiruxShellView.leaveToHook`,
  `MissionDeliveryPolicy.hookStep`): a message for a `claude` posts to the
  conversation that `claude` confirmed, while a waiter waits there. A posted
  letter whose waiter left is taken back and typed. A claim counts as
  delivered (`markTyped`) at the next main-thread Stop of its session; a
  SessionEnd first frees it to go again. At launch, claims count as
  delivered and waiting letters are taken back (`settleMissionMailbox`).
- **What stays typed:** a `tell` that starts with a slash command, Lead
  notices, PR follow-ups, and every message for a session with no waiter.
- **Trust.** Claude Code shows the message to the model as a system
  notification. Without context, Haiku 5.5 refused to act on one ("it didn't
  come from you"). With a handover that says Nirux brings messages in through
  its hook, it acted every time, with or without `rewakeMessage`. The
  handover (`typedAnswerMission`) and the task and Lead instructions
  (NiruxMCPServer) say so. A hook-borne `tell` names its sender
  (`MissionPromptText.hookText`).

Proved on 2026-11-24 with the built binary and Claude Code 2.1.331 (Haiku 5.5)
in a PTY, `env -i` and `--setting-sources project`. Idle: woke the model.
Mid-turn, posted during a `sleep 15`: in the same turn's answer. A draft
stayed in the prompt. Posted while closed: delivered on `claude --resume`.
One waiter per session after several turns. No waiter left after `/exit`.

## Not in this version

- Claude channels (`--channels`): a development channel shows a warning
  dialog at every launch, and an approved one needs a marketplace plugin on
  Anthropic's allowlist.
- Claude's cross-session socket (`messagingSocketPath`): a private protocol
  with tokens.
