import AppKit
import SwiftUI
import TokenBarCore

/// Popover root: loads the dashboard data off the main actor and renders the
/// Overview lens. Other lenses and per-client tabs arrive in later phases.
struct PopoverView: View {
    private struct Dashboard {
        let payload: UsagePayload
        let stats: UsageStats
        let modelReport: ModelReport?
        let colors: ModelColorMap
    }

    private enum DashboardState {
        case loading
        case loaded(Dashboard)
        case failed(String)
    }

    @State private var state: DashboardState = .loading
    @State private var tokensPerMin: Double?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 360, height: 480)
        .background(GlassBackground().ignoresSafeArea())
        .task { await loadDashboard() }
        .task { await pollTokensPerMin() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Image(systemName: "chart.bar.fill")
                .foregroundStyle(.secondary)
            Text("TokenBar")
                .font(.headline)
            Spacer()
            liveRateBadge
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var liveRateBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(tokensPerMin.map { $0 > 0 ? Color.green : .secondary.opacity(0.4) } ?? .secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(tokensPerMin.map { "\(Format.compactTokens(Int64($0.rounded()))) tok/min" } ?? "— tok/min")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading usage…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
        case let .loaded(dashboard):
            OverviewView(
                payload: dashboard.payload,
                stats: dashboard.stats,
                modelReport: dashboard.modelReport,
                colors: dashboard.colors)
        }
    }

    private var footer: some View {
        HStack {
            Text("Overview")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Data

    /// TBCore is blocking — hop off the main actor for the FFI calls. The
    /// model report failing only degrades colors/rows, not the whole view.
    private func loadDashboard() async {
        do {
            async let payloadTask = Task.detached(priority: .userInitiated) {
                try TBCore.graph()
            }.value
            async let reportTask = Task.detached(priority: .userInitiated) {
                try? TBCore.modelReport()
            }.value
            let payload = try await payloadTask
            let report = await reportTask
            let stats = UsageStats(
                payload: payload, selectedClients: Set(payload.summary.clients))
            state = .loaded(
                Dashboard(
                    payload: payload, stats: stats, modelReport: report,
                    colors: ModelColorMap(report: report)))
        } catch {
            state = .failed("Failed to load usage: \(error)")
        }
    }

    /// Poll the live rate every 10s while the popover content is on screen;
    /// `.task` cancels this loop when the popover closes.
    private func pollTokensPerMin() async {
        while !Task.isCancelled {
            let rate = try? await Task.detached(priority: .utility) {
                try TBCore.tokensPerMin()
            }.value
            if Task.isCancelled { break }
            tokensPerMin = rate
            try? await Task.sleep(for: .seconds(10))
        }
    }
}
