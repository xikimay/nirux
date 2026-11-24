# Mission Delivery

> **Design record:** how Mission messages reach an agent without typing them into its terminal. PR 1 adds the NiruxCore primitives; nothing calls them yet.

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

`MissionMailbox` keeps the letters for a conversation's hook (a Claude
session, a Codex thread, an agy conversation):

    <root>/<conversation>/ids/<id>                 the letter is here
    <root>/<conversation>/waiting/<id>.json        for its hook
    <root>/<conversation>/claimed/<ms>-<id>.json   its hook took it
    <root>/<conversation>/owed/<id>.json           Nirux took it back to type it

- `post` creates the id's marker exclusively (O_EXCL), then writes the letter
  under `.drafts` and renames it into `waiting`: a reader never sees half a
  letter, and a letter of that id waiting, claimed or owed isn't posted
  again, whatever a hook does meanwhile. A post that fails leaves nothing
  behind and throws, for Nirux to type it.
- `claim` (the hook) renames each waiting letter into `claimed`; a letter
  another claim took is skipped, and one it can't read stays waiting.
- `retract` (Nirux, before typing) says one of three things. `.retracted`:
  the letter moved into `owed`, where it stays until Nirux typed it
  (`markTyped`), so a crash in between loses nothing (`owed` lists it at the
  next launch). `.claimed`: a hook has it, and Nirux doesn't type it.
  `.unknown`: nothing of that id, so it was never posted, a post failed, or
  Nirux is done with it, and Nirux's own record decides. Any other failure
  throws, so a disk error never reads as a hook's.
- `claims` lists what hooks took, for Nirux to record the delivery (today's
  `parentTypedAt`); `forget` drops a recorded one, and its marker.
- `sweep` drops what is a day old (`lifetime`, like typed Missions): letters
  waiting or owed, with their text, and claims. Then a draft or a marker
  with no letter a crash left a minute ago, and folders once empty (rmdir,
  which leaves one something just went into). `claim` creates nothing when
  nothing waits.

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

## Not in this version

- Claude channels (`--channels`): a development channel shows a warning
  dialog at every launch, and an approved one needs a marketplace plugin on
  Anthropic's allowlist.
- Claude's cross-session socket (`messagingSocketPath`): a private protocol
  with tokens.
