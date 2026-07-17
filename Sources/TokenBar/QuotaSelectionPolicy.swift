import TokenBarCore

/// Shared quota-selection policy for the tray and Settings preview. Both live
/// and demo callers use the same payload-aware canonical migration; the
/// fallback flag remains only until Stage 5C2 removes the dead parameter.
enum QuotaSelectionPolicy {
    static func effectiveSelection(
        payload: AgentUsagePayload?,
        persistedSelection: String,
        excluding: Set<String>,
        fallbackUnknownExplicit: Bool
    ) -> String {
        QuotaResolver.canonicalSelection(payload: payload, selection: persistedSelection)
    }

    static func resolve(
        payload: AgentUsagePayload?,
        persistedSelection: String,
        excluding: Set<String>,
        fallbackUnknownExplicit: Bool
    ) -> (clientId: String, window: UsageWindow)? {
        let selection = effectiveSelection(
            payload: payload,
            persistedSelection: persistedSelection,
            excluding: excluding,
            fallbackUnknownExplicit: fallbackUnknownExplicit)
        return QuotaResolver.resolve(
            payload: payload, selection: selection, excluding: excluding)
    }
}
