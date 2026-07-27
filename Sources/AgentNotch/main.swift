import AgentNotchCore
import AppKit
import Foundation

// FocusCLI owns the `agent-notch --focus …` / `--doctor` subcommands. It returns
// an exit code when it recognised the argv and nil when it did not, in which
// case we are the app. It has to run FIRST and it has to run BEFORE any UI
// exists: a `--doctor` invocation must never start a server, open a panel, or
// register an app with the window server.
if let code = FocusCLI.run(CommandLine.arguments) { exit(code) }

let app = NSApplication.shared
let delegate = AppDelegate(mode: FocusCLI.launchMode(CommandLine.arguments))
app.delegate = delegate
// .accessory: no Dock icon, no app menu. The bundle also sets LSUIElement, but
// this makes a `swift run` from a terminal behave the same as the bundle.
app.setActivationPolicy(.accessory)
app.run()
