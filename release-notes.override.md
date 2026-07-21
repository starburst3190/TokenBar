## Highlights

- **Grok Build usage is accurate again.** Multi-turn sessions now count real API usage from `turn_completed` events (with unified-log precedence when present) instead of under-counting from context counters. Totals may rise sharply versus 1.5.0 — that is a correction, not new spend. [#69](https://github.com/Nanako0129/TokenBar/pull/69) [#77](https://github.com/Nanako0129/TokenBar/pull/77)
- **Grok subscription card shows weekly and monthly meters.** Agent Limits recovers the SuperGrok weekly credits window and, best-effort, adds the monthly included allowance only when the billing API returns used/limit for that meter. A missing or failed monthly read does not sink the weekly card; a weekly reset with no usage yet no longer fails the whole card either. [#76](https://github.com/Nanako0129/TokenBar/pull/76)
- **Historical pace expands beyond Codex Weekly.** Only eligible recurring quota windows for Codex, Claude, Grok, Antigravity, and Copilot (not every % card) can learn account-scoped history and show Historical / Linear / Off projections with typed learning and unavailable states. Learning may restart for providers that did not have history before. [#58](https://github.com/Nanako0129/TokenBar/pull/58) [#60](https://github.com/Nanako0129/TokenBar/pull/60)
- **More local usage is counted.** Expanded sources on existing clients: OpenCode v2 session databases, Kiro IDE globalStorage and structured sessions, and Kimi Code beside legacy Kimi. New first-class clients: Junie and OpenCodeReview. All flow through Overview, Models, Monthly, Hourly, and Agents. [#63](https://github.com/Nanako0129/TokenBar/pull/63) [#65](https://github.com/Nanako0129/TokenBar/pull/65) [#66](https://github.com/Nanako0129/TokenBar/pull/66) [#71](https://github.com/Nanako0129/TokenBar/pull/71)

## Changes

- **Long-context and routed pricing.** Request-level long-context tiers for verified Sakana / LiteLLM paths and safer routed-provider cost resolution so displayed dollars follow the selected pricing policy. [#70](https://github.com/Nanako0129/TokenBar/pull/70)
- **Existing-parser correctness (M16).** Start-anchored durations, Codex/Claude/Copilot merge and identity fixes, and Antigravity alias cleanup so shared sessions do not double-count or mis-attribute. [#67](https://github.com/Nanako0129/TokenBar/pull/67)
- **Usage cache schema advances 29→32 (via 30/31).** First launch after this update rebuilds the local message cache once so OpenCode v2, parser fixes, and Grok turn usage are not mixed with stale entries. Expect a slower first scan; subsequent refreshes return to normal. [#65](https://github.com/Nanako0129/TokenBar/pull/65) [#67](https://github.com/Nanako0129/TokenBar/pull/67) [#77](https://github.com/Nanako0129/TokenBar/pull/77)
- **Windows vendor portability and atomic rename retries** for the downstream Windows line (no change to macOS product behavior). [#59](https://github.com/Nanako0129/TokenBar/pull/59) [#61](https://github.com/Nanako0129/TokenBar/pull/61) [#68](https://github.com/Nanako0129/TokenBar/pull/68)
- **Selective tokscale alignment ledger** updated through M21 / M25 bookkeeping; Zcode remains deferred after the fidelity stop. [#64](https://github.com/Nanako0129/TokenBar/pull/64) [#73](https://github.com/Nanako0129/TokenBar/pull/73)

## Fixes

- **Quota card IDs that contain `|` no longer split incorrectly** (for example Antigravity model-scoped windows). [#60](https://github.com/Nanako0129/TokenBar/pull/60)
- **Grok weekly card no longer errors** when credits percent is omitted right after a weekly reset (treated as 0% used). [#76](https://github.com/Nanako0129/TokenBar/pull/76)

## Not in this release

- Copilot Desktop SQLite, VS Code `chatSessions`, and Hermes Windows discovery (open M23 / PR #74)
- Zcode client (PR #72 closed unmerged; deferred)
- In-app settings UI for reloadable model aliases (core API only; PR #75)
