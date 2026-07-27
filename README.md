# Peeksy

**Mission control for your AI agents.**

Peeksy is a background macOS app that sits a small pill next to your MacBook's
notch. The colour is the most urgent thing happening across every Claude Code
session you have running. Hover to see the list, click a row to jump straight
into that session.

<img src="assets/screenshot.png" alt="Peeksy expanded beside the notch, showing one working session" width="100%">

When you run several agents at once, it is easy to lose track of which one
finished, which is still thinking, and which has been waiting on a permission.
Peeksy keeps that visible without another window to watch.

## Requirements

- macOS 14 or later
- [Claude Code](https://claude.com/claude-code)
- A Swift toolchain (Xcode or the Command Line Tools). You build it yourself;
  see [Installing](#installing).

Designed for Macs with a notch. There is a fallback for displays without one
(the pill sits at the right of an ordinary menu-bar band), but that path is
untested, as is multi-display. See [Known gaps](#known-gaps).

## Installing

There are no prebuilt downloads yet. An ad-hoc signed app hits Gatekeeper when
downloaded, and the signature changes on every build, which silently revokes
Automation permission on every update. Building it yourself avoids both. See
[Signing](#signing).

```sh
git clone https://github.com/jayintheday/peeksy.git
cd peeksy
./scripts/build_app.sh --install      # → ~/Applications/Peeksy.app
open ~/Applications/Peeksy.app
```

The pill should appear next to the notch. Then do these two things once:

1. **Register the hook.** Hover the pill and click *Install the hook…*. You
   get a unified diff of the exact change before anything is written. Or from
   the command line:

   ```sh
   scripts/install_hook.sh              # preview, then ask before writing
   ```

2. **Grant Automation.** Click any session row. macOS will ask for permission
   to control Terminal. That is what raises the right tab. Nothing else is
   requested.

New sessions appear as soon as Claude Code fires its next hook event. Sessions
already running when you launched are found by a `ps`/`lsof` scan and shown as
`waiting…` until a hook event confirms what they are doing.

### Launch at login, and quitting

Peeksy has no Dock icon and no menu-bar menu. Both controls live on the gear
icon at the right of the panel header:

- **Launch at login** is off by default. Turn it on and macOS starts Peeksy for
  you. It also appears in System Settings → General → Login Items; turning it
  off there wins.
- **Quit** stops the app. The socket is unlinked on the way out, so the hook
  drops back to its fast path and Claude Code behaves as if Peeksy had never
  been installed.

To start again: `open ~/Applications/Peeksy.app`, or turn on launch at login.

## Privacy

Everything is local. There is no network code and no telemetry.

| It reads | Why |
|---|---|
| Claude Code hook payloads | over a Unix domain socket (`0600`, in a `0700` directory), not a TCP port |
| `~/.claude/projects/…/*.jsonl` | just enough of the tail to read the session's own task title |
| `ps` / `lsof` | to find sessions that were already running at launch |
| Terminal, via AppleScript | only to raise the tab you clicked |

It writes to exactly two places: its own folder in
`~/Library/Application Support/Peeksy`, and (only when you approve the diff) an
appended hooks block in `~/.claude/settings.json`. That file often carries
other tools' hooks, so the installer is append-only, backed up, atomic, and
preview-gated. It never rewrites what it did not add.

**The hook fails open.** It always exits 0, never prints to stdout, and its
first line checks for the socket. When Peeksy is not running it costs zero
forks, and Claude Code cannot tell it exists.

## Session states

| State | Colour | Means |
|---|---|---|
| **needs attention** | red | a permission prompt or an idle prompt is waiting on you |
| **stale** | orange | was working, then went quiet for 10 minutes |
| **working** | green | mid-turn: running a tool, or thinking |
| **done** | cyan | the turn finished |
| **idle** | grey | started, nothing yet |
| *unknown* | dim grey | found by the launch scan; no hook has confirmed it |

The pill shows one colour for possibly many sessions: the most urgent one
present. `stale` outranks `working`, because a session quiet for ten minutes is
likelier to want you than one mid-turn. When anything needs attention the whole
pill gets a red outline, so a small dot next to the notch is harder to miss.

Almost nothing moves. The pill's dot breathes only while something is genuinely
working, and a row's orb spins under the same rule. Both stop when the panel is
off screen or Reduce Motion is on.

## Troubleshooting

```sh
scripts/doctor.sh          # sessions, socket, hook registration, TCC state
```

**Clicking a row does nothing.** Automation permission. This bites after a
rebuild: an ad-hoc signature changes on every build, so macOS silently denies
Apple events with `-1743` and shows no prompt.

```sh
tccutil reset AppleEvents com.vijaypatel.peeksy
```

Then click a row once to get a fresh prompt.

**No sessions ever appear.** Check the hook is registered and the app is
running. `scripts/doctor.sh` answers both. The hook is silent on every failure,
so it will never tell you itself.

**You would rather edit `settings.json` by hand.**
`Peeksy --print-hook-json` prints just Peeksy's block. Merge its nine entries
into your `hooks` object. It never reads your settings file, so it still works
when that file is missing or half-broken, and it is safe to paste into a bug
report.

**You want to see what an install would change.**
`scripts/install_hook.sh --dry-run` shows a unified diff against your real file.

## Uninstalling

```sh
scripts/install_hook.sh --uninstall-hook    # round-trips settings.json byte-identically
rm -rf ~/Applications/Peeksy.app
rm -rf ~/Library/Application\ Support/Peeksy
```

If you turned on launch at login, quit the app before deleting it, or remove it
from System Settings → General → Login Items.

## How it works

```
claude ──hook──▶ peeksy-hook.sh ──POST──▶ unix socket ──▶ EventRouter
                                                                   │
                                                          ClaudeCodeAdapter
                                                                   │
                                                            SessionRegistry
                                                          (a struct, not an actor)
                                                                   │
                                                        SessionStore ──▶ the pill
```

The codebase is split hard at AppKit:

- **`Sources/PeeksyCore`** — Foundation only. The state machine, the wire
  format, the geometry maths, the hover state machine, the settings merge, the
  orb. All pure value types, all tested.
- **`Sources/Peeksy`** — AppKit and SwiftUI. Thin shells over the above.

Tests only depend on Core, which is why logic that could be wrong lives there.
Adding a second agent runtime is an `AgentAdapter` conformance and an
`AgentSource` case. A mock adapter in the test suite speaks a completely
different wire format in 25 lines.

```sh
swift build && swift test      # 508 tests, 50 suites
```

The app icon is generated, not committed: `assets/AppIcon.png` is the 1024×1024
source and `build_app.sh` turns it into `AppIcon.icns` whenever it is newer. To
use your own, replace the PNG. It must be 1024×1024 and already the rounded-rect
shape with transparent corners, because macOS does not mask an `.icns`.

Useful flags on the built binary:

```sh
Peeksy --doctor        # diagnostics
Peeksy --geometry      # notch rects, and the layout invariant
Peeksy --menubar       # who else is in the menu bar, and whether we fit
Peeksy --login-item    # launch-at-login status (read-only)
Peeksy --slice         # plain-window UI, for when the notch is in the way
Peeksy --orb-lab       # the orb tuning harness
```

## Known gaps

Honest ones, all reproducible:

- **Multi-display and non-notched displays are untested.**
- **Full-screen apps and auto-hiding menu bars are unverified** since the app
  stopped using a status item as its anchor.
- **Cursor and VS Code are not user-confirmed.** Zed's integrated terminal is.
  Zed's agent panel is not.
- **Claude Desktop cannot be supported.** Its agent runs with a per-conversation
  config root that has no `settings.json`, so no hook can ever fire.
- `CGWindowList` reports the panel at ~0.903 scale for the first 10–30 seconds
  after launch and then corrects itself. Pre-existing, not caused by any current
  code. It only matters because window metadata is this repo's substitute for a
  screenshot.

## Signing

The app is **ad-hoc signed** (`codesign --sign -`). That is correct for a build
you made on your own machine, and wrong for anything you download:

- Gatekeeper blocks an ad-hoc signed app that arrives from the internet.
- The signature's `cdhash` changes on **every build**, and TCC keys Automation
  permission to the `cdhash`, so a distributed update would silently break
  click-to-focus with no prompt and no error.

Proper Developer ID signing plus notarisation would fix both. It is not done
yet because it costs $99/year and nobody has asked. The Mac App Store is out of
reach for this app either way: AppleScript-driven terminal focus and process
scanning are disqualifying.

## Contributing

Issues and PRs welcome. Two things to know:

1. **Put logic in `PeeksyCore` as pure value types.** The test target only
   depends on Core.
2. **Never run `screencapture`.** Verify window geometry with
   `CGWindowListCopyWindowInfo` metadata instead. `--geometry` and `--menubar`
   print everything you need.

## Licence

MIT. See [LICENSE](LICENSE).

This project ports and adapts code from two others, both MIT, both credited
file-by-file in [NOTICE](NOTICE):

- [open-focus](https://github.com/fillsoko/open-focus) — notch geometry, the
  panel configuration, the app-bundle build script
- [thinking-orbs](https://github.com/Jakubantalik/thinking-orbs) — the session
  row orbs, ported from TypeScript/canvas to Swift/SwiftUI `Canvas`
