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

// Single-instance guard: macOS session restoration and the SMAppService login
// item can both launch the app at login, leaving two status items. The bundle
// also sets LSMultipleInstancesProhibited, which stops LaunchServices-routed
// duplicates; this runtime check covers direct executable launches (and older
// installed bundles without the key). The lowest PID wins the tie so two
// instances that see each other simultaneously can't BOTH exit — without a
// deterministic tie-break, near-simultaneous launches each observe the other
// already registered and mutually quit, leaving no instance at all.
if let bundleId = Bundle.main.bundleIdentifier {
    let yieldsToOther = NSRunningApplication
        .runningApplications(withBundleIdentifier: bundleId)
        .contains {
            $0 != .current && $0.processIdentifier < ProcessInfo.processInfo.processIdentifier
        }
    if yieldsToOther {
        exit(0)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
