import SwiftUI
import TokenBarCore

/// The classic TokenBar dashboard stack (all-agent overview lens). Agent
/// limits and the live-session trace cards join the stack in a later phase;
/// per-client tabs and the other lenses arrive with the view switch.
struct OverviewView: View {
    let payload: UsagePayload
    let stats: UsageStats
    let modelReport: ModelReport?
    let colors: ModelColorMap

    var body: some View {
        VStack(spacing: 12) {
            UsageChartCard(payload: payload, stats: stats, colors: colors)
            ModelBreakdownCard(report: modelReport, colors: colors)
            StreaksCard(streaks: stats.streaks)
        }
    }
}
