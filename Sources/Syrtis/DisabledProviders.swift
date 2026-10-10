import Foundation
import TokenBarCore

/// The quota providers the user has switched off in Settings, and the seam that
/// hands that list to the FFI registry.
///
/// **This is not a card-visibility setting.** Hiding a card would leave the
/// fetch running, and the fetch is the expensive part: `tb_agent_usage` joins
/// every provider and returns only when the slowest finishes, so one slow
/// provider delays every other card. The Antigravity CLI fallback is the case
/// that made this worth a setting — with no Antigravity IDE installed it spawns
/// a ~170MB binary on every publication, measured at 2.6-4.6s, and the Claude
/// limits card could not appear until that returned. Switching a provider off
/// here stops the future being created at all.
///
/// Stored as a comma-separated raw string, the same shape
/// `tokenbar.views.hidden` uses, so a `@AppStorage` binding in Settings is the
/// whole UI contract.
enum DisabledProviders {
    static let storageKey = "tokenbar.providers.disabled"

    /// Every provider the core can fetch, in the order Settings lists them.
    /// Mirrors `disabled_providers::KNOWN_PROVIDERS`; an id absent from the
    /// Rust list is refused by the setter rather than silently stored.
    static let known: [String] = [
        "claude", "codex", "antigravity", "copilot", "grok", "grok-bot", "kiro", "opencode-go",
    ]

    /// Display name for a provider row. Deliberately the vendor's own casing
    /// rather than a localized string: these are product names.
    static func label(_ id: String) -> String {
        switch id {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "antigravity": return "Antigravity"
        case "copilot": return "GitHub Copilot"
        case "grok": return "Grok"
        case "grok-bot": return "Grok Bot"
        case "kiro": return "Kiro"
        case "opencode-go": return "OpenCode Go"
        default: return id
        }
    }

    /// Parse the stored raw value. Unknown ids are dropped here as well as in
    /// Rust: a value written by a newer build that knew a provider this one
    /// does not must not disable something at random.
    static func parse(raw: String) -> [String] {
        var seen = Set<String>()
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { known.contains($0) && seen.insert($0).inserted }
    }

    static func current() -> [String] {
        parse(raw: UserDefaults.standard.string(forKey: storageKey) ?? "")
    }

    /// The exact wire shape the setter expects: a JSON array of ids. An empty
    /// selection is an explicit `[]` rather than an omitted call, because the
    /// setter is full-replace and `[]` is how a provider gets re-enabled.
    static func payloadJSON(_ ids: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: ids),
              let json = String(data: data, encoding: .utf8)
        else { return "[]" }
        return json
    }

    /// Last value this process installed. The Rust registry starts empty every
    /// launch, so a persisted marker cannot answer "is the core already holding
    /// this"; only an in-process record can.
    @MainActor private static var lastInstalled: String?

    /// Push the stored selection into the core. Safe to call on every launch
    /// and on every Settings write.
    ///
    /// Failure is swallowed on purpose, matching `ClaudeExtraRoots.apply`: a
    /// refused registry install must not take down launch, and the consequence
    /// is a provider that keeps being fetched — slower, never wrong.
    @MainActor
    static func apply() {
        let ids = current()
        let json = payloadJSON(ids)
        let isFirstInstall = lastInstalled == nil
        let changed = lastInstalled != json
        lastInstalled = json
        _ = try? TBCore.setDisabledProviders(json: json)
        // A first install of an empty selection writes the state the registry
        // already had, so nothing needs waking. Without this, every launch
        // would invalidate the throttle and restart the poll for no change.
        guard changed, !(isFirstInstall && ids.isEmpty) else { return }
        Task { @MainActor in
            // Same order and same reason as the account registry: drop the
            // throttled payload BEFORE waking the poll, or the woken fetch is
            // answered from a payload built for the provider set that just
            // changed — and the user waits out the 50s floor watching a card
            // they just switched off.
            await AgentUsageThrottle.shared.invalidate()
            ClaudeExtraRoots.RegistryChange.signal()
        }
    }

    /// Test seam: install an explicit selection without touching UserDefaults
    /// or the in-process record used by `apply`.
    static func installForTesting(_ ids: [String]) throws -> DisabledProvidersResult {
        try TBCore.setDisabledProviders(json: payloadJSON(ids))
    }

    /// Test seam: forget what this process installed, so a suite can drive
    /// `apply`'s first-install branch more than once.
    @MainActor
    static func resetInstalledRecordForTesting() {
        lastInstalled = nil
    }
}
