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

// Single-instance guard: macOS session restoration, the SMAppService login
// item, and a legacy LaunchAgent that exec's the binary directly can each
// launch the app at login, leaving two status items. LSMultipleInstancesProhibited
// only stops LaunchServices-routed duplicates, so a direct-exec launch bypasses
// it entirely and a runtime guard is still needed.
//
// The previous guard used NSRunningApplication.runningApplications(withBundleIdentifier:)
// with a lowest-PID tie-break, but that has a confirmed race: a process appears
// in that list only after its own NSApplication registers with LaunchServices.
// Two instances launched in the same window both run this check *before* either
// has created NSApplication, so both see an empty list, neither yields, and both
// survive — the PID tie-break never engages because the twins are mutually
// invisible during the pre-registration window.
//
// Instead, acquire an exclusive advisory file lock before touching NSApplication.
// flock(2) locks are owned by the open file description and released automatically
// on process death — including crashes — so there is no stale-lock to clean up.
// Two processes racing for LOCK_EX | LOCK_NB are serialized by the kernel: exactly
// one acquires it, the loser gets EWOULDBLOCK and exits quietly. The fd is
// intentionally never closed; it must stay open for the whole process lifetime to
// hold the lock. If the lock file cannot even be created (exotic filesystem
// failure) we fall back to the old NSRunningApplication check rather than refuse
// to launch, so an I/O error can't brick the app.
func acquireSingleInstanceLock() -> Bool {
    let fm = FileManager.default
    guard let support = try? fm.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    ) else {
        return false // no support dir → caller falls back
    }
    let dir = support.appendingPathComponent("TokenBar", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let lockPath = dir.appendingPathComponent("single-instance.lock").path

    // Deliberately leaked fd: held open for the process lifetime so the lock
    // outlives this function. Do not close it.
    let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else {
        return false // couldn't create/open lock file → caller falls back
    }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        // Another instance holds the lock. Exit quietly like the old guard.
        exit(0)
    }
    return true // lock held; we are the sole instance
}

if !acquireSingleInstanceLock() {
    // Fallback path only: the lock file could not be created. Use the best-effort
    // NSRunningApplication check (racy, but better than nothing) so a lock-file
    // I/O failure degrades gracefully instead of bricking startup.
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
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
