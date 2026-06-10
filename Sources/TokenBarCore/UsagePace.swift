import Foundation

// Usage pace — port of the Tauri app's src/lib/usagePace.ts (itself ported
// from codexbar's UsagePace).
//
// Given a rate-limit window's length and reset time, work out how much you'd
// be *expected* to have used if you paced evenly, compare it to actual usage,
// and classify the gap. Positive delta = ahead of pace ("in deficit", burning
// fast); negative = behind pace ("in reserve"). Also projects when the window
// empties at the current burn rate.

/// How the pace marker is derived (`PaceMode` in settings.ts).
public enum PaceMode: String, CaseIterable, Sendable {
    case historical, linear, off
}

public enum PaceStage: Sendable, Equatable {
    case onTrack
    case slightlyAhead, ahead, farAhead
    case slightlyBehind, behind, farBehind

    public var isDeficit: Bool {
        switch self {
        case .slightlyAhead, .ahead, .farAhead: return true
        default: return false
        }
    }
}

public struct UsagePace: Sendable {
    public let stage: PaceStage
    /// actual − expected, in percentage points (>0 = ahead/deficit).
    public let deltaPercent: Double
    public let expectedUsedPercent: Double
    public let actualUsedPercent: Double
    /// Seconds until the window empties at the current rate, if before reset.
    public let etaSeconds: Double?
    /// True if the current rate lasts past the reset (won't run out).
    public let willLastToReset: Bool

    /// Short left-hand label: "On pace" / "12% in deficit" / "8% in reserve".
    public var label: String {
        if stage == .onTrack { return "On pace" }
        let d = Int(abs(deltaPercent).rounded())
        return stage.isDeficit ? "\(d)% in deficit" : "\(d)% in reserve"
    }

    /// Right-hand projection: "Lasts until reset" / "Projected empty in 2h 10m".
    public var etaText: String? {
        if willLastToReset { return "Lasts until reset" }
        guard let etaSeconds else { return nil }
        let t = Self.durationText(etaSeconds)
        return t == "now" ? "Projected empty now" : "Projected empty in \(t)"
    }

    public static func durationText(_ seconds: Double) -> String {
        let m = Int((seconds / 60).rounded())
        if m < 1 { return "now" }
        if m < 60 { return "\(m)m" }
        let h = m / 60
        let rem = m % 60
        if h < 24 { return rem > 0 ? "\(h)h \(rem)m" : "\(h)h" }
        let days = h / 24
        let hr = h % 24
        return hr > 0 ? "\(days)d \(hr)h" : "\(days)d"
    }
}

private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
    min(hi, max(lo, v))
}

private func stageFor(_ delta: Double) -> PaceStage {
    let a = abs(delta)
    if a <= 2 { return .onTrack }
    if a <= 6 { return delta >= 0 ? .slightlyAhead : .slightlyBehind }
    if a <= 12 { return delta >= 0 ? .ahead : .behind }
    return delta >= 0 ? .farAhead : .farBehind
}

/// RFC3339 parser tolerating fractional seconds (the backend emits both).
/// ISO8601DateFormatter is not Sendable, so build per call — pace runs a
/// handful of times per refresh, never hot.
func parseRFC3339(_ s: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: s) ?? ISO8601DateFormatter().date(from: s)
}

extension UsagePace {
    /// Compute *linear* pace for a window, or nil if it can't be derived yet.
    public static func compute(window: UsageWindow, now: Date = Date()) -> UsagePace? {
        computeCore(window: window, now: now, expectedOverride: nil)
    }

    /// Compute pace under the user's chosen mode:
    /// - `off`        → nil (no pace marker).
    /// - `historical` → use the backend's historical expected-percent if
    ///                  present, otherwise transparently fall back to linear.
    /// - `linear`     → naive elapsed/duration pace.
    public static func compute(
        window: UsageWindow, mode: PaceMode, now: Date = Date()
    ) -> UsagePace? {
        if mode == .off { return nil }
        let override: Double? =
            mode == .historical
            ? window.historicalExpectedPercent.map { clamp($0, 0, 100) }
            : nil
        guard let pace = computeCore(window: window, now: now, expectedOverride: override)
        else { return nil }
        // In historical mode the run-out *probability* (share of past weeks
        // that hit the cap) is a better lasts/empty signal than the naive
        // linear burn rate — otherwise the card could read "in reserve ·
        // Projected empty" at once. If most past weeks lasted, project "Lasts
        // until reset"; codexbar does the same.
        if override != nil, let probability = window.runOutProbability {
            let lasts = probability < 0.5
            return UsagePace(
                stage: pace.stage, deltaPercent: pace.deltaPercent,
                expectedUsedPercent: pace.expectedUsedPercent,
                actualUsedPercent: pace.actualUsedPercent,
                etaSeconds: lasts ? nil : pace.etaSeconds,
                willLastToReset: lasts)
        }
        return pace
    }

    private static func computeCore(
        window: UsageWindow, now: Date, expectedOverride: Double?
    ) -> UsagePace? {
        guard let resetsAtRaw = window.resetsAt,
              let windowMinutes = window.windowMinutes, windowMinutes > 0,
              let resetsAt = parseRFC3339(resetsAtRaw)
        else { return nil }

        let duration = Double(windowMinutes) * 60
        let timeUntilReset = resetsAt.timeIntervalSince(now)
        if timeUntilReset <= 0 || timeUntilReset > duration { return nil }

        let elapsed = clamp(duration - timeUntilReset, 0, duration)
        // Expected used-percent: historical override when available, else the
        // naive linear elapsed/duration. The rest (delta/stage/ETA) is
        // identical either way.
        let expected = expectedOverride ?? clamp(elapsed / duration * 100, 0, 100)
        let actual = clamp(window.usedPercent, 0, 100)
        if elapsed == 0 && actual > 0 { return nil }

        let delta = actual - expected

        var etaSeconds: Double?
        var willLastToReset = false
        if elapsed > 0 && actual > 0 {
            let rate = actual / elapsed // %% per second
            if rate > 0 {
                let remaining = max(0, 100 - actual)
                let candidate = remaining / rate
                if candidate >= timeUntilReset {
                    willLastToReset = true
                } else {
                    etaSeconds = candidate
                }
            }
        } else if elapsed > 0 && actual == 0 {
            willLastToReset = true
        }

        return UsagePace(
            stage: stageFor(delta), deltaPercent: delta,
            expectedUsedPercent: expected, actualUsedPercent: actual,
            etaSeconds: etaSeconds, willLastToReset: willLastToReset)
    }
}

/// codexbar-style historical run-out risk, e.g. "≈ 30% run-out risk", or nil.
public func runOutRiskLabel(window: UsageWindow) -> String? {
    guard let probability = window.runOutProbability else { return nil }
    let pct = Int((clamp(probability, 0, 1) * 100).rounded())
    if pct <= 0 { return nil }
    return "≈ \(pct)% run-out risk"
}
