//! API keys, the Windows counterpart of `KeychainStore`
//! (Sources/Support/KeychainStore.swift). Keys live in Windows Credential
//! Manager as generic credentials named `Cue/<provider>`, never in files.
//! Environment variables are a fallback for scripts and CI.

use cue_core::translation::Provider;

/// Where a key was found, for `cue keys list`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeySource {
    CredentialManager,
    Environment(&'static str),
}

fn target_name(provider: Provider) -> String {
    format!("Cue/{}", provider.slug())
}

/// `CUE_<PROVIDER>_API_KEY` first, then the provider's conventional name.
fn env_names(provider: Provider) -> &'static [&'static str] {
    match provider {
        Provider::OpenAi => &["CUE_OPENAI_API_KEY", "OPENAI_API_KEY"],
        Provider::Anthropic => &["CUE_ANTHROPIC_API_KEY", "ANTHROPIC_API_KEY"],
        Provider::Google => &["CUE_GOOGLE_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY"],
        Provider::OpenRouter => &["CUE_OPENROUTER_API_KEY", "OPENROUTER_API_KEY"],
        Provider::Groq => &["CUE_GROQ_API_KEY", "GROQ_API_KEY"],
        Provider::Cerebras => &["CUE_CEREBRAS_API_KEY", "CEREBRAS_API_KEY"],
        Provider::Local => &[],
    }
}

/// The key for a provider and where it came from. Credential Manager wins
/// over the environment, matching the Mac app's Keychain-only lookup.
pub fn lookup(provider: Provider) -> Option<(String, KeySource)> {
    if let Some(key) = store::read(&target_name(provider)).filter(|k| !k.trim().is_empty()) {
        return Some((key.trim().to_string(), KeySource::CredentialManager));
    }
    env_names(provider).iter().find_map(|name| {
        let value = std::env::var(name).ok()?;
        let value = value.trim();
        (!value.is_empty()).then(|| (value.to_string(), KeySource::Environment(name)))
    })
}

pub fn save(provider: Provider, key: &str) -> Result<(), String> {
    if !provider.needs_api_key() {
        return Err("local servers need no API key".into());
    }
    let key = key.trim();
    if key.is_empty() {
        return Err("the key is empty".into());
    }
    store::write(&target_name(provider), key)
}

pub fn remove(provider: Provider) -> Result<bool, String> {
    store::delete(&target_name(provider))
}

#[cfg(windows)]
mod store {
    use windows_sys::Win32::Foundation::{GetLastError, ERROR_NOT_FOUND};
    use windows_sys::Win32::Security::Credentials::{
        CredDeleteW, CredFree, CredReadW, CredWriteW, CREDENTIALW, CRED_PERSIST_LOCAL_MACHINE, CRED_TYPE_GENERIC,
    };

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    pub fn read(target: &str) -> Option<String> {
        let name = wide(target);
        let mut credential: *mut CREDENTIALW = std::ptr::null_mut();
        // SAFETY: `name` is NUL-terminated and outlives the call; on success
        // Windows hands back a buffer we release with CredFree.
        unsafe {
            if CredReadW(name.as_ptr(), CRED_TYPE_GENERIC, 0, &mut credential) == 0 {
                return None;
            }
            let c = &*credential;
            let blob = std::slice::from_raw_parts(c.CredentialBlob, c.CredentialBlobSize as usize);
            let value = String::from_utf8(blob.to_vec()).ok();
            CredFree(credential as *const _);
            value
        }
    }

    pub fn write(target: &str, secret: &str) -> Result<(), String> {
        let mut name = wide(target);
        let mut user = wide("Cue");
        let mut blob = secret.as_bytes().to_vec();
        let credential = CREDENTIALW {
            Type: CRED_TYPE_GENERIC,
            TargetName: name.as_mut_ptr(),
            CredentialBlobSize: blob.len() as u32,
            CredentialBlob: blob.as_mut_ptr(),
            // Per user, survives sign-out; roams only inside the profile.
            Persist: CRED_PERSIST_LOCAL_MACHINE,
            UserName: user.as_mut_ptr(),
            ..Default::default()
        };
        // SAFETY: every pointer refers to a live local buffer for the call.
        if unsafe { CredWriteW(&credential, 0) } == 0 {
            return Err(format!("Credential Manager refused the key (error {})", unsafe { GetLastError() }));
        }
        Ok(())
    }

    pub fn delete(target: &str) -> Result<bool, String> {
        let name = wide(target);
        // SAFETY: `name` is NUL-terminated and outlives the call.
        if unsafe { CredDeleteW(name.as_ptr(), CRED_TYPE_GENERIC, 0) } != 0 {
            return Ok(true);
        }
        match unsafe { GetLastError() } {
            ERROR_NOT_FOUND => Ok(false),
            code => Err(format!("Credential Manager could not remove the key (error {code})")),
        }
    }
}

/// Elsewhere (Linux CI, macOS dev builds) there is no store; keys come from
/// the environment only.
#[cfg(not(windows))]
mod store {
    pub fn read(_target: &str) -> Option<String> {
        None
    }

    pub fn write(_target: &str, _secret: &str) -> Result<(), String> {
        Err("saving keys needs Windows Credential Manager; set the API key environment variable instead".into())
    }

    pub fn delete(_target: &str) -> Result<bool, String> {
        Ok(false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn environment_fallback_prefers_the_cue_name() {
        // Unique provider-specific names keep this test independent of the
        // others; Groq is not touched elsewhere.
        std::env::set_var("GROQ_API_KEY", " conventional ");
        assert_eq!(lookup(Provider::Groq), Some(("conventional".into(), KeySource::Environment("GROQ_API_KEY"))));
        std::env::set_var("CUE_GROQ_API_KEY", "cue");
        assert_eq!(lookup(Provider::Groq), Some(("cue".into(), KeySource::Environment("CUE_GROQ_API_KEY"))));
        std::env::remove_var("CUE_GROQ_API_KEY");
        std::env::remove_var("GROQ_API_KEY");
    }

    #[test]
    fn local_needs_no_key() {
        assert!(save(Provider::Local, "x").is_err());
        assert_eq!(lookup(Provider::Local), None);
    }
}
