//! GitHub Copilot quota — ported from codexbar's CopilotUsageFetcher.
//!
//! Copilot has no token-usage log, but GitHub exposes a per-account quota at
//! `/copilot_internal/user` (premium interactions + chat, as percent-remaining
//! snapshots). We authenticate with the GitHub OAuth token opencode already
//! stored for its Copilot login (`~/.local/share/opencode/auth.json`), so the
//! card appears whenever Copilot is signed in there. Maps to `UsageWindow`s.

use crate::agent_account_scope::{self, AccountScope, AccountScopeError};
use crate::agent_quota_duration::{copilot_calendar_duration, DurationEvidence};
use crate::agent_usage::{clean_plan, AgentIdentity, UsageWindow};
use crate::opencode_integrations::GitHubCopilotCredential;
use chrono::{DateTime, NaiveDate, TimeZone, Utc};
use serde::Deserialize;

const COPILOT_USAGE_URL: &str = "https://api.github.com/copilot_internal/user";

pub(crate) struct CopilotData {
    pub identity: Option<AgentIdentity>,
    pub account_scope: Result<AccountScope, AccountScopeError>,
    pub windows: Vec<UsageWindow>,
}

#[derive(Debug, Deserialize)]
struct CopilotUser {
    #[serde(default)]
    copilot_plan: Option<String>,
    #[serde(default)]
    quota_reset_date: Option<String>,
    #[serde(default)]
    quota_snapshots: Option<QuotaSnapshots>,
}

#[derive(Debug, Deserialize)]
struct QuotaSnapshots {
    #[serde(
        default,
        deserialize_with = "crate::agent_usage::deserialize_optional_raw"
    )]
    premium_interactions: Option<QuotaSnapshot>,
    #[serde(
        default,
        deserialize_with = "crate::agent_usage::deserialize_optional_raw"
    )]
    chat: Option<QuotaSnapshot>,
}

#[derive(Debug, Deserialize)]
struct QuotaSnapshot {
    #[serde(default)]
    entitlement: f64,
    #[serde(default)]
    remaining: f64,
    #[serde(default)]
    percent_remaining: Option<f64>,
}

pub(crate) async fn fetch(
    now: DateTime<Utc>,
    credential: GitHubCopilotCredential,
) -> Result<CopilotData, String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| format!("build Copilot client: {e}"))?;
    let response = client
        .get(COPILOT_USAGE_URL)
        .header(
            reqwest::header::AUTHORIZATION,
            format!("token {}", credential.request_token),
        )
        .header(reqwest::header::ACCEPT, "application/json")
        .header(reqwest::header::USER_AGENT, "GitHubCopilotChat/0.26.7")
        .header("Editor-Version", "vscode/1.96.2")
        .header("Editor-Plugin-Version", "copilot-chat/0.26.7")
        .header("X-Github-Api-Version", "2025-04-01")
        .send()
        .await
        .map_err(|e| format!("Copilot usage request failed: {e}"))?;
    let status = response.status();
    if status == reqwest::StatusCode::UNAUTHORIZED || status == reqwest::StatusCode::FORBIDDEN {
        return Err("GitHub Copilot token expired or lacks access.".to_string());
    }
    if !status.is_success() {
        return Err(format!("Copilot usage API returned {}.", status.as_u16()));
    }

    let body = response
        .text()
        .await
        .map_err(|e| format!("read Copilot response: {e}"))?;
    let usage: CopilotUser =
        serde_json::from_str(&body).map_err(|e| format!("decode Copilot usage: {e}"))?;

    let (plan, windows) = map_user(usage, now);

    let account_scope = agent_account_scope::resolve_credential(
        "copilot",
        credential.semantic_source,
        &credential.canonical_location,
        &credential.marker,
    );
    Ok(CopilotData {
        identity: Some(AgentIdentity { email: None, plan }),
        account_scope,
        windows,
    })
}

fn map_user(usage: CopilotUser, now: DateTime<Utc>) -> (Option<String>, Vec<UsageWindow>) {
    let resets_at = usage.quota_reset_date.as_deref().and_then(parse_reset_date);
    let mut windows = Vec::new();
    if let Some(snapshots) = usage.quota_snapshots {
        if let Some(window) = snapshot_window_with_identity(
            "Premium",
            "premium_interactions.v1",
            snapshots.premium_interactions,
            resets_at,
            now,
        ) {
            windows.push(window);
        }
        if let Some(window) =
            snapshot_window_with_identity("Chat", "chat.v1", snapshots.chat, resets_at, now)
        {
            windows.push(window);
        }
    }
    let plan = usage
        .copilot_plan
        .filter(|plan| !plan.trim().is_empty())
        .map(clean_plan);
    (plan, windows)
}

fn snapshot_window_with_identity(
    label: &str,
    window_key: &str,
    snapshot: Option<QuotaSnapshot>,
    resets_at: Option<DateTime<Utc>>,
    now: DateTime<Utc>,
) -> Option<UsageWindow> {
    let snapshot = snapshot?;
    // Skip explicit zero-entitlement placeholders (no usable quota signal).
    if snapshot.entitlement == 0.0
        && snapshot.remaining == 0.0
        && snapshot.percent_remaining.is_none()
    {
        return None;
    }
    let percent_remaining = snapshot
        .percent_remaining
        .or_else(|| {
            (snapshot.entitlement > 0.0)
                .then(|| (snapshot.remaining / snapshot.entitlement) * 100.0)
        })
        .filter(|percent| percent.is_finite() && (0.0..=100.0).contains(percent))?;
    let contract_duration = resets_at
        .and_then(|reset| copilot_calendar_duration(reset.timestamp()))
        .map(DurationEvidence::contract);
    Some(
        UsageWindow::from_provider_used_percent(
            label.to_string(),
            100.0 - percent_remaining,
            resets_at,
            now,
        )
        .with_identity(
            window_key,
            Some(window_key.to_string()),
            None,
            contract_duration,
        ),
    )
}

#[cfg(test)]
fn snapshot_window(
    label: &str,
    snapshot: Option<QuotaSnapshot>,
    resets_at: Option<DateTime<Utc>>,
    now: DateTime<Utc>,
) -> Option<UsageWindow> {
    let window_key = match label {
        "Premium" => "premium_interactions.v1",
        "Chat" => "chat.v1",
        _ => "row.copilot.unknown.v1",
    };
    snapshot_window_with_identity(label, window_key, snapshot, resets_at, now)
}

/// Copilot reports `quota_reset_date` as a bare `YYYY-MM-DD`; treat it as UTC midnight.
fn parse_reset_date(value: &str) -> Option<DateTime<Utc>> {
    let date = NaiveDate::parse_from_str(value.trim(), "%Y-%m-%d").ok()?;
    Utc.from_utc_datetime(&date.and_hms_opt(0, 0, 0)?).into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_premium_and_chat_snapshots() {
        let now = Utc::now();
        let body = r#"{
            "copilot_plan": "individual",
            "quota_reset_date": "2026-07-01",
            "quota_snapshots": {
                "premium_interactions": { "entitlement": 300, "remaining": 90, "percent_remaining": 30 },
                "chat": { "entitlement": 0, "remaining": 0 }
            }
        }"#;
        let usage: CopilotUser = serde_json::from_str(body).unwrap();
        let snaps = usage.quota_snapshots.unwrap();
        let premium = snapshot_window("Premium", snaps.premium_interactions, None, now).unwrap();
        assert!((premium.remaining_for_test() - 30.0).abs() < 0.01);
        // chat is a zero-entitlement placeholder → skipped
        assert!(snapshot_window("Chat", snaps.chat, None, now).is_none());
    }

    #[test]
    fn stage4_copilot_maps_shared_reset_to_both_quota_cards() {
        let now = Utc.timestamp_opt(1_751_328_000, 0).single().unwrap();
        let usage: CopilotUser = serde_json::from_str(
            r#"{
                "copilot_plan": "individual",
                "quota_reset_date": "2026-08-01",
                "quota_snapshots": {
                    "premium_interactions": {
                        "entitlement": 300,
                        "remaining": 90,
                        "percent_remaining": 30
                    },
                    "chat": {
                        "entitlement": 100,
                        "remaining": 75
                    }
                }
            }"#,
        )
        .unwrap();
        let (plan, windows) = map_user(usage, now);
        assert_eq!(plan.as_deref(), Some("Individual"));
        assert_eq!(windows.len(), 2);
        let premium = &windows[0];
        let chat = &windows[1];

        assert_eq!(premium.label_for_test(), "Premium");
        assert_eq!(chat.label_for_test(), "Chat");
        assert_eq!(
            premium.resets_at_for_test(),
            Some("2026-08-01T00:00:00.000Z")
        );
        assert_eq!(chat.resets_at_for_test(), premium.resets_at_for_test());
        assert_eq!(
            premium.window_minutes_for_test(),
            Some(44_640),
            "first-of-month reset uses the exact preceding calendar month"
        );
        assert_eq!(chat.window_minutes_for_test(), Some(44_640));
        assert_eq!(
            premium.pace_window_key_for_test(),
            Some("premium_interactions.v1")
        );
        assert_eq!(chat.pace_window_key_for_test(), Some("chat.v1"));
        for window in &windows {
            let wire = serde_json::to_value(window).unwrap();
            assert_eq!(wire["paceStatus"]["durationSource"], "contract");
            assert_eq!(wire["paceStatus"]["durationSeconds"], 2_678_400);
        }

        let non_calendar_reset = parse_reset_date("2026-08-15").unwrap();
        let observed = snapshot_window(
            "Premium",
            Some(QuotaSnapshot {
                entitlement: 300.0,
                remaining: 90.0,
                percent_remaining: Some(30.0),
            }),
            Some(non_calendar_reset),
            now,
        )
        .unwrap();
        assert_eq!(
            observed.window_minutes_for_test(),
            None,
            "copilot.premium.observed-fallback"
        );
    }

    #[test]
    fn rejects_invalid_remaining_percentages_before_wire() {
        let now = Utc::now();
        assert!(snapshot_window(
            "Premium",
            Some(QuotaSnapshot {
                entitlement: 300.0,
                remaining: 90.0,
                percent_remaining: Some(101.0),
            }),
            None,
            now,
        )
        .is_none());
        assert!(snapshot_window(
            "Chat",
            Some(QuotaSnapshot {
                entitlement: 100.0,
                remaining: f64::NAN,
                percent_remaining: None,
            }),
            None,
            now,
        )
        .is_none());
    }

    #[test]
    fn malformed_snapshot_percentage_does_not_poison_valid_sibling() {
        let now = Utc.timestamp_opt(1_751_328_000, 0).single().unwrap();
        for invalid in ["1e400", r#""NaN""#] {
            let usage: CopilotUser = serde_json::from_str(&format!(
                r#"{{
                    "quota_reset_date": "2026-08-01",
                    "quota_snapshots": {{
                        "premium_interactions": {{
                            "entitlement": 300,
                            "remaining": 90,
                            "percent_remaining": {invalid}
                        }},
                        "chat": {{
                            "entitlement": 100,
                            "remaining": 75,
                            "percent_remaining": 75
                        }}
                    }}
                }}"#
            ))
            .unwrap();
            let (_, windows) = map_user(usage, now);
            assert_eq!(windows.len(), 1);
            assert_eq!(windows[0].label_for_test(), "Chat");
            assert!((windows[0].remaining_for_test() - 75.0).abs() < 0.01);
        }
    }

    #[test]
    fn parses_reset_date() {
        assert!(parse_reset_date("2026-07-01").is_some());
        assert!(parse_reset_date("not-a-date").is_none());
    }
}
