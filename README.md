# TokenBar (native)

Native SwiftUI rewrite of [TokenBar](https://github.com/Nanako0129/TokenBar) —
a macOS menu-bar monitor for AI coding-agent token usage and quotas, with
Liquid Glass on macOS 26+.

> **Status: work in progress.** The shipping app is still the Tauri-based
> [TokenBar](https://github.com/Nanako0129/TokenBar); this repo takes over at
> feature parity (target: v0.4.4 feature set).

## Progress

| Phase | Scope | Status |
|---|---|---|
| 0 | Repo skeleton: cargo workspace + SwiftPM + CI | ✅ |
| 1 | FFI data layer: 8 JSON entry points over tokscale-core + Swift models | ✅ |
| 2 | SceneKit 3D contribution-graph spike (163 fps, custom orbit rig) | ✅ |
| 3 | Menu-bar shell: NSStatusItem + popover + Liquid Glass/vibrancy | ✅ |
| 4 | Overview lens: usage chart, model breakdown, streaks | ✅ |
| 5 | Remaining lenses: Models / Daily / Hourly / Stats / Agents + tabs | ✅ |
| 6 | Agent limits + pace + live trace + settings | — |
| 7 | 3D contribution graph integration | — |
| 8 | Cat animation, shortcuts, autostart | — |
| 9 | Sparkle updater, signing, packaging, release CI | — |
| 10 | Bundle-id switch, migration, v1.0.0 | — |

## Architecture

Rust owns the data (session parsing, aggregation, pricing, quota fetching) via
the vendored [tokscale-core](https://github.com/junhoyeo/tokscale), exposed to
Swift as a C-ABI staticlib (`crates/tb_core_ffi`). Swift owns everything else:
SwiftUI views, `NSStatusItem` shell, Sparkle updates.

| Part | Path | Role |
|---|---|---|
| Rust FFI | `crates/tb_core_ffi` | staticlib; JSON-returning C entry points over tokscale-core |
| C shim | `Sources/CTB` | header + modulemap so Swift can import the FFI |
| Core | `Sources/TokenBarCore` | decode JSON into Swift models; pace/stats logic |
| App | `Sources/TokenBar` | menu-bar app (SwiftUI, Liquid Glass / vibrancy fallback) |

## Build

Requires Swift 6 and a Rust toolchain. macOS 14+.

```bash
make        # cargo build --release, then swift build
make run    # build + run the smoke binary
```

> **Note:** run `swift build` from the repo root — the linker's `-L
> target/release` path in `Package.swift` is relative.

## Credits

TokenBar began as a fork of [tokcat](https://github.com/handlecusion/tokcat) by
handlecusion (the spinning-cat idea is theirs). Parsing/pricing comes from
[tokscale](https://github.com/junhoyeo/tokscale) by Junho Yeo. The native
menu-bar shell patterns reference [CodexBar](https://github.com/steipete/CodexBar)
by Peter Steinberger (MIT). Licensed under [MIT](LICENSE).
