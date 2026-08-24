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
    /// Recorded reset cycles of that window, newest first.
    var quotaCycles: [QuotaCycle] = []
    /// Those cycles joined to local usage; empty while the scan is out.
    var quotaHistory: [QuotaHistoryRow] = []
    /// Shared model palette, so a model keeps one colour across the app.
    var colors: ModelColorMap = ModelColorMap(entries: [])
    /// Daily spend stacked by declared subscription, for the all-agent view.
    /// Nil until the graph payload has been folded.
    /// Recorded-cycle strips for every displayed window.
    var windowSummaries: [QuotaWindowSummary] = []
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
                    .foregroundStyle(.secondary)
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
        case .trend, .historyStrip, .heatmap: return singleClient == nil
        case .limits: return limitsEnabled
        case .history: return singleClient != nil
        }
    }

    @ViewBuilder
    private func card(_ card: QuotaCard) -> some View {
        switch card {
        case .windowUsage:
            if let windowCard {
                // Above its siblings: a `zIndex` set inside the card orders
                // that card's children, not the card among these.
                WindowUsageCard(state: windowCard).zIndex(1)
            }
        case .trend:
            // Answers "where is my spend going" across subscriptions, which
            // the window-by-window cards cannot.
            SubscriptionTrendCard(trend: trend)
        case .historyStrip:
            QuotaHistoryStripCard(
                summaries: windowSummaries, equivalences: equivalences,
                attempted: usageAttempted)
        case .heatmap:
            // Default order puts this after the strip, not before: the strip
            // says how much each window consumed, and this says when. "When"
            // is only a question once "how much" has an answer.
            QuotaHeatmapCard(
                windows: heatmapWindows, heatmaps: heatmaps,
                equivalences: equivalences, attempted: usageAttempted)
        case .limits:
            if let singleClient {
                AgentLimitsCard(
                    clients: [singleClient], trace: trace, agentUsage: agentUsage,
                    usageAttempted: usageAttempted,
                    title: "%@ limits".localized(
                        ClientRegistry.style(singleClient).displayName),
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
                    rows: quotaHistory, colors: colors, attempted: usageAttempted,
                    scanFailed: scanFailed, curveUnreadable: curveUnreadable)
            }
        }
    }
}
