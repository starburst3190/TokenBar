import AppKit
import SwiftUI
import TokenBarCore

/// Popover root: view-switch row + lens router over a shared DashboardModel.
/// Per-client tabs join in a later phase.
struct PopoverView: View {
    @State private var model = DashboardModel()
    @State private var tokensPerMin: Double?
    @AppStorage("tokenbar.view") private var activeViewRaw = AppView.overview.rawValue

    private var activeView: Binding<AppView> {
        Binding(
            get: { AppView(rawValue: activeViewRaw) ?? .overview },
            set: { activeViewRaw = $0.rawValue })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ViewSwitch(active: activeView)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
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
        .task { await model.load() }
        .task(id: activeViewRaw) {
            await model.ensureData(for: activeView.wrappedValue)
        }
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
        switch model.phase {
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
        case .ready:
            lens
        }
    }

    /// Lens router. Placeholders are filled in by tasks 5.2–5.6.
    @ViewBuilder private var lens: some View {
        if let payload = model.payload, let stats = model.stats {
            switch activeView.wrappedValue {
            case .overview:
                OverviewView(
                    payload: payload, stats: stats,
                    modelReport: model.modelReport, colors: model.colors)
            case .models:
                ModelsView(report: model.modelReport, colors: model.colors)
            case .daily, .hourly, .stats, .agents:
                placeholder(activeView.wrappedValue)
            }
        }
    }

    private func placeholder(_ view: AppView) -> some View {
        DashCard(view.label) {
            Text("Coming soon — this lens is being ported.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Text(activeView.wrappedValue.label)
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

    // MARK: - Live rate

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
