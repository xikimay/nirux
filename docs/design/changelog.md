# Changelog and What's New

> **Design record:** built in the Changelog UI series (#889, #892 and the
> PRs after them). The study the user approved on 2026-11-25 compared three
> directions and picked B, "a card and a journal".

## Decided

- **One file.** The nightly publishes `changelog.json` beside
  `appcast.xml`: one entry per pull request that landed on main (a merge
  train counts through the pull requests it carries), with its title, its
  Why (the body's "## Why", else its first paragraph), a kind and the build
  that shipped it. 90 days are kept. The release body lists the same
  entries.
- **Kinds.** A label named after a kind wins (`internal` first, then
  `new`). Otherwise a test/, ci/, refactor/, chore/ or dependabot/ branch,
  or a pull request that touches nothing the app is built from, is Under the
  hood; a fix/ branch is Fixed; anything else is Better. The Lead sets the
  `new` and `internal` labels before `queue_merge`; a forgotten label
  only leaves a feature under Better.
- **Never block a nightly.** The changelog step runs on its own, five
  minutes at most, and its failure only leaves the release listing commits.
  Each file says which commit of main it reaches, and the next nightly
  continues from the newest dated release's copy (else the rolling one), so
  a failed or cancelled run loses no pull request and never starts the
  history over.
- **Three moments, three surfaces.**
  - Before installing: the status bar counts the changes the update brings
    since the running build ("Update ready · 9 changes"); its popover lists
    them, with Install and Relaunch. Once downloaded, Nirux takes the
    install from Sparkle (`willInstallUpdateOnQuit`), so no second alert
    follows; it still installs on quit, and Sparkle looks for no newer build
    until then.
  - After the relaunch: a card over the bottom right of the work lists what
    the builds since the last one seen brought, from the changelog fetched
    since launch. It stays until Dismiss or See All, never takes the
    keyboard, and has no motion when Reduce Motion or Animate the interface
    is off. Opening What's New counts as seen. The last build seen lives in
    the state folder (`whats-new-seen`).
  - On demand: Help › What's New and the ⌘P command open a window, each
    nightly's entries under its build, newest first, searchable, with the
    internal work behind a checkbox.
- **Task rows.** A merged pull request of the nightlies' repository says
  "in your build" or "in a newer nightly" once the changelog lists it.
- **Left out:** notes in Sparkle's own dialog (rarely seen with automatic
  installs), a line on the Lead's row, the entries as a ⌘P section, a card
  per nightly.
