import Foundation
import TokenBarCore

// Logic checks for the pure TokenBarCore ports, run via `TokenBar --selftest`.
// Plain assertions instead of swift-testing/XCTest because the dev machine has
// Command Line Tools only (no testing modules); CI runs this the same way.

enum SelfTest {
    static func run() -> Never {
        var failures = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            if condition() {
                print("ok   \(label)")
            } else {
                failures += 1
                print("FAIL \(label)")
            }
        }

        // ModelColors: provider inference + shade math.
        expect(ModelColors.providerFromModel("claude-sonnet-4-6") == "anthropic", "provider claude")
        expect(ModelColors.providerFromModel("gpt-5.5") == "openai", "provider gpt")
        expect(ModelColors.providerFromModel("o3-mini") == "openai", "provider o3")
        expect(ModelColors.providerFromModel("gemini-3-pro") == "google", "provider gemini")
        expect(ModelColors.providerFromModel("auto") == "cursor", "provider cursor auto")
        expect(ModelColors.providerFromModel("mystery") == "unknown", "provider unknown")
        expect(ModelColors.providerColorKey("litellm, openai", "gpt-5.5") == "openai", "merged provider id")
        expect(ModelColors.providerColorKey("Anthropic", "whatever") == "anthropic", "provider id alias")
        expect(ModelColors.shadeFromBase("#da7756", rank: 0) == "#da7756", "shade rank 0 is base")
        // rank 1 factor 0.11: 59→81 (0x51), 130→144 (0x90), 246→247 (0xf7)
        expect(ModelColors.shadeFromBase("#3b82f6", rank: 1) == "#5190f7", "shade rank 1 lerp")

        // ModelColorMap: cost ranking drives shades; unseen models fall back.
        let map = ModelColorMap(entries: [
            ("anthropic", "claude-opus-4-8", 100.0),
            ("anthropic", "claude-haiku-4-5", 1.0),
        ])
        expect(map.color("anthropic", "claude-opus-4-8") == "#da7756", "priciest model gets base shade")
        expect(map.color("anthropic", "claude-haiku-4-5") != "#da7756", "cheaper model is tinted")
        expect(map.color(nil, "gemini-3-pro") == "#06b6d4", "unseen model falls back to provider base")

        // ISODay: civil-date round trip.
        expect(ISODay("1970-01-01")?.number == 0, "epoch day number")
        expect(ISODay("2026-06-10")?.iso == "2026-06-10", "iso round trip")
        expect(ISODay("garbage") == nil, "invalid iso rejected")

        // Streaks: longest run vs current run touching the range end.
        func perDay(_ dates: [String]) -> [String: PerDay] {
            Dictionary(uniqueKeysWithValues: dates.map {
                ($0, PerDay(date: $0, tokens: 10, cost: 1, intensity: 1))
            })
        }
        let s1 = Streaks.compute(
            perDayMap: perDay(["2026-06-01", "2026-06-02", "2026-06-03", "2026-06-05", "2026-06-06"]),
            rangeStart: "2026-06-01", rangeEnd: "2026-06-06")
        expect(s1.longest == 3 && s1.current == 2, "streaks longest 3 current 2")
        let s2 = Streaks.compute(
            perDayMap: perDay(["2026-06-01"]),
            rangeStart: "2026-06-01", rangeEnd: "2026-06-03")
        expect(s2.longest == 1 && s2.current == 0, "broken current streak is zero")
        let s3 = Streaks.compute(perDayMap: [:], rangeStart: "2026-06-10", rangeEnd: "2026-06-01")
        expect(s3.longest == 0 && s3.current == 0, "inverted range is empty")

        if failures > 0 {
            print("\(failures) selftest check(s) failed")
            exit(1)
        }
        print("selftest passed")
        exit(0)
    }
}
