import TokenBarCore

/// Shared quota-selection policy for the tray and Settings preview. Both live
/// and demo callers use the same payload-aware canonical migration.
enum QuotaSelectionPolicy {
    static func effectiveSelection(
        payload: AgentUsagePayload?,
        persistedSelection: String,
        excluding: Set<String>
    ) -> String {
        QuotaResolver.canonicalSelection(payload: payload, selection: persistedSelection)
    }

    static func resolve(
        payload: AgentUsagePayload?,
        persistedSelection: String,
        excluding: Set<String>
    ) -> (clientId: String, window: UsageWindow)? {
        let selection = effectiveSelection(
            payload: payload,
            persistedSelection: persistedSelection,
            excluding: excluding)
        return QuotaResolver.resolve(
            payload: payload, selection: selection, excluding: excluding)
    }
}
