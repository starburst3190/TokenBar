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
# Mirror cliff.toml's noise filter: app users don't care about the landing
# page, README, or CI plumbing, and an unfiltered list here would let the
# AI resurrect entries cliff dropped.
COMMITS="$(git log --no-merges --pretty='- %s' "$RANGE" 2>/dev/null \
  | grep -vE '^- (docs|chore|ci|build|test|style)(\(|:)' \
  | grep -vE '^- [a-z]+\((landing|readme|release|ci)\):' || true)"
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
# GitHub's tail sections, kept verbatim (never AI-rewritten); the head
# (What's Changed) is what feeds the AI prompt.
AUTO_TAIL="$(printf '%s\n' "$AUTO" | awk '/^## New Contributors/{f=1} f' || true)"
[[ -z "$AUTO_TAIL" ]] && AUTO_TAIL="$(printf '%s\n' "$AUTO" | grep '^\*\*Full Changelog' || true)"
AUTO_HEAD="$(printf '%s\n' "$AUTO" | awk '/^## New Contributors|^\*\*Full Changelog/{exit} {print}' || true)"

# PR titles + bodies (truncated): the richest context the AI gets — PR
# descriptions carry the why and the measurements that commit subjects lack.
PR_DETAILS=""
if [[ -n "$AUTO" && -n "${GH_TOKEN:-}" ]]; then
  PR_NUMS="$(printf '%s\n' "$AUTO" | grep -oE "${REPO}/pull/[0-9]+" | grep -oE '[0-9]+$' | sort -un | head -8 || true)"
  for n in $PR_NUMS; do
    PR_JSON="$(gh api "repos/${REPO}/pulls/${n}" 2>/dev/null || true)"
    [[ -z "$PR_JSON" ]] && continue
    PR_TITLE="$(printf '%s' "$PR_JSON" | jq -r '.title // empty')"
    PR_BODY="$(printf '%s' "$PR_JSON" | jq -r '.body // empty' | head -c 2500)"
    PR_DETAILS+="$(printf '### PR #%s: %s\n%s' "$n" "$PR_TITLE" "$PR_BODY")"$'\n\n'
  done
fi

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
# Manual override: a committed release-notes.override.txt is shipped verbatim
# (DeepSeek skipped) so an important release can carry hand-written notes. The
# "Thanks:" contributor line is still appended below.
if [[ -f release-notes.override.txt ]]; then
  cp release-notes.override.txt "$TXT"
elif [[ -n "${DEEPSEEK_API_KEY:-}" && -s "$TXT" ]]; then
  # read -d '' instead of $(cat <<EOF): bash 3.2 (macOS default) mis-parses
  # apostrophes inside heredocs nested in command substitution.
  read -r -d '' PROMPT <<PROMPT_EOF || true
You are writing the update notes shown in TokenBar ${VERSION}'s Sparkle update dialog. TokenBar is a native macOS menu-bar app that monitors local AI token usage and agent quotas.

Audience: end users deciding whether to install the update. Describe the user-visible effect of each change in plain language. Never mention internal identifiers: no function, file, struct, or flag names, no CI/build/refactor plumbing.

STRICT FORMAT: plain text only. No markdown of any kind: no #, no asterisks, no underscores, no backticks, no links, no tables. Headings are exactly "New:", "Improved:", "Fixes:" on their own lines, in that order; omit a heading when it has no items. Every item is one line starting with "- ". Output nothing else: no title, no intro, no closing line.

Content rules:
- Only describe changes present in the input. Never invent features, numbers, or effects.
- Do not guess specifics the input does not state — where a control lives, whether a window is resizable, what a default is. When unsure, stay general.
- Merge commits that belong to one feature into a single item; put the most impactful item first in each section.
- Performance work goes under "Improved:", stating the concrete effect (for example lower CPU or memory on large histories) when the input states it.
- Keep the whole output under 12 lines.

Grouped changelog:
${CLIFF}

Commit subjects:
${COMMITS}

Pull request details:
${PR_DETAILS}

Diff summary: ${STAT}
PROMPT_EOF
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
# Manual override: a committed release-notes.override.md is used as the body
# (DeepSeek skipped); the GitHub "New Contributors"/"Full Changelog" tail is
# still appended below.
if [[ -f release-notes.override.md ]]; then
  MD_BODY="$(cat release-notes.override.md)"
elif [[ -n "${DEEPSEEK_API_KEY:-}" ]]; then
  read -r -d '' MD_PROMPT <<PROMPT_EOF || true
Write the GitHub release notes for TokenBar ${VERSION}, a native macOS menu-bar app that monitors local AI token usage and agent quotas, in GitHub-flavored markdown.

Audience: end users and contributors reading the release page. Describe the user-visible effect of each change; never mention internal identifiers (function, file, struct, or flag names) or CI/build plumbing.

Structure:
- "## Highlights": include only when a change is clearly major (a big performance win, a headline feature). One bullet per highlight, up to two sentences, concrete — use the measurements from the pull request details when present, never invented ones.
- "## Changes" then "## Fixes": one "- " bullet per item, most impactful first. Merge commits that belong to one feature into a single bullet. Drop items with no user-visible effect.

Attribution: when an item comes from a pull request in the "What's Changed" list below, end its bullet with the PR link in the form [#N](https://github.com/${REPO}/pull/N) and, unless the author is @${OWNER}, append " — thanks @login". Items without a PR get no link and no credit.

Hard rules: only describe changes present in the input, never invent. Do not guess specifics the input does not state — where a control lives, whether a window is resizable, what a default is; when unsure, stay general. Do NOT include "New Contributors" or "Full Changelog" sections — they are appended separately. No title line, no intro, no closing line. Keep it tight.

Grouped changelog:
${CLIFF}

What's Changed (PR attribution):
${AUTO_HEAD}

Pull request details:
${PR_DETAILS}

Commit subjects:
${COMMITS}

Diff summary: ${STAT}
PROMPT_EOF
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
