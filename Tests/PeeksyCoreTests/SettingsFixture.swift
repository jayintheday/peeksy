import Foundation

/// A settings file with the SHAPE of the real one.
///
/// Not a copy of the user's file — theirs is deliberately not in this repo, for
/// the same reason `CLAUDE.md` and `LEARNINGS.md` are gitignored. What matters
/// for the merge is the shape, and every awkward feature of the real file is
/// reproduced here:
///
///  * 13 top-level keys, 9 of which this app has never heard of and must carry
///    through untouched;
///  * 11 hook events holding 18 groups from two OTHER tools;
///  * `Notification` where one foreign group has `matcher: "*"` and the other
///    has none, so "the matcher is a property of the event" is provably false;
///  * `SubagentStop` and `PreCompact`, events we never register — controls that
///    must come out the far side byte-identical;
///  * `PostToolUseFailure` and `PermissionRequest` with exactly one foreign
///    group, so appending to a short array is covered as well as a long one.
enum SettingsFixture {
    static let toolOne = "/Users/example/.toolone/hooks/notify.sh"
    static let toolTwo = "/Users/example/Code/tooltwo/hooks/tooltwo-hook.sh"

    /// Where a real install would point.
    static let ourCommand = "/Users/example/Library/Application Support/Peeksy/peeksy-hook.sh"

    static let json = """
    {
      "permissions": { "defaultMode": "auto" },
      "model": "opus[1m]",
      "hooks": {
        "SessionStart": [
          { "hooks": [ { "type": "command", "command": "\(toolOne)" } ] },
          { "hooks": [ { "type": "command", "command": "\(toolTwo)" } ] }
        ],
        "SessionEnd": [
          { "hooks": [ { "type": "command", "command": "\(toolOne)" } ] },
          { "hooks": [ { "type": "command", "command": "\(toolTwo)" } ] }
        ],
        "UserPromptSubmit": [
          { "hooks": [ { "type": "command", "command": "\(toolOne)" } ] },
          { "hooks": [ { "type": "command", "command": "\(toolTwo)" } ] }
        ],
        "PreToolUse": [
          { "matcher": "*", "hooks": [ { "type": "command", "command": "\(toolOne)" } ] },
          { "matcher": "*", "hooks": [ { "type": "command", "command": "\(toolTwo)" } ] }
        ],
        "PostToolUse": [
          { "matcher": "*", "hooks": [ { "type": "command", "command": "\(toolOne)" } ] },
          { "matcher": "*", "hooks": [ { "type": "command", "command": "\(toolTwo)" } ] }
        ],
        "PostToolUseFailure": [
          { "matcher": "*", "hooks": [ { "type": "command", "command": "\(toolTwo)" } ] }
        ],
        "Stop": [
          { "hooks": [ { "type": "command", "command": "\(toolOne)" } ] },
          { "hooks": [ { "type": "command", "command": "\(toolTwo)" } ] }
        ],
        "SubagentStop": [
          { "hooks": [ { "type": "command", "command": "\(toolOne)" } ] }
        ],
        "Notification": [
          { "matcher": "*", "hooks": [ { "type": "command", "command": "\(toolOne)" } ] },
          { "hooks": [ { "type": "command", "command": "\(toolTwo)" } ] }
        ],
        "PreCompact": [
          { "hooks": [ { "type": "command", "command": "\(toolOne)" } ] }
        ],
        "PermissionRequest": [
          { "matcher": "*", "hooks": [ { "type": "command", "command": "\(toolTwo)" } ] }
        ]
      },
      "statusLine": { "type": "command", "command": "bash /Users/example/.claude/statusline-command.sh" },
      "enabledPlugins": {
        "swift-lsp@claude-plugins-official": true,
        "some-plugin@some-marketplace": true
      },
      "extraKnownMarketplaces": {
        "some-marketplace": { "source": { "source": "github", "repo": "example/some-marketplace" } }
      },
      "effortLevel": "xhigh",
      "autoDreamEnabled": true,
      "skipDangerousModePermissionPrompt": true,
      "skipWorkflowUsageWarning": true,
      "agentPushNotifEnabled": true,
      "skipAutoPermissionPrompt": true,
      "feedbackSurveyState": { "lastShownTime": 1754472892108 }
    }
    """

    static var object: [String: Any] {
        // Force-unwrapped on purpose: a fixture that does not parse is a broken
        // test file, not a runtime condition worth threading an error through.
        let data = Data(json.utf8)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    /// Total foreign groups across every event. Asserted rather than assumed, so
    /// editing the fixture cannot silently weaken the preservation tests.
    static let foreignGroupCount = 18
    static let topLevelKeyCount = 13
    static let hookEventCount = 11
}
