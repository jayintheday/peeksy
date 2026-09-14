# Changelog

## Unreleased

### Added

- `--doctor` reads Codex's hook trust record (`[hooks.state]` in `$CODEX_HOME/config.toml`) and reports, per event, whether Peeksy's hook is trusted, disabled, or waiting for review in `/hooks`. Registration alone was already reported; this is the line that says whether Codex will actually run it.

### Changed

- README and the install sheet now spell out the three reasons a Codex session shows nothing after install: untrusted hooks, a session started before the registration, and a session trusted mid-run that has not yet had a prompt.

## 0.2.0 — 2026-09-14

Peeksy now monitors Claude Code and Codex sessions together.

### Added

- Codex lifecycle hooks for working, permission-needed, done, interrupted, and ended sessions.
- Discovery of existing local Codex terminal sessions, with provisional status until a hook arrives.
- Agent selection in hook setup and `--agent codex` for CLI install, preview, JSON output, and uninstall.
- Custom `CODEX_HOME` support and independent hook installation for each agent.
- Codex diagnostics, real-socket bridge tests, and temporary-file installer tests in CI.

### Changed

- Session storage and UI/cache identities include the agent source to prevent cross-agent collisions.
- Codex turn tracking rejects delayed progress after completion and preserves attention during unrelated parallel tool activity.
- Shared Codex hosts use inactivity cleanup instead of treating one live process as proof that every conversation is active.
- Both hook scripts are packaged and checked by CI. Existing Claude installer commands keep their defaults.

### Setup and compatibility

- Requires macOS 14 or later. Codex CLI 0.154.0 is the integration baseline.
- After installing Codex hooks, review and trust them using `/hooks` in Codex. Registration does not bypass trust or administrator policy.
- Local use was confirmed by the maintainer. IDE/desktop host coverage, exact conversation navigation, and remote/cloud discovery are not established.
- Codex rows use project and tool information rather than transcript-derived titles. Hosted tool activity and idle notifications are not fully covered.
- This is a source-only release. Build locally; no notarized app download is provided.

### Upgrading

Quit Peeksy, update the checkout, run `./scripts/build_app.sh --install`, and
launch `~/Applications/Peeksy.app`. Open the gear menu → **Agent hooks…** to add
Codex. Existing Claude hooks remain independent. A rebuild may require granting
Terminal Automation permission again; see the README troubleshooting section.
