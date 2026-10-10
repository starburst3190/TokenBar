import SwiftUI
import TokenBarCore

/// The "Quota" lens: everything about a subscription's usage windows in one
/// place, rather than the current window on Overview and its history somewhere
/// else.
///
/// The two tabs answer different questions and so render different things.
/// Across all agents the question is comparative — which subscription is
/// tightest, which is burning fastest — and `AgentLimitsCard` already answers
/// it, one sparkline per window. On a single client the question is specific:
/// this window, then the windows before it.
struct QuotaView: View {
    /// The open client tab, or nil on the all-agent view.
    let singleClient: String?
    let clientIds: [String]
    let trace: [TraceBucket]
    let agentUsage: AgentUsagePayload?
    var usageAttempted = true
    /// Whether the stage-two usage scan settled with an error, so the history
    /// card can say so instead of spinning under rows that are already drawn.
    var scanFailed = false
    var curveUnreadable = false
    /// Quota readings per `"<clientId>|<cardId>"`, for the sparklines.
    var windowCurves: [String: [QuotaSample]] = [:]
    /// The selected window's card state on a single-client tab.
    var windowCard: WindowCardState?
    /// The open client's accounts: pill row, header label, and which local-usage
    /// line the card and its history show. Nil when no account has live windows.
    var accountContext: CardAccountContext?
    /// Called with the account the reader picked (nil = primary).
    var onSelectAccount: (String?) -> Void = { _ in }
    /// Recorded reset cycles of that window, newest first.
    var quotaCycles: [QuotaCycle] = []
    /// Those cycles joined to local usage; empty while the scan is out.
    var quotaHistory: [QuotaHistoryRow] = []
    /// The cycles above belong to another account or window than the card
    /// shows now (an account pick before its refresh landed); draw loading.
    var historyPending = false
    /// Shared model palette, so a model keeps one colour across the app.
    var colors: ModelColorMap = ModelColorMap(entries: [])
    /// Daily spend stacked by declared subscription, for the all-agent view.
    /// Nil until the graph payload has been folded.
    /// Recorded-cycle strips for every displayed window.
    var windowSummaries: [QuotaWindowSummary] = []
    /// Clients with an unread window the strip has nothing to draw for.
    var stripUnreadableClients: Set<String> = []
    /// Weekday-by-hour consumption per window, keyed as the window's id.
    var heatmaps: [String: QuotaHeatmap] = [:]
    /// Which windows have a grid at all. Not derived from `windowSummaries`.
    var heatmapWindows: [QuotaHeatmapWindow] = []
    var equivalences: [String: WindowEquivalence.Row] = [:]
    var trend: SubscriptionTrend?

    @AppStorage("tokenbar.limits.enabled") private var limitsEnabled = true
    @AppStorage(QuotaCard.hiddenKey) private var hiddenCardsRaw = ""
    @AppStorage(QuotaCard.orderKey) private var cardOrderRaw = ""

    var body: some View {
        // Filtered by what this surface actually draws, not merely by what the
        // user left switched on: `visible` still contains the cards belonging
        // to the OTHER surface, and counting those would report a lens as
        // populated while it renders nothing.
        let cards = QuotaCard.visible(hiddenRaw: hiddenCardsRaw, orderRaw: cardOrderRaw)
            .filter(renders)
        VStack(spacing: 12) {
            ForEach(cards, id: \.self) { card in
                self.card(card)
            }
            // A lens with nothing in it reads as a bug rather than a choice —
            // say which it is, and where the choice was made.
            if cards.isEmpty {
                Text("No quota cards are switched on. Turn some back on in Settings › Dashboard.")
                    .font(.caption)
                    .foregroundStyle(.secondaryAdaptive)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Whether `card` draws anything here. The two surfaces answer different
    /// questions (see the type's doc comment), so a card absent from one is not
    /// a card the user hid — and `card(_:)` below does not re-state any of
    /// this, because a rule stated twice is a rule that gets reconciled once.
    private func renders(_ card: QuotaCard) -> Bool {
        switch card {
        case .windowUsage: return singleClient != nil && windowCard != nil
        case .trend: return singleClient == nil
        case .historyStrip, .heatmap: return singleClient == nil || hasNoWindowCard
        case .limits: return limitsEnabled
        case .history: return singleClient != nil && !hasNoWindowCard
        }
    }

    /// A client tab with no window card to list a history for: a Bot-only Grok
    /// install, or a tab whose client reports no quota. It shows the Past
    /// windows strip and the heatmap, filtered to its own clients, where every
    /// other client tab shows Window history. These folds need quota history
    /// only. A grouped tab with a window card (Grok Build & Bot, Antigravity)
    /// takes the window history, the same card as every other client tab; its
    /// other member's windows stay on the all-agent Quota lens.
    private var hasNoWindowCard: Bool {
        singleClient != nil && windowCard == nil
    }

    /// The strip and heatmap's "could not read" note: any shown client with an
    /// unread window.
    private var unreadable: Bool {
        singleClient == nil
            ? !stripUnreadableClients.isEmpty
            : !stripUnreadableClients.isDisjoint(with: clientIds)
    }

    @ViewBuilder
    private func card(_ card: QuotaCard) -> some View {
        switch card {
        case .windowUsage:
            if let windowCard {
                // Above its siblings: a `zIndex` set inside the card orders
                // that card's children, not the card among these.
                WindowUsageCard(
                    state: windowCard, account: accountContext,
                    onSelectAccount: onSelectAccount).zIndex(1)
            }
        case .trend:
            // Answers "where is my spend going" across subscriptions, which
            // the window-by-window cards cannot.
            SubscriptionTrendCard(trend: trend)
        case .historyStrip:
            QuotaHistoryStripCard(
                summaries: singleClient == nil
                    ? windowSummaries : windowSummaries.filter { clientIds.contains($0.clientId) },
                equivalences: equivalences, attempted: usageAttempted,
                unreadable: unreadable)
        case .heatmap:
            // Default order puts this after the strip, not before: the strip
            // says how much each window consumed, and this says when. "When"
            // is only a question once "how much" has an answer.
            QuotaHeatmapCard(
                windows: singleClient == nil
                    ? heatmapWindows : heatmapWindows.filter { clientIds.contains($0.clientId) },
                heatmaps: heatmaps, equivalences: equivalences,
                attempted: usageAttempted,
                unreadable: unreadable)
        case .limits:
            if let singleClient {
                AgentLimitsCard(
                    clients: clientIds, trace: trace, agentUsage: agentUsage,
                    usageAttempted: usageAttempted,
                    title: "%@ limits".localized(
                        ClientRegistry.tabDisplayName(singleClient)),
                    note: "Session / weekly / model limits",
                    restrict: true, curves: windowCurves)
            } else {
                AgentLimitsCard(
                    clients: clientIds, trace: trace, agentUsage: agentUsage,
                    usageAttempted: usageAttempted,
                    reorderable: true, curves: windowCurves)
            }
        case .history:
            if let singleClient {
                QuotaHistoryCard(
                    clientId: singleClient, cycles: quotaCycles,
                    rows: quotaHistory, colors: colors,
                    attempted: usageAttempted && !historyPending,
                    scanFailed: scanFailed, curveUnreadable: curveUnreadable,
                    account: accountContext)
                    // The card holds per-window state — how many rows the
                    // reader has grown the list to, and which row is open — and
                    // switching windows inside one client does not by itself
                    // rebuild it. Keyed on the RESOLVED window rather than the
                    // stored preference: a choice saved for another client does
                    // not move this one's window, and a window vanishing from
                    // the payload moves it without the preference changing.
                    // Same resolution the cycle list itself went through, so
                    // the key cannot name a window other than the one the rows
                    // came from.
                    // The account is part of the identity (history vocabulary:
                    // three-part for a non-primary account), so switching
                    // account rebuilds the card instead of keeping the
                    // other account's expanded rows.
                    .id(WindowCardLoader.historyCardId(
                        payload: agentUsage, clientId: singleClient,
                        accountKey: accountContext?.resolved))
            }
        }
    }
}
