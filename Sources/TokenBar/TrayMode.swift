import Foundation
import TokenBarCore

/// What the status-item text shows next to the icon, mirroring TrayMode +
/// computeTrayTitle in the Tauri app's settings.ts.
enum TrayMode: String, CaseIterable {
    case todayTokens = "today_tokens"
    case todayCost = "today_cost"
    case totalTokens = "total_tokens"
    case totalCost = "total_cost"
    case tokensPerMin = "tokens_per_min"
    case hidden

    static let storageKey = "tokenbar.tray.mode"

    static var current: TrayMode {
        UserDefaults.standard.string(forKey: storageKey)
            .flatMap(TrayMode.init(rawValue:)) ?? .todayTokens
    }

    var label: String {
        switch self {
        case .todayTokens: return "Today's tokens (50M)"
        case .todayCost: return "Today's cost ($5.20)"
        case .totalTokens: return "Total tokens (1.5B)"
        case .totalCost: return "Total cost ($889)"
        case .tokensPerMin: return "Tokens / min (12.4K/m)"
        case .hidden: return "Icon only"
        }
    }

    /// The tray title for this mode ("" = icon only). `tokensPerMin` is only
    /// consulted by the live-rate mode.
    func title(graph: UsagePayload?, tokensPerMin: Double?) -> String {
        guard self != .hidden, let graph else { return "" }
        switch self {
        case .todayTokens:
            return Format.compactTokens(Format.todayTokens(in: graph))
        case .todayCost:
            return Format.usd(Format.todayCost(in: graph))
        case .totalTokens:
            return Format.compactTokens(graph.summary.totalTokens)
        case .totalCost:
            return Format.usd(graph.summary.totalCost)
        case .tokensPerMin:
            guard let tokensPerMin else { return "—/m" }
            return "\(Format.compactTokens(Int64(max(0, tokensPerMin).rounded())))/m"
        case .hidden:
            return ""
        }
    }
}
