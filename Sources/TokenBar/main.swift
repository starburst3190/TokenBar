import AppKit

// Entry point. `--smoke` keeps the Phase 1 CLI bridge check available for CI,
// `--selftest` runs the TokenBarCore logic checks; anything else boots the
// menu-bar app (no storyboard, no .app bundle yet).

if CommandLine.arguments.contains("--smoke") {
    exit(Smoke.run())
}
if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
