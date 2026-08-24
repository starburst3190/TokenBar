import Foundation

/// The pieces the Quota lens can show, and the order the user put them in.
///
/// Declaration order is the default render order, as in `OverviewCard`. One
/// sequence serves both of the lens's surfaces: a single client renders
/// `windowUsage → limits → history` and the all-agent view renders
/// `trend → historyStrip → heatmap → limits`, which are the two subsequences
/// of the order below. A card that does not apply to a surface simply is not
/// drawn there — the same rule `OverviewCard` follows — so neither surface
/// needs an order of its own.
public enum QuotaCard: String, CaseIterable, Sendable {
    case windowUsage, trend, historyStrip, heatmap, limits, history

    /// Unlike `OverviewCard`, the label is spelled out per case rather than
    /// derived from the id. These ids describe a card's ROLE ("historyStrip"),
    /// while the settings row has to name the card the user is looking at
    /// ("Past windows"); a derived label would invent a third name for it.
    /// Every string below is the card's own `DashCard` title, so the
    /// translations already exist.
    public var label: String {
        switch self {
        case .windowUsage: return "Session window"
        case .trend: return "Daily by subscription"
        case .historyStrip: return "Past windows"
        case .heatmap: return "When the allowance goes"
        case .limits: return "Agent limits"
        case .history: return "Window history"
        }
    }

    /// Every quota card may be hidden. `OverviewCard` pins its chart because
    /// Overview is the lens every hidden lens falls back TO; Quota is not a
    /// fallback for anything, and the lens itself can be hidden outright, so
    /// there is nothing here that must survive. `QuotaView` says so on screen
    /// when the last one goes.
    public static let toggleable: [QuotaCard] = allCases

    public static let hiddenKey = "tokenbar.quota.hidden"
    public static let orderKey = "tokenbar.quota.order"

    /// All cards in the user's saved order, with any card the saved order does
    /// not mention appended in declaration order — so a card added by a later
    /// release appears rather than vanishing because an old preference never
    /// heard of it. Ids in the saved order that name nothing are dropped.
    public static func ordered(orderRaw: String) -> [QuotaCard] {
        ClientRegistry.orderedClients(allCases.map(\.rawValue), orderRaw: orderRaw)
            .compactMap(QuotaCard.init(rawValue:))
    }

    /// Cards shown, given the persisted hidden-set and order raw strings. Same
    /// comma-separated shape, and the same parser, as every other id list the
    /// app persists.
    public static func visible(hiddenRaw: String, orderRaw: String) -> [QuotaCard] {
        let hidden = ClientRegistry.parseIdSet(hiddenRaw)
        return ordered(orderRaw: orderRaw).filter { !hidden.contains($0.rawValue) }
    }
}
