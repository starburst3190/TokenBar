## Highlights
- TokenBar now tracks five more local AI coding tools — Cline, Antigravity CLI, jcode, MiMo Code, and gjc — so their token usage shows up alongside the tools you already track.

## Changes
- Add Cline and Antigravity CLI as tracked local sources [#11](https://github.com/Nanako0129/TokenBar/pull/11)
- Add jcode, MiMo Code, and gjc as tracked local sources [#12](https://github.com/Nanako0129/TokenBar/pull/12)
- More accurate pricing and per-tool attribution for token usage [#9](https://github.com/Nanako0129/TokenBar/pull/9)
- Corrected Codex usage counts for forked and sub-agent sessions [#10](https://github.com/Nanako0129/TokenBar/pull/10)
- Antigravity CLI usage is now dated per turn, so the live view and daily totals are accurate

## Fixes
- The app no longer crashes if the usage parser hits an unexpected error
- More reliable live usage updates: single-flight refresh, quota-gate recovery, and fresh reads for journal-based tools
