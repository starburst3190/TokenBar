//! Process-wide registry of the quota providers the user has switched off in
//! Settings. Written by `tb_set_disabled_providers`, read by `agent_usage::run`
//! before it builds the provider futures.
//!
//! **Why a registry and not a Swift-side filter.** Hiding a card in the UI is a
//! presentation decision; it does not stop the fetch, and the fetch is the part
//! that costs. One provider's fetch can hold up every other card, because
//! `run` joins them and returns only when the slowest finishes: the Antigravity
//! CLI fallback spawns a ~170MB binary that takes seconds, so a user who does
//! not use Antigravity was paying that on every publication for a card they did
//! not want. A filter that runs after the payload is built cannot recover that
//! time. This one runs before the future is created, so a disabled provider
//! costs nothing at all.
//!
//! A `RwLock` static rather than an env var, for the same reason
//! `extra_scan_paths` and `claude_config_dirs` are: the process is resident and
//! a Settings edit must take effect without a restart.
//!
//! The registry starts empty every launch — it is in-memory, not persisted here
//! — so Swift owns re-applying it from `UserDefaults` at launch and after every
//! edit. A process that never calls the setter fetches exactly the providers it
//! fetched before this module existed.

use std::collections::BTreeSet;
use std::sync::{LazyLock, RwLock};

/// Every provider id `agent_usage::run` can fetch. An id outside this set is
/// refused rather than stored: it would sit in the registry disabling nothing,
/// and a typo in a Settings value would look exactly like a working toggle.
pub(crate) const KNOWN_PROVIDERS: [&str; 8] = [
    "codex",
    "claude",
    "antigravity",
    "copilot",
    "grok",
    "grok-bot",
    "kiro",
    "opencode-go",
];

static DISABLED_PROVIDERS: LazyLock<RwLock<BTreeSet<String>>> =
    LazyLock::new(|| RwLock::new(BTreeSet::new()));

/// The provider ids currently switched off. Empty by default, which is the
/// pre-feature behavior exactly.
pub(crate) fn snapshot() -> BTreeSet<String> {
    DISABLED_PROVIDERS
        .read()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .clone()
}

/// Replace the whole registry from a JSON array of provider ids.
/// Full-replace, not merge: `[]` re-enables everything (the Settings rollback
/// path).
///
/// A repeated id is not an error the way a repeated Claude config directory is.
/// That one produces two cards writing one series; this one is a set, and
/// listing `claude` twice asks for the same state as listing it once. It is
/// reported as accepted and folded into the set.
pub(crate) fn set_from_json(raw: &str) -> Result<serde_json::Value, String> {
    let input: Vec<String> = serde_json::from_str(raw)
        .map_err(|e| format!("invalid disabled providers JSON: {}", e))?;

    let mut disabled: BTreeSet<String> = BTreeSet::new();
    let mut rejected: Vec<serde_json::Value> = Vec::new();
    for raw_id in input {
        if KNOWN_PROVIDERS.contains(&raw_id.as_str()) {
            disabled.insert(raw_id);
        } else {
            rejected.push(serde_json::json!({
                "id": raw_id,
                "reason": "unknown provider id",
            }));
        }
    }

    let disabled_count = disabled.len();
    *DISABLED_PROVIDERS
        .write()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = disabled;

    Ok(serde_json::json!({
        "disabledCount": disabled_count,
        "rejected": rejected,
    }))
}

/// One process-wide mutex for every test that reads or writes the static, so
/// parallel `cargo test` threads do not observe each other's registry.
#[cfg(test)]
pub(crate) static TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[cfg(test)]
pub(crate) fn reset_for_test() {
    *DISABLED_PROVIDERS
        .write()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = BTreeSet::new();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn registers_known_ids_and_reports_what_it_refused() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        reset_for_test();

        let result =
            set_from_json(r#"["antigravity", "grok", "Antigravity", "", "antigravity"]"#).unwrap();

        // Two distinct ids: the repeat folds into the set, the wrong-case and
        // empty ids are refused.
        assert_eq!(result["disabledCount"], 2);
        assert_eq!(
            snapshot(),
            BTreeSet::from(["antigravity".to_string(), "grok".to_string()])
        );
        let reasons: Vec<&str> = result["rejected"]
            .as_array()
            .unwrap()
            .iter()
            .map(|note| note["reason"].as_str().unwrap())
            .collect();
        assert_eq!(reasons, vec!["unknown provider id", "unknown provider id"]);

        reset_for_test();
    }

    #[test]
    fn full_replace_re_enables_everything() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        reset_for_test();

        set_from_json(r#"["antigravity"]"#).unwrap();
        assert!(!snapshot().is_empty());
        set_from_json("[]").unwrap();
        assert!(
            snapshot().is_empty(),
            "an empty array is the Settings rollback path and must re-enable \
             every provider, not merge into the previous set"
        );

        reset_for_test();
    }

    #[test]
    fn malformed_json_leaves_the_registry_untouched() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        reset_for_test();
        set_from_json(r#"["antigravity"]"#).unwrap();
        let error = set_from_json("{not json").unwrap_err();
        assert!(error.contains("invalid disabled providers JSON"), "{error}");
        assert_eq!(snapshot(), BTreeSet::from(["antigravity".to_string()]));
        reset_for_test();
    }

    #[test]
    fn every_known_provider_id_is_one_run_actually_fetches() {
        // The set is duplicated from `agent_usage::run`'s join by necessity —
        // the futures there are named, not enumerable. This pins the copy so a
        // provider renamed on one side cannot leave a toggle that silently
        // disables nothing.
        assert_eq!(
            KNOWN_PROVIDERS.len(),
            8,
            "a provider was added or removed in run(); update this list and the \
             Settings UI, or the new provider gets no toggle"
        );
    }
}
