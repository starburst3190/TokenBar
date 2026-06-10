import Foundation

// Live tail payloads. `TraceBucket` is the one snake_case shape in the
// contract (the Tauri struct has no rename attribute), hence explicit keys.

public struct TraceBucket: Decodable, Sendable {
    public let client: String
    public let agent: String
    public let model: String
    public let tokens: Int64
    public let messages: Int
    public let tokensPerMin: Double

    enum CodingKeys: String, CodingKey {
        case client, agent, model, tokens, messages
        case tokensPerMin = "tokens_per_min"
    }

    // Memberwise init for collapsed rows and selftest fixtures.
    public init(
        client: String, agent: String, model: String, tokens: Int64,
        messages: Int, tokensPerMin: Double
    ) {
        self.client = client
        self.agent = agent
        self.model = model
        self.tokens = tokens
        self.messages = messages
        self.tokensPerMin = tokensPerMin
    }

    /// Collapse (client, agent, model) buckets to one row per client, for the
    /// trace card's compact view. Agent/model strings join sorted; "unknown"
    /// models drop out when a client has named ones too. Rows sort by tokens.
    public static func collapseByClient(_ buckets: [TraceBucket]) -> [TraceBucket] {
        struct Slot {
            var tokens: Int64 = 0
            var messages = 0
            var tokensPerMin = 0.0
            var agents = Set<String>()
            var models = Set<String>()
        }
        var groups: [String: Slot] = [:]
        var order: [String] = []
        for bucket in buckets {
            var slot = groups[bucket.client] ?? {
                order.append(bucket.client)
                return Slot()
            }()
            slot.tokens += bucket.tokens
            slot.messages += bucket.messages
            slot.tokensPerMin += bucket.tokensPerMin
            slot.agents.insert(bucket.agent)
            slot.models.insert(bucket.model)
            groups[bucket.client] = slot
        }
        return order.map { client in
            let slot = groups[client]!
            var models = slot.models.sorted()
            if models.count > 1 { models.removeAll { $0 == "unknown" } }
            return TraceBucket(
                client: client, agent: slot.agents.sorted().joined(separator: ", "),
                model: models.joined(separator: ", "), tokens: slot.tokens,
                messages: slot.messages, tokensPerMin: slot.tokensPerMin)
        }
        .sorted { $0.tokens > $1.tokens }
    }
}
/// Payload of `tb_tokens_per_min`: `{"tokensPerMin": <number>}`.
public struct TokensPerMin: Decodable, Sendable {
    public let tokensPerMin: Double
}
