# Auth Expiry Badge

Status: validated by the user on 2026-10-02, implemented.

In three weeks the user typed `aws sso login` by hand 7 times, each time after
an agent hit an expired AWS SSO session mid-task. Nirux can say so before the
next agent trips on it.

## Shape

- **A title-bar badge**, "AWS SSO expired", left of the keep-awake cup and
  built the same way (`AWSSSOIndicator`). Hidden while every session works.
- **A click shows the command, types nothing**: a menu with
  `! aws sso login --sso-session NAME` and Copy Command. The `! ` runs it
  from Claude Code's prompt, and is a no-op in a shell.
- **Which sessions**: each `[sso-session NAME]` of `~/.aws/config` that a
  profile uses. Its cache is `~/.aws/sso/cache/<sha1(NAME)>.json`, the AWS
  CLI's naming. A missing file shows nothing (never logged in, or logged out
  on purpose). No AWS CLI in `/opt/homebrew/bin` or `/usr/local/bin`, no badge.

## Detection

The cache's `expiresAt` is the access token's, about an hour. With an
sso-session the CLI refreshes it on use, from the refresh token, while the
session lasts ([botocore `tokens.py`](https://github.com/boto/botocore/blob/develop/botocore/tokens.py)).
The session's own end is written nowhere. So a past `expiresAt` doesn't mean a
login is needed, and the file alone can't warn ahead of time.

- **The file says when to look.** Once `expiresAt` is within the CLI's 15
  minute refresh window, Nirux runs `aws sts get-caller-identity --profile
  <first profile of the session>`. The CLI refreshes if it can. An error saying
  "expired" turns the badge on. Any other failure (offline) doesn't.
- **Then it waits for a login.** An expired session isn't probed again while
  its file is unchanged. `aws sso login` rewrites it.
- **When**: at launch, on app activation, and every 5 minutes. A check reads
  `~/.aws/config` and one small file per session. The probe, a network call,
  runs about once an hour, since its own refresh keeps the token fresh for
  the next hour. Offline, it runs at each check.
- **What is read**: only `expiresAt`, decoded with a struct that has no other
  field. Only the probe's error text is searched, and nothing of it is kept.
  Nirux never reads, logs or persists a token. A session name that isn't a
  plain word is shell-quoted in the command, so a pasted command runs nothing
  else.
- **Not ahead of time.** The badge says a login is needed now, not 10 minutes
  before: a failed refresh shows only once the token is gone.

## Dropped

- **`gh auth status`**: a `gh` OAuth token doesn't expire on a timer. The check
  is a network call, and its output names the token. Not worth it.
- **MCP OAuth**: Claude Code exposes no documented passive signal (not
  verified against its source, which isn't public). `claude mcp list`
  connects to every server (it starts the stdio ones), and the tokens likely sit in
  Claude Code's keychain item, which Nirux must not read. Nothing reliable,
  so nothing.
