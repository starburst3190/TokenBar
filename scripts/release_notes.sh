#!/bin/bash
# Generate release notes in two formats:
#
#   release-notes.txt  — plain text. Rendered by the Sparkle update dialog,
#                        embedded in appcast.xml, and shipped in the Tauri
#                        latest.json, so it must stay markdown-free. Ends
#                        with a deterministic "Thanks: @…" line when the
#                        release contains external PRs.
#   release-notes.md   — GitHub-flavored markdown for the GitHub release
#                        page: AI-polished sections with PR links and
#                        per-change contributor credit (openclaw-style),
#                        plus GitHub's own "New Contributors" and "Full
#                        Changelog" tail appended verbatim.
#
# Inputs (env): GITHUB_REF_NAME (tag), GITHUB_REPOSITORY (owner/repo),
# VERSION, GH_TOKEN, and optionally DEEPSEEK_API_KEY / DEEPSEEK_MODEL.
# Every network-dependent stage degrades: no DeepSeek → git-cliff/auto-notes
# verbatim; no auto-notes → cliff-only with no credit lines.
set -euo pipefail

TAG="${GITHUB_REF_NAME:?GITHUB_REF_NAME (tag) required}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY (owner/repo) required}"
VERSION="${VERSION:-${TAG#v}}"
OWNER="${REPO%%/*}"
TXT="release-notes.txt"
MD="release-notes.md"

# --- Deterministic baseline: grouped changelog for this tag. -----------------
if ! command -v git-cliff >/dev/null 2>&1; then
  brew install git-cliff
fi
CLIFF="$(git-cliff --config cliff.toml --current --strip all 2>/dev/null || true)"
[[ -z "$CLIFF" ]] && CLIFF="$(git-cliff --config cliff.toml --latest --strip all 2>/dev/null || true)"

PREV="$(git describe --tags --abbrev=0 "${TAG}^" 2>/dev/null || true)"
if [[ -n "$PREV" ]]; then RANGE="${PREV}..${TAG}"; else RANGE="$TAG"; fi
COMMITS="$(git log --no-merges --pretty='- %s' "$RANGE" 2>/dev/null || true)"
STAT="$(git diff --stat "$RANGE" 2>/dev/null | tail -1 || true)"

# --- GitHub auto-generated notes: PR attribution + New Contributors. ---------
AUTO=""
if [[ -n "${GH_TOKEN:-}" ]]; then
  if [[ -n "$PREV" ]]; then
    AUTO="$(gh api "repos/${REPO}/releases/generate-notes" \
      -f tag_name="$TAG" -f previous_tag_name="$PREV" --jq .body 2>/dev/null || true)"
  else
    AUTO="$(gh api "repos/${REPO}/releases/generate-notes" \
      -f tag_name="$TAG" --jq .body 2>/dev/null || true)"
  fi
fi
# External PR authors: everyone credited "by @login" except the owner and bots.
CONTRIB="$(printf '%s\n' "$AUTO" | grep -oE 'by @[A-Za-z0-9_-]+' | sed 's/^by //' \
  | sort -u | grep -vix "@${OWNER}" | grep -vi 'bot$' || true)"
# GitHub's tail sections, kept verbatim (never AI-rewritten).
AUTO_TAIL="$(printf '%s\n' "$AUTO" | awk '/^## New Contributors/{f=1} f' || true)"
[[ -z "$AUTO_TAIL" ]] && AUTO_TAIL="$(printf '%s\n' "$AUTO" | grep '^\*\*Full Changelog' || true)"

deepseek() {
  local prompt="$1"
  local model="${DEEPSEEK_MODEL:-deepseek-v4-pro}"
  local req resp
  req="$(jq -n --arg m "$model" --arg p "$prompt" \
    '{model:$m, stream:false, temperature:0.3, messages:[{role:"user", content:$p}]}')"
  resp="$(curl -sS --max-time 60 https://api.deepseek.com/chat/completions \
    -H "Authorization: Bearer ${DEEPSEEK_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$req" 2>/dev/null || true)"
  printf '%s' "$resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null || true
}

# --- Plain text for Sparkle / appcast / latest.json. --------------------------
printf '%s\n' "$CLIFF" > "$TXT"
if [[ -n "${DEEPSEEK_API_KEY:-}" && -s "$TXT" ]]; then
  PROMPT="$(printf 'Write concise, user-facing release notes for TokenBar %s, a native macOS menu-bar AI token-usage monitor. STRICT FORMAT RULES: plain text only — absolutely no markdown syntax (no #, no **, no _, no backticks, no links, no tables). Structure: group lines under plain headings that are exactly "New:" or "Fixes:" on their own line, each item on its own line starting with "- ". Nothing else. Be specific and factual — only describe changes present below, do not invent. Keep it tight.\n\nGrouped changelog:\n%s\n\nCommits:\n%s\n\nDiff summary: %s\n' \
    "$VERSION" "$CLIFF" "$COMMITS" "$STAT")"
  AI="$(deepseek "$PROMPT")"
  if [[ -n "$AI" ]]; then
    printf '%s\n' "$AI" > "$TXT"
  else
    echo "::warning::DeepSeek polish unavailable; using git-cliff changelog"
  fi
fi
if [[ -n "$CONTRIB" ]]; then
  printf '\nThanks: %s\n' "$(printf '%s\n' "$CONTRIB" | paste -sd, - | sed 's/,/, /g')" >> "$TXT"
fi
[[ -s "$TXT" ]] || printf 'TokenBar %s\n' "$VERSION" > "$TXT"

# --- Markdown for the GitHub release page. ------------------------------------
MD_BODY=""
if [[ -n "${DEEPSEEK_API_KEY:-}" ]]; then
  MD_PROMPT="$(printf 'Write user-facing release notes for TokenBar %s, a native macOS menu-bar AI token-usage monitor, in GitHub-flavored markdown. Structure: an optional "## Highlights" section (only when a change is clearly major), then "## Changes" and "## Fixes" with one "- " bullet per item. When an item matches a pull request in the "What'"'"'s Changed" list below, end its bullet with the PR link in the form [#N](https://github.com/%s/pull/N) and, unless the author is @%s, append "— thanks @login". Changes without a PR get no link and no credit. Be specific and factual — only describe changes present below, never invent. Do NOT include "New Contributors" or "Full Changelog" sections; they are appended separately. Keep it tight.\n\nGrouped changelog:\n%s\n\nWhat'"'"'s Changed (PR attribution):\n%s\n\nCommits:\n%s\n\nDiff summary: %s\n' \
    "$VERSION" "$REPO" "$OWNER" "$CLIFF" "$AUTO" "$COMMITS" "$STAT")"
  MD_BODY="$(deepseek "$MD_PROMPT")"
fi
if [[ -n "$MD_BODY" ]]; then
  printf '%s\n' "$MD_BODY" > "$MD"
  if [[ -n "$AUTO_TAIL" ]]; then
    printf '\n%s\n' "$AUTO_TAIL" >> "$MD"
  fi
elif [[ -n "$AUTO" ]]; then
  # No AI: GitHub's auto-notes already carry attribution + tail.
  printf '%s\n' "$AUTO" > "$MD"
else
  cp "$TXT" "$MD"
fi

echo "----- $TXT -----"
cat "$TXT"
echo "----- $MD -----"
cat "$MD"
