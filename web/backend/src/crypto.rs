//! Web 独立 secret 管理：master key 加载/生成 + AEAD 加解密（AES-256-GCM）。
//!
//! 边界：使用 **Web 自己的 master key**（/var/lib/user-manager-web/secrets/master.key，
//! 0600），不读取 CLI/TUI 特权域主密钥。用于加密 TOTP secret 与 WeCom webhook（P4）。

use std::io;
use std::path::Path;

use aes_gcm::aead::Aead;
use aes_gcm::{Aes256Gcm, Key, KeyInit, Nonce};
use base64::Engine as _;
use rand::RngCore;

pub const KEY_LEN: usize = 32;
pub const NONCE_LEN: usize = 12;

/// 加载 master key；不存在则生成随机 32 字节并以 0600 落盘（父目录 0700）。
pub fn load_or_create_master_key(path: &Path) -> io::Result<[u8; KEY_LEN]> {
    if let Ok(existing) = std::fs::read(path) {
        if existing.len() == KEY_LEN {
            let mut k = [0u8; KEY_LEN];
            k.copy_from_slice(&existing);
            return Ok(k);
        }
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "master key has wrong length",
        ));
    }
    let mut k = [0u8; KEY_LEN];
    rand::rngs::OsRng.fill_bytes(&mut k);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700));
        }
    }
    std::fs::write(path, k)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
    }
    Ok(k)
}

/// 加密：随机 12B nonce || ciphertext，base64 编码返回。失败返回 None。
pub fn encrypt(key: &[u8; KEY_LEN], plaintext: &[u8]) -> Option<String> {
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key));
    let mut nonce = [0u8; NONCE_LEN];
    rand::rngs::OsRng.fill_bytes(&mut nonce);
    let ct = cipher.encrypt(Nonce::from_slice(&nonce), plaintext).ok()?;
    let mut out = nonce.to_vec();
    out.extend_from_slice(&ct);
    Some(base64::engine::general_purpose::STANDARD.encode(out))
}

/// 解密 base64(nonce||ct)。失败返回 None。
pub fn decrypt(key: &[u8; KEY_LEN], blob: &str) -> Option<Vec<u8>> {
    let data = base64::engine::general_purpose::STANDARD
        .decode(blob.as_bytes())
        .ok()?;
    if data.len() <= NONCE_LEN {
        return None;
    }
    let (n, ct) = data.split_at(NONCE_LEN);
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key));
    cipher.decrypt(Nonce::from_slice(n), ct).ok()
}

pub fn encrypt_str(key: &[u8; KEY_LEN], s: &str) -> Option<String> {
    encrypt(key, s.as_bytes())
}

pub fn decrypt_str(key: &[u8; KEY_LEN], blob: &str) -> Option<String> {
    decrypt(key, blob).and_then(|b| String::from_utf8(b).ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encrypt_decrypt_roundtrip() {
        let key = [7u8; KEY_LEN];
        let ct = encrypt_str(&key, "super-secret-totp").unwrap();
        assert_ne!(ct, "super-secret-totp");
        assert_eq!(decrypt_str(&key, &ct).unwrap(), "super-secret-totp");
    }

    #[test]
    fn tamper_detected() {
        let key = [7u8; KEY_LEN];
        let ct = encrypt_str(&key, "hello").unwrap();
        // 翻转一个 base64 字符（改内容）。
        let mut chars: Vec<char> = ct.chars().collect();
        if let Some(c) = chars.last_mut() {
            *c = if *c == 'A' { 'B' } else { 'A' };
        }
        let tampered: String = chars.into_iter().collect();
        assert!(
            decrypt_str(&key, &tampered).is_none()
                || decrypt_str(&key, &tampered) != Some("hello".to_string())
        );
    }
}
