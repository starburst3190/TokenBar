//! Opaque account identity for provider quota history.
//!
//! The installation key lives in the non-synchronizing macOS Keychain. Raw
//! provider identifiers and credential markers are reduced to domain-separated
//! HMACs before authenticated metadata is persisted. Provider adapters only get
//! an opaque scope or a typed failure; no raw identity crosses into history.

use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use base64::Engine as _;
use fs2::FileExt as _;
use hmac::{Hmac, Mac as _};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read as _, Write as _};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{LazyLock, Mutex, MutexGuard};
use std::time::{SystemTime, UNIX_EPOCH};

type HmacSha256 = Hmac<Sha256>;

const KEYCHAIN_SERVICE: &str = "com.nyanako.tokenbar.account-scope.v1";
const KEYCHAIN_ACCOUNT: &str = "installation-key";
const METADATA_FILE: &str = "quota-account-scope-v1.json";
const METADATA_LOCK_FILE: &str = "quota-account-scope-v1.lock";
const V3_HISTORY_FILE: &str = "quota-pace-history-v3.json";
const METADATA_SCHEMA_VERSION: u32 = 1;
const INSTALLATION_KEY_BYTES: usize = 32;
const LINEAGE_ID_BYTES: usize = 16;
const DIGEST_BYTES: usize = 32;
const ERR_SEC_SUCCESS: i32 = 0;
const ERR_SEC_DUPLICATE_ITEM: i32 = -25_299;
const ERR_SEC_ITEM_NOT_FOUND: i32 = -25_300;

static METADATA_PROCESS_LOCK: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));
static CODEX_REFRESH_LOCK: Mutex<()> = Mutex::new(());
static CLAUDE_REFRESH_LOCK: Mutex<()> = Mutex::new(());
static GROK_REFRESH_LOCK: Mutex<()> = Mutex::new(());
static ANTIGRAVITY_REFRESH_LOCK: Mutex<()> = Mutex::new(());
static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, PartialEq, Eq)]
pub(crate) struct AccountScope(String);

impl AccountScope {
    pub(crate) fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Debug for AccountScope {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("AccountScope(<opaque>)")
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum AuthoritativeIdKind {
    Email,
    OpaqueId,
}

impl AuthoritativeIdKind {
    fn domain_value(self) -> &'static str {
        match self {
            Self::Email => "email",
            Self::OpaqueId => "opaque-id",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum AccountScopeError {
    NoTrustedEvidence,
    InvalidEvidence,
    UnsupportedPlatform,
    KeychainUnavailable,
    InvalidInstallationKey,
    OrphanedArtifacts,
    RandomUnavailable,
    StorageUnavailable,
    MetadataLock,
    MetadataRead,
    MetadataCorrupt,
    MetadataConflict,
    MetadataWrite,
    QuarantineFailed,
}

impl std::fmt::Display for AccountScopeError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let message = match self {
            Self::NoTrustedEvidence => "no trusted account evidence",
            Self::InvalidEvidence => "invalid account evidence",
            Self::UnsupportedPlatform => "secure account scope is unavailable on this platform",
            Self::KeychainUnavailable => "installation key is unavailable",
            Self::InvalidInstallationKey => "installation key has an invalid length",
            Self::OrphanedArtifacts => "account-scope artifacts were orphaned after key loss",
            Self::RandomUnavailable => "secure randomness is unavailable",
            Self::StorageUnavailable => "account-scope storage is unavailable",
            Self::MetadataLock => "account-scope metadata lock failed",
            Self::MetadataRead => "account-scope metadata could not be read",
            Self::MetadataCorrupt => "account-scope metadata failed authentication",
            Self::MetadataConflict => "account-scope metadata contains conflicting bindings",
            Self::MetadataWrite => "account-scope metadata could not be saved",
            Self::QuarantineFailed => "account-scope metadata could not be quarantined",
        };
        formatter.write_str(message)
    }
}

impl std::error::Error for AccountScopeError {}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum KeyAddOutcome {
    Added,
    AlreadyExists,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FsOperation {
    CreateDirectory,
    InspectArtifacts,
    OpenMetadataLock,
    AcquireMetadataLock,
    ReadMetadata,
    QuarantineMetadata,
    CreateTemp,
    WriteTemp,
    SyncTemp,
    ReplaceMetadata,
    SyncDirectory,
    OpenRefreshLock,
    AcquireRefreshLock,
}

trait Backend {
    fn keychain_read(&self) -> Result<Option<Vec<u8>>, AccountScopeError>;
    fn keychain_add_if_absent(&self, key: &[u8]) -> Result<KeyAddOutcome, AccountScopeError>;
    fn random_bytes(&self, length: usize) -> Result<Vec<u8>, AccountScopeError>;
    fn storage_dir(&self) -> Result<PathBuf, AccountScopeError>;
    fn now_seconds(&self) -> i64;
    fn before_fs(&self, _operation: FsOperation) -> io::Result<()> {
        Ok(())
    }
}

#[derive(Debug, Clone, Copy)]
struct SystemBackend;

#[cfg(target_os = "macos")]
fn installation_key_item_query(
    keychain: &security_framework::os::macos::keychain::SecKeychain,
    value: Option<&[u8]>,
) -> core_foundation::dictionary::CFDictionary {
    use core_foundation::array::CFArray;
    use core_foundation::base::{TCFType as _, ToVoid as _};
    use core_foundation::boolean::CFBoolean;
    use core_foundation::data::CFData;
    use core_foundation::dictionary::CFMutableDictionary;
    use core_foundation::string::{CFString, CFStringRef};
    use security_framework_sys::item::{
        kSecAttrAccount, kSecAttrService, kSecAttrSynchronizable, kSecClass,
        kSecClassGenericPassword, kSecMatchSearchList, kSecReturnData, kSecUseAuthenticationUI,
        kSecUseKeychain, kSecValueData,
    };

    extern "C" {
        #[link_name = "kSecUseAuthenticationUIFail"]
        static K_SEC_USE_AUTHENTICATION_UI_FAIL: CFStringRef;
    }

    let service = CFString::new(KEYCHAIN_SERVICE);
    let account = CFString::new(KEYCHAIN_ACCOUNT);
    let mut query: CFMutableDictionary = CFMutableDictionary::new();
    unsafe {
        query.add(&kSecClass.to_void(), &kSecClassGenericPassword.to_void());
        query.add(&kSecAttrService.to_void(), &service.to_void());
        query.add(&kSecAttrAccount.to_void(), &account.to_void());
        query.add(
            &kSecAttrSynchronizable.to_void(),
            &CFBoolean::false_value().to_void(),
        );
        // Per-operation failure is required here: the menu app must never allow
        // Security.framework to display authentication or legacy ACL UI.
        query.add(
            &kSecUseAuthenticationUI.to_void(),
            &K_SEC_USE_AUTHENTICATION_UI_FAIL.to_void(),
        );
        match value {
            Some(value) => {
                let data = CFData::from_buffer(value);
                query.add(&kSecUseKeychain.to_void(), &keychain.as_CFType().to_void());
                query.add(&kSecValueData.to_void(), &data.to_void());
            }
            None => {
                let search_list = CFArray::from_CFTypes(std::slice::from_ref(keychain));
                query.add(
                    &kSecMatchSearchList.to_void(),
                    &search_list.as_CFType().to_void(),
                );
                query.add(
                    &kSecReturnData.to_void(),
                    &CFBoolean::true_value().to_void(),
                );
            }
        }
    }
    query.to_immutable()
}

impl Backend for SystemBackend {
    #[cfg(target_os = "macos")]
    fn keychain_read(&self) -> Result<Option<Vec<u8>>, AccountScopeError> {
        use core_foundation::base::{CFGetTypeID, CFRelease, CFTypeRef, TCFType as _};
        use core_foundation::data::CFData;
        use security_framework::os::macos::keychain::SecKeychain;
        use security_framework_sys::keychain_item::SecItemCopyMatching;

        let keychain =
            SecKeychain::default().map_err(|_| AccountScopeError::KeychainUnavailable)?;
        let query = installation_key_item_query(&keychain, None);
        let mut result: CFTypeRef = std::ptr::null();
        let status = unsafe { SecItemCopyMatching(query.as_concrete_TypeRef(), &mut result) };
        if status != ERR_SEC_SUCCESS {
            if !result.is_null() {
                unsafe { CFRelease(result) };
            }
            return if status == ERR_SEC_ITEM_NOT_FOUND {
                Ok(None)
            } else {
                Err(AccountScopeError::KeychainUnavailable)
            };
        }
        if result.is_null() {
            return Err(AccountScopeError::KeychainUnavailable);
        }
        if unsafe { CFGetTypeID(result) } != CFData::type_id() {
            unsafe { CFRelease(result) };
            return Err(AccountScopeError::KeychainUnavailable);
        }
        let data = unsafe { CFData::wrap_under_create_rule(result.cast()) };
        Ok(Some(data.bytes().to_vec()))
    }

    #[cfg(not(target_os = "macos"))]
    fn keychain_read(&self) -> Result<Option<Vec<u8>>, AccountScopeError> {
        Err(AccountScopeError::UnsupportedPlatform)
    }

    #[cfg(target_os = "macos")]
    fn keychain_add_if_absent(&self, key: &[u8]) -> Result<KeyAddOutcome, AccountScopeError> {
        use core_foundation::base::TCFType as _;
        use security_framework::os::macos::keychain::SecKeychain;
        use security_framework_sys::keychain_item::SecItemAdd;

        // SecItemAdd remains add-only and targets the explicit default file
        // keychain. A duplicate is never updated, so concurrent creators cannot
        // replace the winner's installation key.
        let keychain =
            SecKeychain::default().map_err(|_| AccountScopeError::KeychainUnavailable)?;
        let query = installation_key_item_query(&keychain, Some(key));
        match unsafe { SecItemAdd(query.as_concrete_TypeRef(), std::ptr::null_mut()) } {
            ERR_SEC_SUCCESS => Ok(KeyAddOutcome::Added),
            ERR_SEC_DUPLICATE_ITEM => Ok(KeyAddOutcome::AlreadyExists),
            _ => Err(AccountScopeError::KeychainUnavailable),
        }
    }

    #[cfg(not(target_os = "macos"))]
    fn keychain_add_if_absent(&self, _key: &[u8]) -> Result<KeyAddOutcome, AccountScopeError> {
        Err(AccountScopeError::UnsupportedPlatform)
    }

    #[cfg(target_os = "macos")]
    fn random_bytes(&self, length: usize) -> Result<Vec<u8>, AccountScopeError> {
        let mut bytes = vec![0_u8; length];
        security_framework::random::SecRandom::default()
            .copy_bytes(&mut bytes)
            .map_err(|_| AccountScopeError::RandomUnavailable)?;
        Ok(bytes)
    }

    #[cfg(not(target_os = "macos"))]
    fn random_bytes(&self, _length: usize) -> Result<Vec<u8>, AccountScopeError> {
        Err(AccountScopeError::UnsupportedPlatform)
    }

    fn storage_dir(&self) -> Result<PathBuf, AccountScopeError> {
        dirs::data_dir()
            .map(|path| path.join("com.nyanako.tokenbar"))
            .ok_or(AccountScopeError::StorageUnavailable)
    }

    fn now_seconds(&self) -> i64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_secs().min(i64::MAX as u64) as i64)
            .unwrap_or(0)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct MetadataEnvelope {
    schema_version: u32,
    payload_bytes_base64: String,
    payload_mac: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct MetadataPayload {
    bindings: Vec<Binding>,
    current_fingerprint_by_slot: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Binding {
    provider: String,
    slot_digest: String,
    credential_fingerprint: String,
    random_lineage_id: String,
}

pub(crate) fn resolve_authoritative(
    provider: &str,
    kind: AuthoritativeIdKind,
    identifier: &str,
) -> Result<AccountScope, AccountScopeError> {
    resolve_authoritative_with(
        &SystemBackend,
        &METADATA_PROCESS_LOCK,
        provider,
        kind,
        identifier,
    )
}

pub(crate) fn resolve_credential(
    provider: &str,
    semantic_source: &str,
    canonical_location: &str,
    raw_marker: &[u8],
) -> Result<AccountScope, AccountScopeError> {
    resolve_credential_with(
        &SystemBackend,
        &METADATA_PROCESS_LOCK,
        provider,
        semantic_source,
        canonical_location,
        raw_marker,
    )
}

pub(crate) fn canonical_file_location(
    path: &Path,
    record: Option<&str>,
) -> Result<String, AccountScopeError> {
    let canonical = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    let path = canonical
        .to_str()
        .ok_or(AccountScopeError::InvalidEvidence)?;
    let mut location = path.to_string();
    if let Some(record) = record.filter(|value| !value.is_empty()) {
        location.push('\0');
        location.push_str(record);
    }
    Ok(location)
}

fn resolve_authoritative_with<B: Backend>(
    backend: &B,
    process_lock: &Mutex<()>,
    provider: &str,
    kind: AuthoritativeIdKind,
    identifier: &str,
) -> Result<AccountScope, AccountScopeError> {
    let provider = validate_text(provider)?;
    let normalized = match kind {
        AuthoritativeIdKind::Email => identifier.trim().to_ascii_lowercase(),
        AuthoritativeIdKind::OpaqueId => identifier.trim().to_string(),
    };
    if normalized.is_empty() {
        return Err(AccountScopeError::NoTrustedEvidence);
    }
    let key = ensure_installation_key(backend, process_lock)?;
    let directory = ensure_storage_dir(backend)?;
    with_metadata_lock(backend, process_lock, &directory, || {
        load_metadata(backend, &directory, &key)?;
        Ok(())
    })?;
    scope_from_authoritative(&key, provider, kind, normalized.as_bytes())
}

fn resolve_credential_with<B: Backend>(
    backend: &B,
    process_lock: &Mutex<()>,
    provider: &str,
    semantic_source: &str,
    canonical_location: &str,
    raw_marker: &[u8],
) -> Result<AccountScope, AccountScopeError> {
    validate_credential_evidence(provider, semantic_source, canonical_location, raw_marker)?;
    let key = ensure_installation_key(backend, process_lock)?;
    bind_current_credential(
        backend,
        process_lock,
        &key,
        provider,
        semantic_source,
        canonical_location,
        raw_marker,
    )
}

fn validate_credential_evidence<'a>(
    provider: &'a str,
    semantic_source: &str,
    canonical_location: &str,
    raw_marker: &[u8],
) -> Result<&'a str, AccountScopeError> {
    let provider = validate_text(provider)?;
    validate_text(semantic_source)?;
    validate_text(canonical_location)?;
    if raw_marker.is_empty() {
        return Err(AccountScopeError::NoTrustedEvidence);
    }
    Ok(provider)
}

fn validate_text(value: &str) -> Result<&str, AccountScopeError> {
    if value.is_empty() || value.len() > u32::MAX as usize {
        Err(AccountScopeError::InvalidEvidence)
    } else {
        Ok(value)
    }
}

fn ensure_installation_key<B: Backend>(
    backend: &B,
    process_lock: &Mutex<()>,
) -> Result<[u8; INSTALLATION_KEY_BYTES], AccountScopeError> {
    if let Some(bytes) = backend.keychain_read()? {
        return installation_key_from_bytes(&bytes);
    }

    let directory = ensure_storage_dir(backend)?;
    backend
        .before_fs(FsOperation::InspectArtifacts)
        .map_err(|_| AccountScopeError::StorageUnavailable)?;
    let metadata_path = directory.join(METADATA_FILE);
    let history_path = directory.join(V3_HISTORY_FILE);
    let metadata_exists = regular_artifact_exists(&metadata_path)
        .map_err(|_| AccountScopeError::StorageUnavailable)?;
    let history_exists = regular_artifact_exists(&history_path)
        .map_err(|_| AccountScopeError::StorageUnavailable)?;
    let had_artifacts = metadata_exists || history_exists;

    if metadata_exists {
        // Another process may have won the add-only Keychain race and persisted
        // metadata after this process's initial missing read. Re-read the winner
        // outside the metadata lock, then authenticate the observed metadata with
        // that key before treating it as orphaned.
        if let Some(winner) = backend.keychain_read()? {
            let winner = installation_key_from_bytes(&winner)?;
            let metadata_is_valid = with_metadata_lock(backend, process_lock, &directory, || {
                if !regular_artifact_exists(&metadata_path)
                    .map_err(|_| AccountScopeError::MetadataRead)?
                {
                    return Ok(false);
                }
                load_metadata(backend, &directory, &winner)?;
                Ok(true)
            })?;
            if metadata_is_valid {
                return Ok(winner);
            }
            return Err(AccountScopeError::OrphanedArtifacts);
        }

        with_metadata_lock(backend, process_lock, &directory, || {
            if regular_artifact_exists(&metadata_path)
                .map_err(|_| AccountScopeError::QuarantineFailed)?
            {
                quarantine_metadata(backend, &metadata_path, "orphaned")?;
            }
            Ok(())
        })?;
    }

    let generated = backend.random_bytes(INSTALLATION_KEY_BYTES)?;
    let generated = installation_key_from_bytes(&generated)?;
    match backend.keychain_add_if_absent(&generated)? {
        KeyAddOutcome::Added => {}
        KeyAddOutcome::AlreadyExists => {
            let winner = backend
                .keychain_read()?
                .ok_or(AccountScopeError::KeychainUnavailable)?;
            let _ = installation_key_from_bytes(&winner)?;
        }
    }

    if had_artifacts {
        return Err(AccountScopeError::OrphanedArtifacts);
    }

    let winner = backend
        .keychain_read()?
        .ok_or(AccountScopeError::KeychainUnavailable)?;
    installation_key_from_bytes(&winner)
}

fn installation_key_from_bytes(
    bytes: &[u8],
) -> Result<[u8; INSTALLATION_KEY_BYTES], AccountScopeError> {
    bytes
        .try_into()
        .map_err(|_| AccountScopeError::InvalidInstallationKey)
}

fn bind_current_credential<B: Backend>(
    backend: &B,
    process_lock: &Mutex<()>,
    key: &[u8; INSTALLATION_KEY_BYTES],
    provider: &str,
    semantic_source: &str,
    canonical_location: &str,
    raw_marker: &[u8],
) -> Result<AccountScope, AccountScopeError> {
    let fingerprint = credential_fingerprint(key, provider, raw_marker)?;
    let slot = slot_digest(key, provider, semantic_source, canonical_location)?;
    let directory = ensure_storage_dir(backend)?;
    with_metadata_lock(backend, process_lock, &directory, || {
        let mut payload = load_metadata(backend, &directory, key)?;
        let lineage = match lineage_for_fingerprint(&payload, provider, &fingerprint)? {
            Some(lineage) => lineage,
            None => encode_lineage_id(&backend.random_bytes(LINEAGE_ID_BYTES)?)?,
        };
        add_binding(&mut payload, provider, &slot, &fingerprint, &lineage)?;
        payload
            .current_fingerprint_by_slot
            .insert(slot, fingerprint);
        validate_payload(&payload)?;
        save_metadata(backend, &directory, key, &payload)?;
        scope_from_lineage(key, provider, &lineage)
    })
}

fn transfer_credential_with<B: Backend>(
    backend: &B,
    process_lock: &Mutex<()>,
    key: &[u8; INSTALLATION_KEY_BYTES],
    provider: &str,
    semantic_source: &str,
    canonical_location: &str,
    old_marker: &[u8],
    new_marker: &[u8],
) -> Result<AccountScope, AccountScopeError> {
    validate_credential_evidence(provider, semantic_source, canonical_location, old_marker)?;
    if new_marker.is_empty() {
        return Err(AccountScopeError::NoTrustedEvidence);
    }
    let old_fingerprint = credential_fingerprint(key, provider, old_marker)?;
    let new_fingerprint = credential_fingerprint(key, provider, new_marker)?;
    let slot = slot_digest(key, provider, semantic_source, canonical_location)?;
    let directory = ensure_storage_dir(backend)?;
    with_metadata_lock(backend, process_lock, &directory, || {
        let mut payload = load_metadata(backend, &directory, key)?;
        let old_lineage = lineage_for_fingerprint(&payload, provider, &old_fingerprint)?;
        let new_lineage = lineage_for_fingerprint(&payload, provider, &new_fingerprint)?;
        let lineage = match (old_lineage, new_lineage) {
            (Some(old), Some(new)) if old != new => {
                return Err(AccountScopeError::MetadataConflict)
            }
            (Some(lineage), _) | (_, Some(lineage)) => lineage,
            (None, None) => encode_lineage_id(&backend.random_bytes(LINEAGE_ID_BYTES)?)?,
        };
        add_binding(&mut payload, provider, &slot, &old_fingerprint, &lineage)?;
        add_binding(&mut payload, provider, &slot, &new_fingerprint, &lineage)?;
        payload
            .current_fingerprint_by_slot
            .insert(slot, new_fingerprint);
        validate_payload(&payload)?;
        save_metadata(backend, &directory, key, &payload)?;
        scope_from_lineage(key, provider, &lineage)
    })
}

fn add_binding(
    payload: &mut MetadataPayload,
    provider: &str,
    slot_digest: &str,
    credential_fingerprint: &str,
    lineage: &str,
) -> Result<(), AccountScopeError> {
    for binding in &payload.bindings {
        if binding.provider == provider
            && binding.credential_fingerprint == credential_fingerprint
            && binding.random_lineage_id != lineage
        {
            return Err(AccountScopeError::MetadataConflict);
        }
        if binding.provider == provider
            && binding.slot_digest == slot_digest
            && binding.credential_fingerprint == credential_fingerprint
        {
            return if binding.random_lineage_id == lineage {
                Ok(())
            } else {
                Err(AccountScopeError::MetadataConflict)
            };
        }
    }
    payload.bindings.push(Binding {
        provider: provider.to_string(),
        slot_digest: slot_digest.to_string(),
        credential_fingerprint: credential_fingerprint.to_string(),
        random_lineage_id: lineage.to_string(),
    });
    Ok(())
}

fn lineage_for_fingerprint(
    payload: &MetadataPayload,
    provider: &str,
    fingerprint: &str,
) -> Result<Option<String>, AccountScopeError> {
    let mut lineage: Option<&str> = None;
    for binding in payload.bindings.iter().filter(|binding| {
        binding.provider == provider && binding.credential_fingerprint == fingerprint
    }) {
        match lineage {
            None => lineage = Some(&binding.random_lineage_id),
            Some(existing) if existing == binding.random_lineage_id => {}
            Some(_) => return Err(AccountScopeError::MetadataConflict),
        }
    }
    Ok(lineage.map(str::to_string))
}

fn load_metadata<B: Backend>(
    backend: &B,
    directory: &Path,
    key: &[u8; INSTALLATION_KEY_BYTES],
) -> Result<MetadataPayload, AccountScopeError> {
    backend
        .before_fs(FsOperation::ReadMetadata)
        .map_err(|_| AccountScopeError::MetadataRead)?;
    let path = directory.join(METADATA_FILE);
    let Some(bytes) = read_owner_only(&path).map_err(|_| AccountScopeError::MetadataRead)? else {
        return Ok(MetadataPayload::default());
    };
    match decode_metadata(key, &bytes) {
        Ok(payload) => Ok(payload),
        Err(AccountScopeError::MetadataConflict) => Err(AccountScopeError::MetadataConflict),
        Err(_) => {
            quarantine_metadata(backend, &path, "corrupt")?;
            Err(AccountScopeError::MetadataCorrupt)
        }
    }
}

fn decode_metadata(
    key: &[u8; INSTALLATION_KEY_BYTES],
    bytes: &[u8],
) -> Result<MetadataPayload, AccountScopeError> {
    let envelope: MetadataEnvelope =
        serde_json::from_slice(bytes).map_err(|_| AccountScopeError::MetadataCorrupt)?;
    if envelope.schema_version != METADATA_SCHEMA_VERSION {
        return Err(AccountScopeError::MetadataCorrupt);
    }
    let payload_bytes = STANDARD
        .decode(envelope.payload_bytes_base64.as_bytes())
        .map_err(|_| AccountScopeError::MetadataCorrupt)?;
    let stored_mac = URL_SAFE_NO_PAD
        .decode(envelope.payload_mac.as_bytes())
        .map_err(|_| AccountScopeError::MetadataCorrupt)?;
    if stored_mac.len() != DIGEST_BYTES {
        return Err(AccountScopeError::MetadataCorrupt);
    }
    let metadata_key = metadata_mac_key(key)?;
    let encoded = encode_fields(&[payload_bytes.as_slice()])?;
    let mut mac = HmacSha256::new_from_slice(&metadata_key)
        .map_err(|_| AccountScopeError::MetadataCorrupt)?;
    mac.update(&encoded);
    mac.verify_slice(&stored_mac)
        .map_err(|_| AccountScopeError::MetadataCorrupt)?;
    let payload: MetadataPayload =
        serde_json::from_slice(&payload_bytes).map_err(|_| AccountScopeError::MetadataCorrupt)?;
    validate_payload(&payload)?;
    Ok(payload)
}

fn save_metadata<B: Backend>(
    backend: &B,
    directory: &Path,
    key: &[u8; INSTALLATION_KEY_BYTES],
    payload: &MetadataPayload,
) -> Result<(), AccountScopeError> {
    validate_payload(payload)?;
    let mut payload = payload.clone();
    payload.bindings.sort_by(|left, right| {
        left.provider
            .cmp(&right.provider)
            .then(left.slot_digest.cmp(&right.slot_digest))
            .then(
                left.credential_fingerprint
                    .cmp(&right.credential_fingerprint),
            )
            .then(left.random_lineage_id.cmp(&right.random_lineage_id))
    });
    let payload_bytes =
        serde_json::to_vec(&payload).map_err(|_| AccountScopeError::MetadataWrite)?;
    let metadata_key = metadata_mac_key(key)?;
    let payload_mac = hmac_digest(&metadata_key, &[payload_bytes.as_slice()])?;
    let envelope = MetadataEnvelope {
        schema_version: METADATA_SCHEMA_VERSION,
        payload_bytes_base64: STANDARD.encode(&payload_bytes),
        payload_mac: encode_digest(&payload_mac),
    };
    let bytes =
        serde_json::to_vec_pretty(&envelope).map_err(|_| AccountScopeError::MetadataWrite)?;
    save_atomic(backend, directory, &directory.join(METADATA_FILE), &bytes)
}

fn validate_payload(payload: &MetadataPayload) -> Result<(), AccountScopeError> {
    let mut exact = BTreeSet::new();
    let mut fingerprint_lineages: BTreeMap<(&str, &str), &str> = BTreeMap::new();
    let mut slot_providers: BTreeMap<&str, &str> = BTreeMap::new();
    for binding in &payload.bindings {
        validate_text(&binding.provider).map_err(|_| AccountScopeError::MetadataConflict)?;
        validate_digest_text(&binding.slot_digest)?;
        validate_digest_text(&binding.credential_fingerprint)?;
        validate_lineage_text(&binding.random_lineage_id)?;
        if !exact.insert((
            binding.provider.as_str(),
            binding.slot_digest.as_str(),
            binding.credential_fingerprint.as_str(),
        )) {
            return Err(AccountScopeError::MetadataConflict);
        }
        match fingerprint_lineages.insert(
            (
                binding.provider.as_str(),
                binding.credential_fingerprint.as_str(),
            ),
            binding.random_lineage_id.as_str(),
        ) {
            Some(existing) if existing != binding.random_lineage_id => {
                return Err(AccountScopeError::MetadataConflict)
            }
            _ => {}
        }
        match slot_providers.insert(binding.slot_digest.as_str(), binding.provider.as_str()) {
            Some(existing) if existing != binding.provider => {
                return Err(AccountScopeError::MetadataConflict)
            }
            _ => {}
        }
    }

    for (slot, fingerprint) in &payload.current_fingerprint_by_slot {
        validate_digest_text(slot)?;
        validate_digest_text(fingerprint)?;
        let matches = payload
            .bindings
            .iter()
            .filter(|binding| {
                binding.slot_digest == *slot && binding.credential_fingerprint == *fingerprint
            })
            .count();
        if matches != 1 {
            return Err(AccountScopeError::MetadataConflict);
        }
    }
    Ok(())
}

fn validate_digest_text(value: &str) -> Result<(), AccountScopeError> {
    let decoded = URL_SAFE_NO_PAD
        .decode(value.as_bytes())
        .map_err(|_| AccountScopeError::MetadataConflict)?;
    if decoded.len() != DIGEST_BYTES || URL_SAFE_NO_PAD.encode(decoded) != value {
        return Err(AccountScopeError::MetadataConflict);
    }
    Ok(())
}

fn validate_lineage_text(value: &str) -> Result<(), AccountScopeError> {
    let decoded = URL_SAFE_NO_PAD
        .decode(value.as_bytes())
        .map_err(|_| AccountScopeError::MetadataConflict)?;
    if decoded.len() != LINEAGE_ID_BYTES || URL_SAFE_NO_PAD.encode(decoded) != value {
        return Err(AccountScopeError::MetadataConflict);
    }
    Ok(())
}

fn quarantine_metadata<B: Backend>(
    backend: &B,
    path: &Path,
    reason: &str,
) -> Result<PathBuf, AccountScopeError> {
    quarantine_metadata_with(
        backend,
        path,
        reason,
        |source, candidate| fs::hard_link(source, candidate),
        |source| fs::remove_file(source),
    )
}

fn quarantine_metadata_with<B, L, U>(
    backend: &B,
    path: &Path,
    reason: &str,
    mut link: L,
    unlink: U,
) -> Result<PathBuf, AccountScopeError>
where
    B: Backend,
    L: FnMut(&Path, &Path) -> io::Result<()>,
    U: Fn(&Path) -> io::Result<()>,
{
    backend
        .before_fs(FsOperation::QuarantineMetadata)
        .map_err(|_| AccountScopeError::QuarantineFailed)?;
    let source = open_existing_owner_only(path)
        .map_err(|_| AccountScopeError::QuarantineFailed)?
        .ok_or(AccountScopeError::QuarantineFailed)?;
    let directory = path.parent().ok_or(AccountScopeError::QuarantineFailed)?;
    let now = backend.now_seconds();
    for suffix in 0..=u32::MAX {
        let name = if suffix == 0 {
            format!("quota-account-scope-v1.{reason}-{now}.json")
        } else {
            format!("quota-account-scope-v1.{reason}-{now}.{suffix}.json")
        };
        let candidate = directory.join(name);
        if verify_open_regular_file(path, &source).is_err() {
            return Err(AccountScopeError::QuarantineFailed);
        }
        match link(path, &candidate) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(_) => return Err(AccountScopeError::QuarantineFailed),
        }
        if verify_open_regular_file(path, &source).is_err()
            || verify_open_regular_file(&candidate, &source).is_err()
        {
            rollback_quarantine_link(&candidate, &source);
            return Err(AccountScopeError::QuarantineFailed);
        }
        if unlink(path).is_err() {
            rollback_quarantine_link(&candidate, &source);
            return Err(AccountScopeError::QuarantineFailed);
        }
        sync_directory(backend, directory).map_err(|_| AccountScopeError::QuarantineFailed)?;
        return Ok(candidate);
    }
    Err(AccountScopeError::QuarantineFailed)
}

fn save_atomic<B: Backend>(
    backend: &B,
    directory: &Path,
    path: &Path,
    bytes: &[u8],
) -> Result<(), AccountScopeError> {
    let counter = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
    let temp = directory.join(format!(
        ".{METADATA_FILE}.tmp-{}-{counter}",
        std::process::id()
    ));
    let staged = (|| -> Result<(), AccountScopeError> {
        backend
            .before_fs(FsOperation::CreateTemp)
            .map_err(|_| AccountScopeError::MetadataWrite)?;
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt as _;
            options.mode(0o600);
        }
        let mut file = options
            .open(&temp)
            .map_err(|_| AccountScopeError::MetadataWrite)?;
        backend
            .before_fs(FsOperation::WriteTemp)
            .map_err(|_| AccountScopeError::MetadataWrite)?;
        file.write_all(bytes)
            .map_err(|_| AccountScopeError::MetadataWrite)?;
        file.flush().map_err(|_| AccountScopeError::MetadataWrite)?;
        backend
            .before_fs(FsOperation::SyncTemp)
            .map_err(|_| AccountScopeError::MetadataWrite)?;
        file.sync_all()
            .map_err(|_| AccountScopeError::MetadataWrite)?;
        drop(file);
        backend
            .before_fs(FsOperation::ReplaceMetadata)
            .map_err(|_| AccountScopeError::MetadataWrite)?;
        tokscale_core::fs_atomic::replace_file(&temp, path)
            .map_err(|_| AccountScopeError::MetadataWrite)?;
        sync_directory(backend, directory).map_err(|_| AccountScopeError::MetadataWrite)
    })();
    if staged.is_err() {
        let _ = fs::remove_file(&temp);
    }
    staged
}

fn ensure_storage_dir<B: Backend>(backend: &B) -> Result<PathBuf, AccountScopeError> {
    let directory = backend.storage_dir()?;
    backend
        .before_fs(FsOperation::CreateDirectory)
        .map_err(|_| AccountScopeError::StorageUnavailable)?;
    ensure_real_directory(&directory).map_err(|_| AccountScopeError::StorageUnavailable)?;
    Ok(directory)
}

fn with_metadata_lock<B: Backend, T>(
    backend: &B,
    process_lock: &Mutex<()>,
    directory: &Path,
    body: impl FnOnce() -> Result<T, AccountScopeError>,
) -> Result<T, AccountScopeError> {
    let _process_guard = process_lock
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let lock_path = directory.join(METADATA_LOCK_FILE);
    backend
        .before_fs(FsOperation::OpenMetadataLock)
        .map_err(|_| AccountScopeError::MetadataLock)?;
    let lock_file = open_owner_only(&lock_path).map_err(|_| AccountScopeError::MetadataLock)?;
    backend
        .before_fs(FsOperation::AcquireMetadataLock)
        .map_err(|_| AccountScopeError::MetadataLock)?;
    lock_file
        .lock_exclusive()
        .map_err(|_| AccountScopeError::MetadataLock)?;
    let result = body();
    let unlock = fs2::FileExt::unlock(&lock_file).map_err(|_| AccountScopeError::MetadataLock);
    match (result, unlock) {
        (Err(error), _) => Err(error),
        (Ok(_), Err(error)) => Err(error),
        (Ok(value), Ok(())) => Ok(value),
    }
}

fn ensure_real_directory(directory: &Path) -> io::Result<()> {
    match fs::symlink_metadata(directory) {
        Ok(metadata) if metadata.file_type().is_dir() => {}
        Ok(_) => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "account-scope storage is not a real directory",
            ))
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            fs::create_dir_all(directory)?;
        }
        Err(error) => return Err(error),
    }

    let path_metadata = fs::symlink_metadata(directory)?;
    if !path_metadata.file_type().is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "account-scope storage is not a real directory",
        ));
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        let file = File::open(directory)?;
        verify_open_directory(directory, &file)?;
        file.set_permissions(fs::Permissions::from_mode(0o700))?;
        verify_open_directory(directory, &file)?;
    }
    Ok(())
}

fn open_owner_only(path: &Path) -> io::Result<File> {
    let mut create = OpenOptions::new();
    create.read(true).write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        create.mode(0o600);
    }
    match create.open(path) {
        Ok(file) => secure_open_regular_file(path, file),
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
            require_regular_file_path(path)?;
            let file = OpenOptions::new().read(true).write(true).open(path)?;
            secure_open_regular_file(path, file)
        }
        Err(error) => Err(error),
    }
}

fn open_existing_owner_only(path: &Path) -> io::Result<Option<File>> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_file() => {}
        Ok(_) => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "account-scope artifact is not a regular file",
            ))
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    }
    let file = OpenOptions::new().read(true).open(path)?;
    secure_open_regular_file(path, file).map(Some)
}

fn read_owner_only(path: &Path) -> io::Result<Option<Vec<u8>>> {
    let Some(mut file) = open_existing_owner_only(path)? else {
        return Ok(None);
    };
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)?;
    verify_open_regular_file(path, &file)?;
    Ok(Some(bytes))
}

fn require_regular_file_path(path: &Path) -> io::Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_file() {
        Ok(())
    } else {
        Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "account-scope artifact is not a regular file",
        ))
    }
}

fn regular_artifact_exists(path: &Path) -> io::Result<bool> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_file() => Ok(true),
        Ok(_) => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "account-scope artifact is not a regular file",
        )),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error),
    }
}

fn secure_open_regular_file(path: &Path, file: File) -> io::Result<File> {
    verify_open_regular_file(path, &file)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        file.set_permissions(fs::Permissions::from_mode(0o600))?;
    }
    verify_open_regular_file(path, &file)?;
    Ok(file)
}

fn verify_open_regular_file(path: &Path, file: &File) -> io::Result<()> {
    let file_metadata = file.metadata()?;
    let path_metadata = fs::symlink_metadata(path)?;
    if !file_metadata.file_type().is_file() || !path_metadata.file_type().is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "account-scope artifact is not a regular file",
        ));
    }
    #[cfg(unix)]
    if !same_file(&file_metadata, &path_metadata) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "account-scope artifact changed while opening",
        ));
    }
    Ok(())
}

#[cfg(unix)]
fn verify_open_directory(path: &Path, file: &File) -> io::Result<()> {
    let file_metadata = file.metadata()?;
    let path_metadata = fs::symlink_metadata(path)?;
    if !file_metadata.file_type().is_dir()
        || !path_metadata.file_type().is_dir()
        || !same_file(&file_metadata, &path_metadata)
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "account-scope storage changed while opening",
        ));
    }
    Ok(())
}

#[cfg(unix)]
fn same_file(left: &fs::Metadata, right: &fs::Metadata) -> bool {
    use std::os::unix::fs::MetadataExt as _;
    left.dev() == right.dev() && left.ino() == right.ino()
}

fn rollback_quarantine_link(path: &Path, source: &File) {
    if verify_open_regular_file(path, source).is_ok() {
        let _ = fs::remove_file(path);
    }
}

fn open_refresh_lock_file<B: Backend>(
    backend: &B,
    directory: &Path,
    provider: &str,
) -> Result<File, AccountScopeError> {
    validate_text(provider)?;
    backend
        .before_fs(FsOperation::OpenRefreshLock)
        .map_err(|_| AccountScopeError::MetadataLock)?;
    let file = open_owner_only(&directory.join(format!("quota-auth-refresh-{provider}.lock")))
        .map_err(|_| AccountScopeError::MetadataLock)?;
    backend
        .before_fs(FsOperation::AcquireRefreshLock)
        .map_err(|_| AccountScopeError::MetadataLock)?;
    file.lock_exclusive()
        .map_err(|_| AccountScopeError::MetadataLock)?;
    Ok(file)
}

fn sync_directory<B: Backend>(backend: &B, directory: &Path) -> io::Result<()> {
    backend.before_fs(FsOperation::SyncDirectory)?;
    File::open(directory)?.sync_all()
}

fn scope_from_authoritative(
    key: &[u8; INSTALLATION_KEY_BYTES],
    provider: &str,
    kind: AuthoritativeIdKind,
    normalized_identifier: &[u8],
) -> Result<AccountScope, AccountScopeError> {
    let digest = hmac_digest(
        key,
        &[
            b"scope-id-v1",
            provider.as_bytes(),
            kind.domain_value().as_bytes(),
            normalized_identifier,
        ],
    )?;
    Ok(AccountScope(encode_digest(&digest)))
}

fn credential_fingerprint(
    key: &[u8; INSTALLATION_KEY_BYTES],
    provider: &str,
    marker: &[u8],
) -> Result<String, AccountScopeError> {
    hmac_digest(key, &[b"credential-v1", provider.as_bytes(), marker])
        .map(|digest| encode_digest(&digest))
}

fn slot_digest(
    key: &[u8; INSTALLATION_KEY_BYTES],
    provider: &str,
    semantic_source: &str,
    canonical_location: &str,
) -> Result<String, AccountScopeError> {
    hmac_digest(
        key,
        &[
            b"slot-v1",
            provider.as_bytes(),
            semantic_source.as_bytes(),
            canonical_location.as_bytes(),
        ],
    )
    .map(|digest| encode_digest(&digest))
}

fn scope_from_lineage(
    key: &[u8; INSTALLATION_KEY_BYTES],
    provider: &str,
    encoded_lineage: &str,
) -> Result<AccountScope, AccountScopeError> {
    let lineage = URL_SAFE_NO_PAD
        .decode(encoded_lineage.as_bytes())
        .map_err(|_| AccountScopeError::MetadataConflict)?;
    if lineage.len() != LINEAGE_ID_BYTES {
        return Err(AccountScopeError::MetadataConflict);
    }
    let digest = hmac_digest(
        key,
        &[b"scope-lineage-v1", provider.as_bytes(), lineage.as_slice()],
    )?;
    Ok(AccountScope(encode_digest(&digest)))
}

fn metadata_mac_key(
    key: &[u8; INSTALLATION_KEY_BYTES],
) -> Result<[u8; DIGEST_BYTES], AccountScopeError> {
    hmac_digest(key, &[b"metadata-key-v1"])
}

fn encode_lineage_id(bytes: &[u8]) -> Result<String, AccountScopeError> {
    if bytes.len() != LINEAGE_ID_BYTES {
        return Err(AccountScopeError::RandomUnavailable);
    }
    Ok(URL_SAFE_NO_PAD.encode(bytes))
}

fn encode_digest(bytes: &[u8; DIGEST_BYTES]) -> String {
    URL_SAFE_NO_PAD.encode(bytes)
}

fn hmac_digest(key: &[u8], fields: &[&[u8]]) -> Result<[u8; DIGEST_BYTES], AccountScopeError> {
    let encoded = encode_fields(fields)?;
    let mut mac =
        HmacSha256::new_from_slice(key).map_err(|_| AccountScopeError::InvalidEvidence)?;
    mac.update(&encoded);
    Ok(mac.finalize().into_bytes().into())
}

fn encode_fields(fields: &[&[u8]]) -> Result<Vec<u8>, AccountScopeError> {
    let capacity = fields.iter().try_fold(0_usize, |total, field| {
        let _ = u32::try_from(field.len()).map_err(|_| AccountScopeError::InvalidEvidence)?;
        total
            .checked_add(4)
            .and_then(|value| value.checked_add(field.len()))
            .ok_or(AccountScopeError::InvalidEvidence)
    })?;
    let mut encoded = Vec::with_capacity(capacity);
    for field in fields {
        let length = u32::try_from(field.len()).map_err(|_| AccountScopeError::InvalidEvidence)?;
        encoded.extend_from_slice(&length.to_be_bytes());
        encoded.extend_from_slice(field);
    }
    Ok(encoded)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RefreshCheckpoint {
    Reloaded,
    NetworkReturned,
    MetadataHandled,
    CredentialsPersisted,
}

pub(crate) trait RefreshScopeTransaction {
    fn resolve_current(
        &self,
        semantic_source: &str,
        canonical_location: &str,
        marker: &[u8],
    ) -> Result<AccountScope, AccountScopeError>;

    fn transfer(
        &self,
        semantic_source: &str,
        canonical_location: &str,
        old_marker: &[u8],
        new_marker: &[u8],
    ) -> Result<AccountScope, AccountScopeError>;
}

pub(crate) struct RefreshTransaction {
    provider: &'static str,
    key: Result<[u8; INSTALLATION_KEY_BYTES], AccountScopeError>,
    _process_guard: MutexGuard<'static, ()>,
    lock_file: File,
}

pub(crate) fn begin_refresh(
    provider: &'static str,
) -> Result<RefreshTransaction, AccountScopeError> {
    let backend = SystemBackend;
    // The installation-key read (and any key-loss recovery) must complete before
    // the provider refresh lock is acquired. No Keychain call occurs below this
    // point while the refresh transaction is alive.
    let key = ensure_installation_key(&backend, &METADATA_PROCESS_LOCK);
    let directory = ensure_storage_dir(&backend)?;
    let process_guard = refresh_process_lock(provider)?
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let lock_file = open_refresh_lock_file(&backend, &directory, provider)?;
    Ok(RefreshTransaction {
        provider,
        key,
        _process_guard: process_guard,
        lock_file,
    })
}

impl RefreshTransaction {
    pub(crate) fn resolve_current(
        &self,
        semantic_source: &str,
        canonical_location: &str,
        marker: &[u8],
    ) -> Result<AccountScope, AccountScopeError> {
        validate_credential_evidence(self.provider, semantic_source, canonical_location, marker)?;
        let key = self.key.as_ref().map_err(|error| *error)?;
        bind_current_credential(
            &SystemBackend,
            &METADATA_PROCESS_LOCK,
            key,
            self.provider,
            semantic_source,
            canonical_location,
            marker,
        )
    }

    pub(crate) fn transfer(
        &self,
        semantic_source: &str,
        canonical_location: &str,
        old_marker: &[u8],
        new_marker: &[u8],
    ) -> Result<AccountScope, AccountScopeError> {
        let key = self.key.as_ref().map_err(|error| *error)?;
        transfer_credential_with(
            &SystemBackend,
            &METADATA_PROCESS_LOCK,
            key,
            self.provider,
            semantic_source,
            canonical_location,
            old_marker,
            new_marker,
        )
    }
}

impl RefreshScopeTransaction for RefreshTransaction {
    fn resolve_current(
        &self,
        semantic_source: &str,
        canonical_location: &str,
        marker: &[u8],
    ) -> Result<AccountScope, AccountScopeError> {
        RefreshTransaction::resolve_current(self, semantic_source, canonical_location, marker)
    }

    fn transfer(
        &self,
        semantic_source: &str,
        canonical_location: &str,
        old_marker: &[u8],
        new_marker: &[u8],
    ) -> Result<AccountScope, AccountScopeError> {
        RefreshTransaction::transfer(
            self,
            semantic_source,
            canonical_location,
            old_marker,
            new_marker,
        )
    }
}

impl Drop for RefreshTransaction {
    fn drop(&mut self) {
        let _ = fs2::FileExt::unlock(&self.lock_file);
    }
}

fn refresh_process_lock(provider: &str) -> Result<&'static Mutex<()>, AccountScopeError> {
    match provider {
        "codex" => Ok(&CODEX_REFRESH_LOCK),
        "claude" => Ok(&CLAUDE_REFRESH_LOCK),
        "grok" => Ok(&GROK_REFRESH_LOCK),
        "antigravity" => Ok(&ANTIGRAVITY_REFRESH_LOCK),
        _ => Err(AccountScopeError::InvalidEvidence),
    }
}

#[cfg(test)]
pub(crate) mod test_support {
    use super::*;
    use std::collections::VecDeque;
    use std::sync::{Arc, Barrier};

    #[derive(Clone)]
    pub(super) struct TestBackend {
        pub(super) directory: PathBuf,
        pub(super) state: Arc<Mutex<TestState>>,
        pub(super) missing_read_barrier: Option<Arc<Barrier>>,
        pub(super) inspect_artifacts_barrier: Option<Arc<Barrier>>,
    }

    pub(super) struct TestState {
        pub(super) key: Result<Option<Vec<u8>>, AccountScopeError>,
        pub(super) random: VecDeque<Vec<u8>>,
        pub(super) fail_fs_once: Option<FsOperation>,
        pub(super) key_adds: usize,
        pub(super) events: Vec<&'static str>,
        pub(super) now: i64,
    }

    impl TestBackend {
        pub(super) fn new(tag: &str) -> Self {
            let directory = std::env::temp_dir().join(format!(
                "tb-account-scope-{tag}-{}-{}",
                std::process::id(),
                TEMP_COUNTER.fetch_add(1, Ordering::Relaxed)
            ));
            let _ = fs::remove_dir_all(&directory);
            Self {
                directory,
                state: Arc::new(Mutex::new(TestState {
                    key: Ok(None),
                    random: VecDeque::from([
                        vec![0x11; INSTALLATION_KEY_BYTES],
                        vec![0x21; LINEAGE_ID_BYTES],
                        vec![0x22; LINEAGE_ID_BYTES],
                        vec![0x23; LINEAGE_ID_BYTES],
                        vec![0x24; LINEAGE_ID_BYTES],
                    ]),
                    fail_fs_once: None,
                    key_adds: 0,
                    events: Vec::new(),
                    now: 1_752_710_400,
                })),
                missing_read_barrier: None,
                inspect_artifacts_barrier: None,
            }
        }

        pub(super) fn with_key(self, key: Vec<u8>) -> Self {
            self.state.lock().unwrap().key = Ok(Some(key));
            self
        }

        pub(super) fn fail_fs(&self, operation: FsOperation) {
            self.state.lock().unwrap().fail_fs_once = Some(operation);
        }

        pub(super) fn cleanup(&self) {
            let _ = fs::remove_dir_all(&self.directory);
        }
    }

    impl Backend for TestBackend {
        fn keychain_read(&self) -> Result<Option<Vec<u8>>, AccountScopeError> {
            let result = self.state.lock().unwrap().key.clone();
            if matches!(result, Ok(None)) {
                if let Some(barrier) = &self.missing_read_barrier {
                    barrier.wait();
                }
            }
            result
        }

        fn keychain_add_if_absent(&self, key: &[u8]) -> Result<KeyAddOutcome, AccountScopeError> {
            let mut state = self.state.lock().unwrap();
            state.key_adds += 1;
            match &state.key {
                Ok(None) => {
                    state.key = Ok(Some(key.to_vec()));
                    Ok(KeyAddOutcome::Added)
                }
                Ok(Some(_)) => Ok(KeyAddOutcome::AlreadyExists),
                Err(error) => Err(*error),
            }
        }

        fn random_bytes(&self, length: usize) -> Result<Vec<u8>, AccountScopeError> {
            let mut state = self.state.lock().unwrap();
            let index = state
                .random
                .iter()
                .position(|bytes| bytes.len() == length)
                .ok_or(AccountScopeError::RandomUnavailable)?;
            state
                .random
                .remove(index)
                .ok_or(AccountScopeError::RandomUnavailable)
        }

        fn storage_dir(&self) -> Result<PathBuf, AccountScopeError> {
            Ok(self.directory.clone())
        }

        fn now_seconds(&self) -> i64 {
            self.state.lock().unwrap().now
        }

        fn before_fs(&self, operation: FsOperation) -> io::Result<()> {
            {
                let mut state = self.state.lock().unwrap();
                state.events.push(match operation {
                    FsOperation::CreateDirectory => "create-directory",
                    FsOperation::InspectArtifacts => "inspect-artifacts",
                    FsOperation::OpenMetadataLock => "open-metadata-lock",
                    FsOperation::AcquireMetadataLock => "acquire-metadata-lock",
                    FsOperation::ReadMetadata => "read-metadata",
                    FsOperation::QuarantineMetadata => "quarantine-metadata",
                    FsOperation::CreateTemp => "create-temp",
                    FsOperation::WriteTemp => "write-temp",
                    FsOperation::SyncTemp => "sync-temp",
                    FsOperation::ReplaceMetadata => "replace-metadata",
                    FsOperation::SyncDirectory => "sync-directory",
                    FsOperation::OpenRefreshLock => "open-refresh-lock",
                    FsOperation::AcquireRefreshLock => "acquire-refresh-lock",
                });
                if state.fail_fs_once == Some(operation) {
                    state.fail_fs_once = None;
                    return Err(io::Error::other("injected failure"));
                }
            }
            if operation == FsOperation::InspectArtifacts {
                if let Some(barrier) = &self.inspect_artifacts_barrier {
                    barrier.wait();
                }
            }
            Ok(())
        }
    }

    pub(crate) struct TestRefreshScope {
        backend: TestBackend,
        process_lock: Mutex<()>,
        provider: &'static str,
    }

    impl TestRefreshScope {
        pub(crate) fn new(provider: &'static str, tag: &str) -> Self {
            Self {
                backend: TestBackend::new(tag).with_key(vec![0x11; INSTALLATION_KEY_BYTES]),
                process_lock: Mutex::new(()),
                provider,
            }
        }

        pub(crate) fn root(&self) -> &Path {
            &self.backend.directory
        }

        pub(crate) fn metadata_bytes(&self) -> Vec<u8> {
            fs::read(self.backend.directory.join(METADATA_FILE)).unwrap()
        }

        pub(crate) fn fail_metadata_save(&self) {
            self.backend.fail_fs(FsOperation::ReplaceMetadata);
        }

        pub(crate) fn cleanup(&self) {
            self.backend.cleanup();
        }
    }

    impl RefreshScopeTransaction for TestRefreshScope {
        fn resolve_current(
            &self,
            semantic_source: &str,
            canonical_location: &str,
            marker: &[u8],
        ) -> Result<AccountScope, AccountScopeError> {
            resolve_credential_with(
                &self.backend,
                &self.process_lock,
                self.provider,
                semantic_source,
                canonical_location,
                marker,
            )
        }

        fn transfer(
            &self,
            semantic_source: &str,
            canonical_location: &str,
            old_marker: &[u8],
            new_marker: &[u8],
        ) -> Result<AccountScope, AccountScopeError> {
            let key_bytes = self
                .backend
                .keychain_read()?
                .ok_or(AccountScopeError::KeychainUnavailable)?;
            let key = installation_key_from_bytes(&key_bytes)?;
            transfer_credential_with(
                &self.backend,
                &self.process_lock,
                &key,
                self.provider,
                semantic_source,
                canonical_location,
                old_marker,
                new_marker,
            )
        }
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::*;
    use super::*;
    use sha2::{Digest as _, Sha256};
    use std::collections::VecDeque;
    use std::sync::{Arc, Barrier};
    use std::thread;

    fn resolve_test(
        backend: &TestBackend,
        process_lock: &Mutex<()>,
        marker: &[u8],
    ) -> Result<AccountScope, AccountScopeError> {
        resolve_credential_with(
            backend,
            process_lock,
            "claude",
            "fixture-source",
            "fixture-location",
            marker,
        )
    }

    fn metadata_bytes(backend: &TestBackend) -> Vec<u8> {
        fs::read(backend.directory.join(METADATA_FILE)).unwrap()
    }

    #[cfg(unix)]
    fn unix_mode(path: &Path) -> u32 {
        use std::os::unix::fs::PermissionsExt as _;
        fs::metadata(path).unwrap().permissions().mode() & 0o777
    }

    #[test]
    fn length_prefix_and_hmac_known_vectors_are_stable_and_domain_separated() {
        let key: [u8; INSTALLATION_KEY_BYTES] = std::array::from_fn(|index| index as u8);
        assert_eq!(
            encode_fields(&[b"ab", b"c"]).unwrap(),
            vec![0, 0, 0, 2, b'a', b'b', 0, 0, 0, 1, b'c']
        );
        assert_ne!(
            encode_fields(&[b"ab", b"c"]).unwrap(),
            encode_fields(&[b"a", b"bc"]).unwrap()
        );
        assert_eq!(
            scope_from_authoritative(
                &key,
                "antigravity",
                AuthoritativeIdKind::Email,
                b"user@example.com"
            )
            .unwrap()
            .as_str(),
            "sK_jjcbkOzChAgJHtE1pPpjKU4AEg_MiNut8GaL1woM"
        );
        assert_eq!(
            credential_fingerprint(&key, "claude", b"fixture-token").unwrap(),
            "JCR4YryCMKNOeEjYQEHYrXfanXoq24YteoyJyoiSPtc"
        );
        assert_eq!(
            slot_digest(&key, "claude", "environment", "CLAUDE_CODE_OAUTH_TOKEN").unwrap(),
            "1nTOH8E7TUly1xvVG2sbUI_C0AzksMJ3iOj9vt2PNj8"
        );
        let lineage = URL_SAFE_NO_PAD.encode([0xA5; LINEAGE_ID_BYTES]);
        assert_eq!(
            scope_from_lineage(&key, "claude", &lineage)
                .unwrap()
                .as_str(),
            "QsM_upNybGz6Hljs9K4Qj5uIuBI1HtHpfmPahxb1SEw"
        );
        assert_ne!(
            credential_fingerprint(&key, "claude", b"fixture-token").unwrap(),
            encode_digest(&hmac_digest(&key, &[b"slot-v1", b"claude", b"fixture-token"]).unwrap())
        );
    }

    #[test]
    fn different_installation_keys_cannot_link_the_same_identifier() {
        let one = scope_from_authoritative(
            &[1; INSTALLATION_KEY_BYTES],
            "codex",
            AuthoritativeIdKind::OpaqueId,
            b"acct-123",
        )
        .unwrap();
        let two = scope_from_authoritative(
            &[2; INSTALLATION_KEY_BYTES],
            "codex",
            AuthoritativeIdKind::OpaqueId,
            b"acct-123",
        )
        .unwrap();
        assert_ne!(one, two);
    }

    #[test]
    fn authoritative_normalization_is_frozen() {
        let backend = TestBackend::new("authoritative-normalization");
        let lock = Mutex::new(());
        let mixed = resolve_authoritative_with(
            &backend,
            &lock,
            "antigravity",
            AuthoritativeIdKind::Email,
            "  User@Example.COM ",
        )
        .unwrap();
        let normalized = resolve_authoritative_with(
            &backend,
            &lock,
            "antigravity",
            AuthoritativeIdKind::Email,
            "user@example.com",
        )
        .unwrap();
        assert_eq!(mixed, normalized);
        let id_upper = resolve_authoritative_with(
            &backend,
            &lock,
            "codex",
            AuthoritativeIdKind::OpaqueId,
            " Account-A ",
        )
        .unwrap();
        let id_lower = resolve_authoritative_with(
            &backend,
            &lock,
            "codex",
            AuthoritativeIdKind::OpaqueId,
            "account-a",
        )
        .unwrap();
        assert_ne!(id_upper, id_lower);
        backend.cleanup();
    }

    #[test]
    fn same_marker_reuses_lineage_across_sources_but_external_replacement_fragments() {
        let backend = TestBackend::new("lineage-rules");
        let lock = Mutex::new(());
        let first =
            resolve_credential_with(&backend, &lock, "claude", "file", "/fixture/a", b"token-a")
                .unwrap();
        let cross_source = resolve_credential_with(
            &backend,
            &lock,
            "claude",
            "keychain",
            "service-a",
            b"token-a",
        )
        .unwrap();
        let replacement =
            resolve_credential_with(&backend, &lock, "claude", "file", "/fixture/a", b"token-b")
                .unwrap();
        assert_eq!(first, cross_source);
        assert_ne!(first, replacement);
        backend.cleanup();
    }

    #[test]
    fn refresh_crash_points_keep_old_and_new_recoverable_without_partial_metadata() {
        let backend = TestBackend::new("refresh-crashes");
        let lock = Mutex::new(());
        let old = resolve_test(&backend, &lock, b"old-refresh").unwrap();
        let key = installation_key_from_bytes(backend.keychain_read().unwrap().as_deref().unwrap())
            .unwrap();

        // Crash before metadata save: credentials are still old and metadata is unchanged.
        let before = metadata_bytes(&backend);
        assert_eq!(resolve_test(&backend, &lock, b"old-refresh").unwrap(), old);
        assert_eq!(metadata_bytes(&backend), before);

        // Crash after metadata save but before credential save: either credential resolves.
        let transferred = transfer_credential_with(
            &backend,
            &lock,
            &key,
            "claude",
            "fixture-source",
            "fixture-location",
            b"old-refresh",
            b"new-refresh",
        )
        .unwrap();
        assert_eq!(transferred, old);
        assert_eq!(resolve_test(&backend, &lock, b"old-refresh").unwrap(), old);
        assert_eq!(resolve_test(&backend, &lock, b"new-refresh").unwrap(), old);

        // Crash after credential save: the new marker still resolves the same lineage.
        assert_eq!(resolve_test(&backend, &lock, b"new-refresh").unwrap(), old);
        backend.cleanup();
    }

    #[test]
    fn refresh_reuses_an_existing_new_fingerprint_lineage_when_old_is_unseen() {
        let backend = TestBackend::new("refresh-known-new");
        let lock = Mutex::new(());
        let known_new = resolve_credential_with(
            &backend,
            &lock,
            "claude",
            "keychain",
            "known-slot",
            b"new-refresh",
        )
        .unwrap();
        let key = installation_key_from_bytes(backend.keychain_read().unwrap().as_deref().unwrap())
            .unwrap();

        let transferred = transfer_credential_with(
            &backend,
            &lock,
            &key,
            "claude",
            "file",
            "refreshing-slot",
            b"previously-unseen-old-refresh",
            b"new-refresh",
        )
        .unwrap();

        assert_eq!(transferred, known_new);
        assert_eq!(
            resolve_credential_with(
                &backend,
                &lock,
                "claude",
                "file",
                "refreshing-slot",
                b"previously-unseen-old-refresh",
            )
            .unwrap(),
            known_new
        );
        backend.cleanup();
    }

    #[test]
    fn metadata_save_failure_is_unavailable_and_preserves_last_valid_bytes() {
        let backend = TestBackend::new("save-failure");
        let lock = Mutex::new(());
        let old = resolve_test(&backend, &lock, b"old").unwrap();
        let before = metadata_bytes(&backend);
        let key = installation_key_from_bytes(backend.keychain_read().unwrap().as_deref().unwrap())
            .unwrap();
        backend.fail_fs(FsOperation::ReplaceMetadata);
        assert_eq!(
            transfer_credential_with(
                &backend,
                &lock,
                &key,
                "claude",
                "fixture-source",
                "fixture-location",
                b"old",
                b"new"
            ),
            Err(AccountScopeError::MetadataWrite)
        );
        assert_eq!(metadata_bytes(&backend), before);
        assert_eq!(resolve_test(&backend, &lock, b"old").unwrap(), old);
        assert_ne!(resolve_test(&backend, &lock, b"new").unwrap(), old);
        backend.cleanup();
    }

    #[test]
    fn atomic_metadata_failure_points_never_leave_partial_json() {
        for operation in [
            FsOperation::CreateTemp,
            FsOperation::WriteTemp,
            FsOperation::SyncTemp,
            FsOperation::ReplaceMetadata,
        ] {
            let backend = TestBackend::new("atomic-failure-point");
            let lock = Mutex::new(());
            let old = resolve_test(&backend, &lock, b"old").unwrap();
            let before = metadata_bytes(&backend);
            backend.fail_fs(operation);
            assert_eq!(
                resolve_test(&backend, &lock, b"new"),
                Err(AccountScopeError::MetadataWrite)
            );
            assert_eq!(metadata_bytes(&backend), before);
            assert_eq!(resolve_test(&backend, &lock, b"old").unwrap(), old);
            decode_metadata(
                &installation_key_from_bytes(backend.keychain_read().unwrap().as_deref().unwrap())
                    .unwrap(),
                &metadata_bytes(&backend),
            )
            .unwrap();
            backend.cleanup();
        }
    }

    #[test]
    fn directory_sync_failure_returns_unavailable_but_keeps_valid_metadata() {
        let backend = TestBackend::new("directory-sync-failure");
        let lock = Mutex::new(());
        let old = resolve_test(&backend, &lock, b"old").unwrap();
        backend.fail_fs(FsOperation::SyncDirectory);
        assert_eq!(
            resolve_test(&backend, &lock, b"new"),
            Err(AccountScopeError::MetadataWrite)
        );
        let new_scope = resolve_test(&backend, &lock, b"new").unwrap();
        assert_ne!(new_scope, old);
        backend.cleanup();
    }

    #[test]
    fn key_loss_reloads_replacement_key_before_metadata_recovery() {
        let backend = TestBackend::new("key-loss-reload");
        backend.state.lock().unwrap().random = VecDeque::from([
            vec![0x31; INSTALLATION_KEY_BYTES],
            vec![0x41; LINEAGE_ID_BYTES],
            vec![0x32; INSTALLATION_KEY_BYTES],
            vec![0x42; LINEAGE_ID_BYTES],
        ]);
        let lock = Mutex::new(());
        let old_scope = resolve_test(&backend, &lock, b"same-marker").unwrap();
        let old_metadata = metadata_bytes(&backend);

        backend.state.lock().unwrap().key = Ok(None);
        assert_eq!(
            resolve_test(&backend, &lock, b"same-marker"),
            Err(AccountScopeError::OrphanedArtifacts)
        );
        assert_eq!(
            fs::read(
                backend
                    .directory
                    .join("quota-account-scope-v1.orphaned-1752710400.json")
            )
            .unwrap(),
            old_metadata
        );

        let replacement_scope = resolve_test(&backend, &lock, b"same-marker").unwrap();
        assert_ne!(replacement_scope, old_scope);
        let replacement_metadata = metadata_bytes(&backend);
        assert_eq!(
            resolve_test(&backend, &lock, b"same-marker").unwrap(),
            replacement_scope
        );
        assert_eq!(metadata_bytes(&backend), replacement_metadata);
        backend.cleanup();
    }

    #[test]
    fn concurrent_first_creation_uses_the_keychain_winner() {
        let barrier = Arc::new(Barrier::new(2));
        let mut backend = TestBackend::new("concurrent-key");
        backend.missing_read_barrier = Some(barrier);
        backend.state.lock().unwrap().random = VecDeque::from([
            vec![0x31; INSTALLATION_KEY_BYTES],
            vec![0x41; LINEAGE_ID_BYTES],
            vec![0x32; INSTALLATION_KEY_BYTES],
            vec![0x42; LINEAGE_ID_BYTES],
        ]);
        let process_one = Arc::new(Mutex::new(()));
        let process_two = Arc::new(Mutex::new(()));
        let one_backend = backend.clone();
        let two_backend = backend.clone();
        let one = thread::spawn(move || resolve_test(&one_backend, &process_one, b"same-marker"));
        let two = thread::spawn(move || resolve_test(&two_backend, &process_two, b"same-marker"));
        let one = one.join().unwrap().unwrap();
        let two = two.join().unwrap().unwrap();
        assert_eq!(one, two);
        assert_eq!(backend.state.lock().unwrap().key_adds, 2);
        backend.cleanup();
    }

    #[test]
    fn concurrent_loser_validates_winner_metadata_before_orphan_recovery() {
        let first_reads = Arc::new(Barrier::new(2));
        let release_loser_inspect = Arc::new(Barrier::new(2));
        let backend = TestBackend::new("concurrent-key-metadata");
        backend.state.lock().unwrap().random = VecDeque::from([
            vec![0x31; INSTALLATION_KEY_BYTES],
            vec![0x41; LINEAGE_ID_BYTES],
            vec![0x32; INSTALLATION_KEY_BYTES],
            vec![0x42; LINEAGE_ID_BYTES],
        ]);

        let mut winner_backend = backend.clone();
        winner_backend.missing_read_barrier = Some(first_reads.clone());
        let mut loser_backend = backend.clone();
        loser_backend.missing_read_barrier = Some(first_reads);
        loser_backend.inspect_artifacts_barrier = Some(release_loser_inspect.clone());

        let winner =
            thread::spawn(move || resolve_test(&winner_backend, &Mutex::new(()), b"same-marker"));
        let loser =
            thread::spawn(move || resolve_test(&loser_backend, &Mutex::new(()), b"same-marker"));

        let winner_scope = winner.join().unwrap().unwrap();
        let winner_metadata = metadata_bytes(&backend);
        release_loser_inspect.wait();
        let loser_scope = loser.join().unwrap().unwrap();

        assert_eq!(loser_scope, winner_scope);
        assert_eq!(metadata_bytes(&backend), winner_metadata);
        assert_eq!(backend.state.lock().unwrap().key_adds, 1);
        assert!(!fs::read_dir(&backend.directory).unwrap().any(|entry| {
            entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .contains(".orphaned-")
        }));
        backend.cleanup();
    }

    #[test]
    fn conflicting_two_process_transfers_fail_closed() {
        let backend = TestBackend::new("transfer-conflict");
        let setup_lock = Mutex::new(());
        let scope_a =
            resolve_credential_with(&backend, &setup_lock, "claude", "file", "slot-a", b"old-a")
                .unwrap();
        let scope_b =
            resolve_credential_with(&backend, &setup_lock, "claude", "file", "slot-b", b"old-b")
                .unwrap();
        assert_ne!(scope_a, scope_b);
        let key = installation_key_from_bytes(backend.keychain_read().unwrap().as_deref().unwrap())
            .unwrap();
        let one_backend = backend.clone();
        let two_backend = backend.clone();
        let one = thread::spawn(move || {
            transfer_credential_with(
                &one_backend,
                &Mutex::new(()),
                &key,
                "claude",
                "file",
                "slot-a",
                b"old-a",
                b"shared-new",
            )
        });
        let two = thread::spawn(move || {
            transfer_credential_with(
                &two_backend,
                &Mutex::new(()),
                &key,
                "claude",
                "file",
                "slot-b",
                b"old-b",
                b"shared-new",
            )
        });
        let results = [one.join().unwrap(), two.join().unwrap()];
        assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
        assert_eq!(
            results
                .iter()
                .filter(|result| **result == Err(AccountScopeError::MetadataConflict))
                .count(),
            1
        );
        backend.cleanup();
    }

    #[test]
    fn keychain_denial_and_invalid_key_never_touch_metadata() {
        for (tag, key, expected) in [
            (
                "keychain-denied",
                Err(AccountScopeError::KeychainUnavailable),
                AccountScopeError::KeychainUnavailable,
            ),
            (
                "keychain-short",
                Ok(Some(vec![7; INSTALLATION_KEY_BYTES - 1])),
                AccountScopeError::InvalidInstallationKey,
            ),
        ] {
            let backend = TestBackend::new(tag);
            backend.state.lock().unwrap().key = key;
            fs::create_dir_all(&backend.directory).unwrap();
            let original = b"fixture metadata";
            fs::write(backend.directory.join(METADATA_FILE), original).unwrap();
            assert_eq!(
                resolve_test(&backend, &Mutex::new(()), b"marker"),
                Err(expected)
            );
            assert_eq!(metadata_bytes(&backend), original);
            assert_eq!(backend.state.lock().unwrap().key_adds, 0);
            backend.cleanup();
        }
    }

    #[test]
    fn secure_random_failure_creates_no_key_or_metadata() {
        let backend = TestBackend::new("random-failure");
        backend.state.lock().unwrap().random.clear();
        assert_eq!(
            resolve_test(&backend, &Mutex::new(()), b"marker"),
            Err(AccountScopeError::RandomUnavailable)
        );
        assert_eq!(backend.keychain_read().unwrap(), None);
        assert!(!backend.directory.join(METADATA_FILE).exists());
        backend.cleanup();
    }

    #[test]
    fn missing_key_quarantines_metadata_preserves_v3_and_defers_one_poll() {
        let backend = TestBackend::new("orphan-recovery");
        fs::create_dir_all(&backend.directory).unwrap();
        let metadata = b"legacy-metadata-bytes";
        let history = b"legacy-v3-bytes";
        fs::write(backend.directory.join(METADATA_FILE), metadata).unwrap();
        fs::write(backend.directory.join(V3_HISTORY_FILE), history).unwrap();
        assert_eq!(
            resolve_test(&backend, &Mutex::new(()), b"marker"),
            Err(AccountScopeError::OrphanedArtifacts)
        );
        assert_eq!(
            fs::read(backend.directory.join(V3_HISTORY_FILE)).unwrap(),
            history
        );
        assert_eq!(
            fs::read(
                backend
                    .directory
                    .join("quota-account-scope-v1.orphaned-1752710400.json")
            )
            .unwrap(),
            metadata
        );
        assert!(resolve_test(&backend, &Mutex::new(()), b"marker").is_ok());
        backend.cleanup();
    }

    #[test]
    fn missing_key_with_only_v3_preserves_history_and_defers_one_poll() {
        let backend = TestBackend::new("v3-only-orphan");
        fs::create_dir_all(&backend.directory).unwrap();
        let history = b"orphaned-v3-scopes";
        fs::write(backend.directory.join(V3_HISTORY_FILE), history).unwrap();
        assert_eq!(
            resolve_test(&backend, &Mutex::new(()), b"marker"),
            Err(AccountScopeError::OrphanedArtifacts)
        );
        assert_eq!(
            fs::read(backend.directory.join(V3_HISTORY_FILE)).unwrap(),
            history
        );
        assert!(resolve_test(&backend, &Mutex::new(()), b"marker").is_ok());
        backend.cleanup();
    }

    #[test]
    fn orphan_quarantine_collision_uses_unique_suffix_without_overwrite() {
        let backend = TestBackend::new("orphan-collision");
        fs::create_dir_all(&backend.directory).unwrap();
        fs::write(backend.directory.join(METADATA_FILE), b"source").unwrap();
        fs::write(
            backend
                .directory
                .join("quota-account-scope-v1.orphaned-1752710400.json"),
            b"existing-zero",
        )
        .unwrap();
        fs::write(
            backend
                .directory
                .join("quota-account-scope-v1.orphaned-1752710400.1.json"),
            b"existing-one",
        )
        .unwrap();
        assert_eq!(
            resolve_test(&backend, &Mutex::new(()), b"marker"),
            Err(AccountScopeError::OrphanedArtifacts)
        );
        assert_eq!(
            fs::read(
                backend
                    .directory
                    .join("quota-account-scope-v1.orphaned-1752710400.2.json")
            )
            .unwrap(),
            b"source"
        );
        assert_eq!(
            fs::read(
                backend
                    .directory
                    .join("quota-account-scope-v1.orphaned-1752710400.json")
            )
            .unwrap(),
            b"existing-zero"
        );
        backend.cleanup();
    }

    #[test]
    fn quarantine_failure_does_not_create_or_replace_the_key() {
        let backend = TestBackend::new("orphan-quarantine-failure");
        fs::create_dir_all(&backend.directory).unwrap();
        let original = b"metadata-before-key-loss";
        fs::write(backend.directory.join(METADATA_FILE), original).unwrap();
        backend.fail_fs(FsOperation::QuarantineMetadata);
        assert_eq!(
            resolve_test(&backend, &Mutex::new(()), b"marker"),
            Err(AccountScopeError::QuarantineFailed)
        );
        assert_eq!(metadata_bytes(&backend), original);
        assert_eq!(backend.state.lock().unwrap().key_adds, 0);
        assert_eq!(backend.keychain_read().unwrap(), None);
        backend.cleanup();
    }

    #[test]
    fn corrupt_quarantine_failure_preserves_authenticated_recovery_evidence() {
        let backend = TestBackend::new("corrupt-quarantine-failure")
            .with_key(vec![0x11; INSTALLATION_KEY_BYTES]);
        fs::create_dir_all(&backend.directory).unwrap();
        let corrupt = b"corrupt-but-preserved";
        fs::write(backend.directory.join(METADATA_FILE), corrupt).unwrap();
        backend.fail_fs(FsOperation::QuarantineMetadata);
        assert_eq!(
            resolve_test(&backend, &Mutex::new(()), b"marker"),
            Err(AccountScopeError::QuarantineFailed)
        );
        assert_eq!(metadata_bytes(&backend), corrupt);
        backend.cleanup();
    }

    #[test]
    fn authoritative_scope_quarantines_corrupt_metadata_before_hmac() {
        for (tag, provider, kind, identifier, bytes) in [
            (
                "authoritative-invalid-json",
                "codex",
                AuthoritativeIdKind::OpaqueId,
                "acct-123",
                b"not-json".as_slice(),
            ),
            (
                "authoritative-bad-mac",
                "antigravity",
                AuthoritativeIdKind::Email,
                "user@example.com",
                br#"{"schemaVersion":1,"payloadBytesBase64":"e30=","payloadMac":"bad"}"#.as_slice(),
            ),
            (
                "authoritative-bad-schema",
                "codex",
                AuthoritativeIdKind::OpaqueId,
                "acct-456",
                br#"{"schemaVersion":2,"payloadBytesBase64":"e30=","payloadMac":"bad"}"#.as_slice(),
            ),
        ] {
            let backend = TestBackend::new(tag).with_key(vec![0x11; INSTALLATION_KEY_BYTES]);
            fs::create_dir_all(&backend.directory).unwrap();
            let metadata_path = backend.directory.join(METADATA_FILE);
            fs::write(&metadata_path, bytes).unwrap();

            assert_eq!(
                resolve_authoritative_with(&backend, &Mutex::new(()), provider, kind, identifier,),
                Err(AccountScopeError::MetadataCorrupt),
                "{tag}"
            );
            let quarantine = backend.directory.join(format!(
                "quota-account-scope-v1.corrupt-{}.json",
                backend.now_seconds()
            ));
            assert_eq!(fs::read(quarantine).unwrap(), bytes, "{tag}");
            assert!(!metadata_path.exists(), "{tag}");
            assert!(resolve_authoritative_with(
                &backend,
                &Mutex::new(()),
                provider,
                kind,
                identifier,
            )
            .is_ok());
            assert!(!metadata_path.exists(), "{tag}");
            backend.cleanup();
        }

        let backend = TestBackend::new("authoritative-corrupt-quarantine-failure")
            .with_key(vec![0x11; INSTALLATION_KEY_BYTES]);
        fs::create_dir_all(&backend.directory).unwrap();
        let metadata_path = backend.directory.join(METADATA_FILE);
        let original = b"corrupt-authoritative-metadata";
        fs::write(&metadata_path, original).unwrap();
        backend.fail_fs(FsOperation::QuarantineMetadata);
        assert_eq!(
            resolve_authoritative_with(
                &backend,
                &Mutex::new(()),
                "codex",
                AuthoritativeIdKind::OpaqueId,
                "acct-789",
            ),
            Err(AccountScopeError::QuarantineFailed)
        );
        assert_eq!(fs::read(&metadata_path).unwrap(), original);
        backend.cleanup();
    }

    #[test]
    fn mac_or_schema_corruption_is_quarantined_then_next_poll_recovers() {
        for (tag, bytes) in [
            (
                "bad-mac",
                br#"{"schemaVersion":1,"payloadBytesBase64":"e30=","payloadMac":"bad"}"#.as_slice(),
            ),
            (
                "bad-schema",
                br#"{"schemaVersion":2,"payloadBytesBase64":"e30=","payloadMac":"bad"}"#.as_slice(),
            ),
        ] {
            let backend = TestBackend::new(tag).with_key(vec![0x11; INSTALLATION_KEY_BYTES]);
            fs::create_dir_all(&backend.directory).unwrap();
            fs::write(backend.directory.join(METADATA_FILE), bytes).unwrap();
            assert_eq!(
                resolve_test(&backend, &Mutex::new(()), b"marker"),
                Err(AccountScopeError::MetadataCorrupt)
            );
            let quarantine = backend.directory.join(format!(
                "quota-account-scope-v1.corrupt-{}.json",
                backend.now_seconds()
            ));
            assert_eq!(fs::read(quarantine).unwrap(), bytes);
            assert!(resolve_test(&backend, &Mutex::new(()), b"marker").is_ok());
            backend.cleanup();
        }
    }

    #[test]
    fn authenticated_payload_with_missing_schema_fields_is_quarantined() {
        let backend =
            TestBackend::new("missing-payload-field").with_key(vec![0x11; INSTALLATION_KEY_BYTES]);
        fs::create_dir_all(&backend.directory).unwrap();
        let key = installation_key_from_bytes(backend.keychain_read().unwrap().as_deref().unwrap())
            .unwrap();
        let payload_bytes = br#"{"bindings":[]}"#;
        let metadata_key = metadata_mac_key(&key).unwrap();
        let mac = hmac_digest(&metadata_key, &[payload_bytes.as_slice()]).unwrap();
        let envelope = MetadataEnvelope {
            schema_version: METADATA_SCHEMA_VERSION,
            payload_bytes_base64: STANDARD.encode(payload_bytes),
            payload_mac: encode_digest(&mac),
        };
        let original = serde_json::to_vec_pretty(&envelope).unwrap();
        fs::write(backend.directory.join(METADATA_FILE), &original).unwrap();

        assert_eq!(
            resolve_test(&backend, &Mutex::new(()), b"marker"),
            Err(AccountScopeError::MetadataCorrupt)
        );
        assert_eq!(
            fs::read(
                backend
                    .directory
                    .join("quota-account-scope-v1.corrupt-1752710400.json")
            )
            .unwrap(),
            original
        );
        backend.cleanup();
    }

    #[test]
    fn lock_failure_preserves_last_valid_metadata() {
        let backend = TestBackend::new("lock-failure");
        let lock = Mutex::new(());
        resolve_test(&backend, &lock, b"old").unwrap();
        let before = metadata_bytes(&backend);
        backend.fail_fs(FsOperation::AcquireMetadataLock);
        assert_eq!(
            resolve_test(&backend, &lock, b"new"),
            Err(AccountScopeError::MetadataLock)
        );
        assert_eq!(metadata_bytes(&backend), before);
        backend.cleanup();
    }

    #[cfg(unix)]
    #[test]
    fn metadata_lock_symlink_fails_closed_before_lock_acquisition() {
        use std::os::unix::fs::{symlink, PermissionsExt as _};

        let backend =
            TestBackend::new("metadata-lock-symlink").with_key(vec![0x11; INSTALLATION_KEY_BYTES]);
        fs::create_dir_all(&backend.directory).unwrap();
        let target = backend.directory.with_extension("external-metadata-lock");
        let lock_path = backend.directory.join(METADATA_LOCK_FILE);
        let original = b"external-metadata-lock-target";
        fs::write(&target, original).unwrap();
        fs::set_permissions(&target, fs::Permissions::from_mode(0o644)).unwrap();
        let original_mode = unix_mode(&target);
        symlink(&target, &lock_path).unwrap();

        assert_eq!(
            resolve_test(&backend, &Mutex::new(()), b"marker"),
            Err(AccountScopeError::MetadataLock)
        );
        assert_eq!(fs::read(&target).unwrap(), original);
        assert_eq!(unix_mode(&target), original_mode);
        assert!(fs::symlink_metadata(&lock_path)
            .unwrap()
            .file_type()
            .is_symlink());
        assert!(!backend.directory.join(METADATA_FILE).exists());
        let events = backend.state.lock().unwrap().events.clone();
        assert!(events.contains(&"open-metadata-lock"));
        assert!(!events.contains(&"acquire-metadata-lock"));
        assert!(!events.contains(&"read-metadata"));
        assert!(!events.contains(&"create-temp"));

        backend.cleanup();
        fs::remove_file(target).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn active_metadata_symlink_fails_closed_without_touching_target() {
        use std::os::unix::fs::{symlink, PermissionsExt as _};

        let backend =
            TestBackend::new("metadata-symlink").with_key(vec![0x11; INSTALLATION_KEY_BYTES]);
        fs::create_dir_all(&backend.directory).unwrap();
        let target = backend.directory.with_extension("external-metadata");
        let metadata_path = backend.directory.join(METADATA_FILE);
        let original = b"external-metadata-target";
        fs::write(&target, original).unwrap();
        fs::set_permissions(&target, fs::Permissions::from_mode(0o644)).unwrap();
        let original_mode = unix_mode(&target);
        symlink(&target, &metadata_path).unwrap();

        assert_eq!(
            resolve_test(&backend, &Mutex::new(()), b"marker"),
            Err(AccountScopeError::MetadataRead)
        );
        assert_eq!(fs::read(&target).unwrap(), original);
        assert_eq!(unix_mode(&target), original_mode);
        assert!(fs::symlink_metadata(&metadata_path)
            .unwrap()
            .file_type()
            .is_symlink());
        assert!(!backend
            .directory
            .join("quota-account-scope-v1.corrupt-1752710400.json")
            .exists());
        let events = backend.state.lock().unwrap().events.clone();
        assert!(events.contains(&"acquire-metadata-lock"));
        assert!(events.contains(&"read-metadata"));
        assert!(!events.contains(&"quarantine-metadata"));
        assert!(!events.contains(&"create-temp"));

        backend.cleanup();
        fs::remove_file(target).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn metadata_symlink_with_missing_key_never_creates_or_replaces_key() {
        use std::os::unix::fs::{symlink, PermissionsExt as _};

        let backend = TestBackend::new("metadata-symlink-missing-key");
        fs::create_dir_all(&backend.directory).unwrap();
        let target = backend.directory.with_extension("external-orphan-metadata");
        let metadata_path = backend.directory.join(METADATA_FILE);
        let original = b"external-orphan-metadata-target";
        fs::write(&target, original).unwrap();
        fs::set_permissions(&target, fs::Permissions::from_mode(0o644)).unwrap();
        let original_mode = unix_mode(&target);
        symlink(&target, &metadata_path).unwrap();

        assert_eq!(
            resolve_test(&backend, &Mutex::new(()), b"marker"),
            Err(AccountScopeError::StorageUnavailable)
        );
        assert_eq!(fs::read(&target).unwrap(), original);
        assert_eq!(unix_mode(&target), original_mode);
        assert!(fs::symlink_metadata(&metadata_path)
            .unwrap()
            .file_type()
            .is_symlink());
        assert_eq!(backend.keychain_read().unwrap(), None);
        assert_eq!(backend.state.lock().unwrap().key_adds, 0);
        let events = backend.state.lock().unwrap().events.clone();
        assert!(events.contains(&"inspect-artifacts"));
        assert!(!events.contains(&"open-metadata-lock"));
        assert!(!events.contains(&"quarantine-metadata"));

        backend.cleanup();
        fs::remove_file(target).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn account_final_directory_symlink_fails_before_chmod_or_artifact_creation() {
        use std::os::unix::fs::{symlink, PermissionsExt as _};

        let backend =
            TestBackend::new("directory-symlink").with_key(vec![0x11; INSTALLATION_KEY_BYTES]);
        let target = backend.directory.with_extension("external-directory");
        fs::create_dir(&target).unwrap();
        fs::set_permissions(&target, fs::Permissions::from_mode(0o755)).unwrap();
        let original_mode = unix_mode(&target);
        symlink(&target, &backend.directory).unwrap();

        assert_eq!(
            resolve_test(&backend, &Mutex::new(()), b"marker"),
            Err(AccountScopeError::StorageUnavailable)
        );
        assert_eq!(unix_mode(&target), original_mode);
        assert_eq!(fs::read_dir(&target).unwrap().count(), 0);
        assert!(fs::symlink_metadata(&backend.directory)
            .unwrap()
            .file_type()
            .is_symlink());
        let events = backend.state.lock().unwrap().events.clone();
        assert!(events.contains(&"create-directory"));
        assert!(!events.contains(&"open-metadata-lock"));
        assert!(!events.contains(&"create-temp"));
        assert_eq!(backend.state.lock().unwrap().key_adds, 0);

        fs::remove_file(&backend.directory).unwrap();
        fs::remove_dir(target).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn atomic_metadata_quarantine_hard_link_closes_collision_race() {
        use std::cell::Cell;
        use std::os::unix::fs::{symlink, MetadataExt as _, PermissionsExt as _};

        let backend = TestBackend::new("metadata-quarantine-reservation-race");
        fs::create_dir_all(&backend.directory).unwrap();
        let metadata_path = backend.directory.join(METADATA_FILE);
        let original = b"metadata-race-source";
        fs::write(&metadata_path, original).unwrap();
        fs::set_permissions(&metadata_path, fs::Permissions::from_mode(0o644)).unwrap();
        let source_inode = fs::metadata(&metadata_path).unwrap().ino();
        let collision = backend
            .directory
            .join("quota-account-scope-v1.corrupt-1752710400.json");
        let missing_target = backend.directory.with_extension("race-dangling-target");
        let raced = Cell::new(false);

        let quarantined = quarantine_metadata_with(
            &backend,
            &metadata_path,
            "corrupt",
            |source, candidate| {
                if !raced.replace(true) {
                    symlink(&missing_target, candidate)?;
                }
                fs::hard_link(source, candidate)
            },
            |source| fs::remove_file(source),
        )
        .unwrap();

        assert_eq!(
            quarantined,
            backend
                .directory
                .join("quota-account-scope-v1.corrupt-1752710400.1.json")
        );
        assert!(fs::symlink_metadata(&collision)
            .unwrap()
            .file_type()
            .is_symlink());
        assert!(!missing_target.exists());
        assert_eq!(fs::read(&quarantined).unwrap(), original);
        assert_eq!(unix_mode(&quarantined), 0o600);
        assert_eq!(fs::metadata(&quarantined).unwrap().ino(), source_inode);
        assert!(!metadata_path.exists());

        backend.cleanup();
    }

    #[cfg(unix)]
    #[test]
    fn metadata_quarantine_unlink_failure_rolls_back_link() {
        use std::os::unix::fs::PermissionsExt as _;

        let backend = TestBackend::new("metadata-quarantine-unlink-failure");
        fs::create_dir_all(&backend.directory).unwrap();
        let metadata_path = backend.directory.join(METADATA_FILE);
        let original = b"metadata-before-rename-failure";
        fs::write(&metadata_path, original).unwrap();
        fs::set_permissions(&metadata_path, fs::Permissions::from_mode(0o644)).unwrap();
        let candidate = backend
            .directory
            .join("quota-account-scope-v1.corrupt-1752710400.json");

        assert_eq!(
            quarantine_metadata_with(
                &backend,
                &metadata_path,
                "corrupt",
                |source, candidate| fs::hard_link(source, candidate),
                |_source| Err(io::Error::new(io::ErrorKind::PermissionDenied, "injected")),
            ),
            Err(AccountScopeError::QuarantineFailed)
        );
        assert_eq!(fs::read(&metadata_path).unwrap(), original);
        assert_eq!(unix_mode(&metadata_path), 0o600);
        assert!(matches!(
            fs::symlink_metadata(&candidate),
            Err(error) if error.kind() == io::ErrorKind::NotFound
        ));
        assert!(!backend
            .state
            .lock()
            .unwrap()
            .events
            .contains(&"sync-directory"));

        backend.cleanup();
    }

    #[cfg(unix)]
    #[test]
    fn dangling_metadata_quarantine_collision_is_not_overwritten() {
        use std::os::unix::fs::{symlink, PermissionsExt as _};

        let backend =
            TestBackend::new("dangling-quarantine").with_key(vec![0x11; INSTALLATION_KEY_BYTES]);
        fs::create_dir_all(&backend.directory).unwrap();
        let metadata_path = backend.directory.join(METADATA_FILE);
        let corrupt = b"corrupt-metadata-with-dangling-collision";
        fs::write(&metadata_path, corrupt).unwrap();
        fs::set_permissions(&metadata_path, fs::Permissions::from_mode(0o644)).unwrap();
        let collision = backend
            .directory
            .join("quota-account-scope-v1.corrupt-1752710400.json");
        let missing_target = backend
            .directory
            .with_extension("missing-quarantine-target");
        symlink(&missing_target, &collision).unwrap();

        assert_eq!(
            resolve_test(&backend, &Mutex::new(()), b"marker"),
            Err(AccountScopeError::MetadataCorrupt)
        );
        assert!(fs::symlink_metadata(&collision)
            .unwrap()
            .file_type()
            .is_symlink());
        assert!(!missing_target.exists());
        let quarantined = backend
            .directory
            .join("quota-account-scope-v1.corrupt-1752710400.1.json");
        assert_eq!(fs::read(&quarantined).unwrap(), corrupt);
        assert_eq!(unix_mode(&quarantined), 0o600);
        assert!(!metadata_path.exists());
        assert_eq!(backend.state.lock().unwrap().key_adds, 0);
        assert!(!backend
            .state
            .lock()
            .unwrap()
            .events
            .contains(&"create-temp"));

        backend.cleanup();
    }

    #[cfg(unix)]
    #[test]
    fn restored_metadata_is_tightened_before_read_without_changing_bytes() {
        use std::os::unix::fs::PermissionsExt as _;

        let backend = TestBackend::new("restored-mode");
        let lock = Mutex::new(());
        resolve_test(&backend, &lock, b"marker").unwrap();
        let metadata_path = backend.directory.join(METADATA_FILE);
        let bytes = fs::read(&metadata_path).unwrap();
        fs::set_permissions(&metadata_path, fs::Permissions::from_mode(0o644)).unwrap();
        let key = installation_key_from_bytes(backend.keychain_read().unwrap().as_deref().unwrap())
            .unwrap();

        let payload = load_metadata(&backend, &backend.directory, &key).unwrap();
        assert_eq!(payload.bindings.len(), 1);
        assert_eq!(fs::read(&metadata_path).unwrap(), bytes);
        assert_eq!(unix_mode(&metadata_path), 0o600);

        backend.cleanup();
    }

    #[cfg(unix)]
    #[test]
    fn symlinked_ancestor_is_allowed_when_final_account_directory_is_real() {
        use std::os::unix::fs::symlink;

        let mut backend =
            TestBackend::new("ancestor-symlink").with_key(vec![0x11; INSTALLATION_KEY_BYTES]);
        let seed = backend.directory.clone();
        let real_parent = seed.with_extension("real-parent");
        let linked_parent = seed.with_extension("linked-parent");
        backend.directory = linked_parent.join("com.nyanako.tokenbar");
        fs::create_dir(&real_parent).unwrap();
        symlink(&real_parent, &linked_parent).unwrap();

        assert!(resolve_test(&backend, &Mutex::new(()), b"marker").is_ok());
        assert!(fs::symlink_metadata(&backend.directory)
            .unwrap()
            .file_type()
            .is_dir());

        fs::remove_file(linked_parent).unwrap();
        fs::remove_dir_all(real_parent).unwrap();
    }

    #[test]
    fn refresh_lock_is_owner_only_and_failure_is_typed() {
        let backend = TestBackend::new("refresh-lock");
        let directory = ensure_storage_dir(&backend).unwrap();
        let file = open_refresh_lock_file(&backend, &directory, "claude").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            assert_eq!(
                fs::metadata(directory.join("quota-auth-refresh-claude.lock"))
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
        }
        fs2::FileExt::unlock(&file).unwrap();
        backend.fail_fs(FsOperation::AcquireRefreshLock);
        assert!(matches!(
            open_refresh_lock_file(&backend, &directory, "claude"),
            Err(AccountScopeError::MetadataLock)
        ));
        backend.cleanup();
    }

    #[cfg(unix)]
    #[test]
    fn refresh_lock_symlink_fails_closed_before_lock_acquisition() {
        use std::os::unix::fs::{symlink, PermissionsExt as _};

        let backend = TestBackend::new("refresh-lock-symlink");
        let directory = ensure_storage_dir(&backend).unwrap();
        let target = backend.directory.with_extension("external-refresh-lock");
        let lock_path = directory.join("quota-auth-refresh-claude.lock");
        let original = b"external-refresh-lock-target";
        fs::write(&target, original).unwrap();
        fs::set_permissions(&target, fs::Permissions::from_mode(0o644)).unwrap();
        let original_mode = unix_mode(&target);
        symlink(&target, &lock_path).unwrap();

        assert!(matches!(
            open_refresh_lock_file(&backend, &directory, "claude"),
            Err(AccountScopeError::MetadataLock)
        ));
        assert_eq!(fs::read(&target).unwrap(), original);
        assert_eq!(unix_mode(&target), original_mode);
        assert!(fs::symlink_metadata(&lock_path)
            .unwrap()
            .file_type()
            .is_symlink());
        let events = backend.state.lock().unwrap().events.clone();
        assert!(events.contains(&"open-refresh-lock"));
        assert!(!events.contains(&"acquire-refresh-lock"));

        backend.cleanup();
        fs::remove_file(target).unwrap();
    }

    #[test]
    fn authenticated_binding_conflict_is_preserved_not_quarantined() {
        let backend = TestBackend::new("binding-conflict");
        let lock = Mutex::new(());
        resolve_test(&backend, &lock, b"old").unwrap();
        let key = installation_key_from_bytes(backend.keychain_read().unwrap().as_deref().unwrap())
            .unwrap();
        let directory = backend.directory.clone();
        let mut payload = decode_metadata(&key, &metadata_bytes(&backend)).unwrap();
        let mut duplicate = payload.bindings[0].clone();
        duplicate.random_lineage_id = URL_SAFE_NO_PAD.encode([0xEF; LINEAGE_ID_BYTES]);
        payload.bindings.push(duplicate);
        // Encode a valid-MAC envelope without running semantic validation.
        let payload_bytes = serde_json::to_vec(&payload).unwrap();
        let metadata_key = metadata_mac_key(&key).unwrap();
        let mac = hmac_digest(&metadata_key, &[payload_bytes.as_slice()]).unwrap();
        let envelope = MetadataEnvelope {
            schema_version: METADATA_SCHEMA_VERSION,
            payload_bytes_base64: STANDARD.encode(&payload_bytes),
            payload_mac: encode_digest(&mac),
        };
        fs::write(
            directory.join(METADATA_FILE),
            serde_json::to_vec_pretty(&envelope).unwrap(),
        )
        .unwrap();
        let before = metadata_bytes(&backend);
        assert_eq!(
            resolve_test(&backend, &lock, b"old"),
            Err(AccountScopeError::MetadataConflict)
        );
        assert_eq!(metadata_bytes(&backend), before);
        assert!(!directory
            .join(format!(
                "quota-account-scope-v1.corrupt-{}.json",
                backend.now_seconds()
            ))
            .exists());
        backend.cleanup();
    }

    #[test]
    fn persisted_files_are_owner_only_and_contain_no_raw_or_plain_sha_values() {
        let backend = TestBackend::new("raw-scan");
        let lock = Mutex::new(());
        let raw_values = [
            "fixture-secret-refresh-token",
            "User.LowEntropy@example.com",
            "/Users/fixture/private/auth.json",
            "Fixture Display Label",
            "Provider-Account-ID-ByteCase",
        ];
        let credential_scope = resolve_credential_with(
            &backend,
            &lock,
            "grok",
            "auth-json",
            raw_values[2],
            raw_values[0].as_bytes(),
        )
        .unwrap();
        let email_scope = resolve_authoritative_with(
            &backend,
            &lock,
            "antigravity",
            AuthoritativeIdKind::Email,
            raw_values[1],
        )
        .unwrap();
        let id_scope = resolve_authoritative_with(
            &backend,
            &lock,
            "codex",
            AuthoritativeIdKind::OpaqueId,
            raw_values[4],
        )
        .unwrap();
        let history = format!(
            r#"{{"accountScopes":["{}","{}","{}"]}}"#,
            credential_scope.as_str(),
            email_scope.as_str(),
            id_scope.as_str()
        );
        fs::write(backend.directory.join(V3_HISTORY_FILE), history).unwrap();
        let metadata = metadata_bytes(&backend);
        let key = installation_key_from_bytes(backend.keychain_read().unwrap().as_deref().unwrap())
            .unwrap();
        decode_metadata(&key, &metadata).unwrap();
        let envelope: MetadataEnvelope = serde_json::from_slice(&metadata).unwrap();
        let decoded_payload = STANDARD
            .decode(envelope.payload_bytes_base64.as_bytes())
            .unwrap();
        let files = [
            metadata,
            decoded_payload,
            fs::read(backend.directory.join(V3_HISTORY_FILE)).unwrap(),
        ];
        for bytes in files {
            let text = String::from_utf8(bytes).unwrap();
            for raw in raw_values {
                assert!(!text.contains(raw));
                let digest = Sha256::digest(raw.as_bytes());
                assert!(!text.contains(&format!("{digest:x}")));
                assert!(!text.contains(&STANDARD.encode(digest)));
                assert!(!text.contains(&URL_SAFE_NO_PAD.encode(digest)));
            }
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            assert_eq!(
                fs::metadata(&backend.directory)
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o700
            );
            for path in [
                backend.directory.join(METADATA_FILE),
                backend.directory.join(METADATA_LOCK_FILE),
            ] {
                assert_eq!(
                    fs::metadata(path).unwrap().permissions().mode() & 0o777,
                    0o600
                );
            }
        }
        backend.cleanup();
    }

    #[test]
    fn reinstall_with_consistent_key_and_metadata_restores_the_same_scope() {
        let backend = TestBackend::new("restore");
        let first = resolve_test(&backend, &Mutex::new(()), b"marker").unwrap();
        let restarted = backend.clone();
        let second = resolve_test(&restarted, &Mutex::new(()), b"marker").unwrap();
        assert_eq!(first, second);
        backend.cleanup();
    }
}
