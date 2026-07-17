import Foundation
import TokenBarCore

// Swift side of the Swift↔C# fixture cross-check. Feeds identical fixture JSON
// to the shipping TokenBarCore/Format code and writes <basename>.actual.json so
// diff.py can compare it field-by-field against the C# port. See the contract
// in the Windows repo: crosscheck/README.md.
//
// Format.swift is symlinked in from Sources/TokenBar so the harness compiles the
// exact same source the app ships (the README says TokenBarCore/Format.swift;
// it actually lives in the app target). No reimplementation — fidelity is the point.

// --- fail fast on timezone (todayKey/today* bucket in the local zone) ---
guard ProcessInfo.processInfo.environment["TZ"] == "Asia/Taipei" else {
    FileHandle.standardError.write(Data("error: TZ must be Asia/Taipei (got \(ProcessInfo.processInfo.environment["TZ"] ?? "unset"))\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: crosscheck-harness <fixtures-dir> <out-dir>\n".utf8))
    exit(2)
}
let fixturesDir = URL(fileURLWithPath: args[1], isDirectory: true)
let outDir = URL(fileURLWithPath: args[2], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// Harness-side strict RFC3339 parser for `now` (NOT the module under test — the
// module parses window.resetsAt itself, which some fixtures exercise).
func parseNow(_ s: String) -> Date? {
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    if let d = plain.date(from: s) { return d }
    let frac = ISO8601DateFormatter()
    frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return frac.date(from: s)
}

// Polymorphic scalar `arg`. Int64-first so int64-max survives exactly (a Double
// path would mangle exact-int64-max / compact-int64-max).
enum Arg: Decodable {
    case int(Int64), double(Double), string(String)
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int64.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else { self = .string(try c.decode(String.self)) }
    }
    var asInt64: Int64 { switch self { case .int(let i): return i; case .double(let d): return Int64(d); case .string: return 0 } }
    var asDouble: Double { switch self { case .int(let i): return Double(i); case .double(let d): return d; case .string: return 0 } }
    var asString: String { switch self { case .string(let s): return s; default: return "" } }
}

func stageName(_ s: PaceStage) -> String {
    switch s {
    case .onTrack: return "onTrack"
    case .slightlyAhead: return "slightlyAhead"
    case .ahead: return "ahead"
    case .farAhead: return "farAhead"
    case .slightlyBehind: return "slightlyBehind"
    case .behind: return "behind"
    case .farBehind: return "farBehind"
    }
}

let decoder = JSONDecoder() // same config production uses (plain default)

func write(_ obj: [String: Any], to name: String) throws {
    let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: outDir.appendingPathComponent(name))
}

// ---------------- usage-pace.json ----------------
struct PaceCase: Decodable {
    let name: String
    let kind: String
    let mode: String?
    let now: String?
    let window: UsageWindow // production DTO, production decoder
}
struct PaceFile: Decodable { let cases: [PaceCase] }

func runUsagePace() throws {
    let data = try Data(contentsOf: fixturesDir.appendingPathComponent("usage-pace.json"))
    let file = try decoder.decode(PaceFile.self, from: data)
    var out: [String: Any] = [:]
    for c in file.cases {
        switch c.kind {
        case "compute":
            guard let modeRaw = c.mode, let mode = PaceMode(rawValue: modeRaw) else {
                out[c.name] = ["error": "unknown pace mode \(c.mode ?? "nil")"]; continue
            }
            guard let nowRaw = c.now, let now = parseNow(nowRaw) else {
                out[c.name] = ["error": "unparseable now \(c.now ?? "nil")"]; continue
            }
            guard let pace = UsagePace.compute(window: c.window, mode: mode, now: now) else {
                out[c.name] = NSNull(); continue
            }
            out[c.name] = [
                "stage": stageName(pace.stage),
                "deltaPercent": pace.deltaPercent,
                "expectedUsedPercent": pace.expectedUsedPercent,
                "actualUsedPercent": pace.actualUsedPercent,
                "etaSeconds": pace.etaSeconds.map { $0 as Any } ?? NSNull(),
                "willLastToReset": pace.willLastToReset,
                "label": pace.label,
                "etaText": pace.etaText.map { $0 as Any } ?? NSNull(),
            ]
        case "runOutRisk":
            out[c.name] = runOutRiskLabel(window: c.window).map { $0 as Any } ?? NSNull()
        default:
            out[c.name] = ["error": "unknown kind \(c.kind)"]
        }
    }
    try write(out, to: "usage-pace.actual.json")
    print("usage-pace.actual.json: \(out.count) cases")
}

// ---------------- format.json ----------------
struct FormatCase: Decodable {
    let name: String
    let fn: String
    let now: String?
    let arg: Arg?
}
struct FormatFile: Decodable {
    let graph: UsagePayload // production DTO, production decoder
    let cases: [FormatCase]
}

func runFormat() throws {
    let data = try Data(contentsOf: fixturesDir.appendingPathComponent("format.json"))
    let file = try decoder.decode(FormatFile.self, from: data)
    var out: [String: Any] = [:]
    for c in file.cases {
        func nowDate() -> Date? { c.now.flatMap(parseNow) }
        switch c.fn {
        case "compactTokens":
            out[c.name] = Format.compactTokens(c.arg?.asInt64 ?? 0)
        case "exactTokens":
            out[c.name] = Format.exactTokens(c.arg?.asInt64 ?? 0)
        case "usd":
            out[c.name] = Format.usd(c.arg?.asDouble ?? 0)
        case "monthDay":
            out[c.name] = Format.monthDay(c.arg?.asString ?? "")
        case "mmdd":
            out[c.name] = Format.mmdd(c.arg?.asString ?? "")
        case "relativeTime":
            guard let now = nowDate() else { out[c.name] = ["error": "relativeTime needs now"]; continue }
            out[c.name] = Format.relativeTime(UInt64(c.arg?.asInt64 ?? 0), now: now)
        case "todayKey":
            guard let now = nowDate() else { out[c.name] = ["error": "todayKey needs now"]; continue }
            out[c.name] = Format.todayKey(now: now)
        case "todayTokens":
            guard let now = nowDate() else { out[c.name] = ["error": "todayTokens needs now"]; continue }
            out[c.name] = file.graph.trayTotals(hidden: [], today: Format.todayKey(now: now)).todayTokens
        case "todayCost":
            guard let now = nowDate() else { out[c.name] = ["error": "todayCost needs now"]; continue }
            out[c.name] = file.graph.trayTotals(hidden: [], today: Format.todayKey(now: now)).todayCost
        case "paceDurationText":
            out[c.name] = UsagePace.durationText(c.arg?.asDouble ?? 0)
        default:
            out[c.name] = ["error": "unknown fn \(c.fn)"]
        }
    }
    try write(out, to: "format.actual.json")
    print("format.actual.json: \(out.count) cases")
}

try runUsagePace()
try runFormat()
