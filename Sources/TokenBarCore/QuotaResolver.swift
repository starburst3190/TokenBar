import Foundation

/// Picks which quota window the menu bar displays. The canonical selection
/// string is `"auto"` or `"<clientId>|<cardId>"`. A legacy label in the
/// second component is migrated when the current payload makes it unique.
public enum QuotaResolver {
    public static let auto = "auto"

    /// Builds the canonical persisted selection for one quota card.
    public static func selection(clientId: String, cardId: String) -> String {
        "\(clientId)|\(cardId)"
    }

    /// Canonicalizes a persisted selection against the current payload.
    ///
    /// Empty and `auto` selections normalize to `auto`. Before a payload is
    /// available, a well-formed explicit selection is preserved so a refresh
    /// cannot erase an otherwise valid persisted choice. Once a payload exists,
    /// exact card IDs win and a unique legacy label is migrated. A well-formed
    /// unmatched selection remains explicit: the payload can be partial during a
    /// provider failure, so silently changing it to Auto would show another
    /// provider instead of letting callers retain the selected source's last-good
    /// value.
    public static func canonicalSelection(
        payload: AgentUsagePayload?, selection: String
    ) -> String {
        guard let parsed = parseExplicitSelection(selection) else { return auto }
        guard let payload else { return selection }
        guard let agent = payload.agents.first(where: { $0.clientId == parsed.clientId }) else {
            return selection
        }

        let windows = agent.uniqueCardWindows
        if let exact = windows.first(where: { $0.cardId == parsed.value }) {
            return Self.selection(clientId: agent.clientId, cardId: exact.cardId)
        }

        let labelMatches = windows.filter { $0.label == parsed.value }
        guard labelMatches.count == 1, let migrated = labelMatches.first else { return selection }
        return Self.selection(clientId: agent.clientId, cardId: migrated.cardId)
    }

    /// `excluding` is the set of client ids to skip in AUTO mode only (the
    /// user's tab-hidden ∪ limits-hidden clients) — so the menu-bar quota can't
    /// surface a client the popover hides. An EXPLICIT `clientId|cardId`
    /// selection is always honored, even for an excluded client (the user
    /// deliberately picked it as the tray source). Empty set = pre-hide
    /// behavior, byte-identical.
    public static func resolve(
        payload: AgentUsagePayload?, selection: String, excluding: Set<String> = []
    ) -> (clientId: String, window: UsageWindow)? {
        guard let payload else { return nil }
        let canonical = canonicalSelection(payload: payload, selection: selection)
        if canonical == Self.auto {
            return autoCandidate(payload: payload, excluding: excluding)
        }

        guard let parsed = parseExplicitSelection(canonical),
              let agent = payload.agents.first(where: { $0.clientId == parsed.clientId }),
              let window = agent.uniqueCardWindows.first(where: { $0.cardId == parsed.value })
        else { return nil }
        return (agent.clientId, window)
    }

    /// True when `resolve` returned nil ONLY because the exclusion removed every
    /// otherwise-resolvable auto candidate (there IS a healthy window, but all
    /// of them belong to excluded clients). Lets a caller distinguish "all
    /// candidates hidden" from "no payload / fetch failed / no healthy window":
    /// in the former it must suppress a stale cache fallback (the hidden
    /// client's last reading) rather than keep showing it. Only meaningful for
    /// the auto/empty selection — an explicit pick ignores the exclusion, so
    /// this returns false for it (and for an empty exclusion or no payload).
    public static func excludedAllCandidates(
        payload: AgentUsagePayload?, selection: String, excluding: Set<String>
    ) -> Bool {
        guard !excluding.isEmpty else { return false }
        guard let payload,
              canonicalSelection(payload: payload, selection: selection) == Self.auto
        else { return false }
        guard autoCandidate(payload: payload, excluding: []) != nil else { return false }
        return autoCandidate(payload: payload, excluding: excluding) == nil
    }

    private static func parseExplicitSelection(
        _ raw: String
    ) -> (clientId: String, value: String)? {
        guard !raw.isEmpty, raw != auto else { return nil }
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let clientId = String(parts[0])
        let value = String(parts[1])
        guard !clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return (clientId, value)
    }

    private static func autoCandidate(
        payload: AgentUsagePayload, excluding: Set<String>
    ) -> (clientId: String, window: UsageWindow)? {
        var best: (clientId: String, window: UsageWindow)?
        for agent in payload.agents
        where agent.error == nil && !excluding.contains(agent.clientId) {
            // Rust omits malformed percentage readings before serialization.
            // Do not reject every `.invalidEvidence` pace status here: a reset or
            // duration error can coexist with a valid remaining-percentage gauge.
            for window in agent.uniqueCardWindows where window.remainingPercent.isFinite {
                if best == nil || window.remainingPercent < best!.window.remainingPercent {
                    best = (agent.clientId, window)
                }
            }
        }
        return best
    }
}
