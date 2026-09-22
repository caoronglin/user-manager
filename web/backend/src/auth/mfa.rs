//! MFA / TOTP（RFC 6238）。TOTP secret 以 Web master key 加密存储（mfa_secret_cipher）。
//!
//! 边界：secret 不明文落库、不进日志；otpauth URL 仅在注册(setup)时返回一次。

use rand::RngCore;
use totp_rs::{Algorithm, Builder, Secret, Totp};

const ISSUER: &str = "User Manager";
const DIGITS: usize = 6;
const SKEW: u16 = 1;
const STEP: u64 = 30;
const SECRET_LEN: usize = 20;

/// 生成新的 TOTP secret（随机 20 字节，base32 友好）。
pub fn generate_secret() -> Vec<u8> {
    let mut s = vec![0u8; SECRET_LEN];
    rand::rngs::OsRng.fill_bytes(&mut s);
    s
}

fn build_from_secret(secret: Secret, account: &str) -> Result<Totp, String> {
    Builder::new()
        .with_algorithm(Algorithm::SHA1)
        .with_digits(DIGITS as u8)
        .with_skew(SKEW)
        .with_step_duration(STEP)
        .with_secret(secret)
        .with_account_name(account)
        .with_issuer(Some(ISSUER))
        .build()
        .map_err(|e| e.to_string())
}

fn build_totp(secret_bytes: &[u8], account: &str) -> Result<Totp, String> {
    build_from_secret(Secret::from(secret_bytes.to_vec()), account)
}

/// 从 base32 secret 构造 TOTP（供测试/兼容 otpauth URL 解析）。
pub fn totp_from_b32(b32: &str, account: &str) -> Result<Totp, String> {
    let secret = Secret::try_from_base32(b32).map_err(|e| e.to_string())?;
    build_from_secret(secret, account)
}

/// 生成 otpauth:// URL（注册时一次性返回给用户）。
pub fn otpauth_url(secret_bytes: &[u8], account: &str) -> Result<String, String> {
    let totp = build_totp(secret_bytes, account)?;
    totp.to_url().map_err(|e| e.to_string())
}

/// 校验当前 TOTP code。
pub fn verify_code(secret_bytes: &[u8], account: &str, code: &str) -> bool {
    match build_totp(secret_bytes, account) {
        Ok(totp) => totp.check_current(code).is_some(),
        Err(_) => false,
    }
}

/// 生成当前 code（仅供测试）。
pub fn current_code(secret_bytes: &[u8], account: &str) -> Option<String> {
    build_totp(secret_bytes, account)
        .ok()
        .map(|t| t.generate_current().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn totp_generate_and_verify_roundtrip() {
        let secret = generate_secret();
        let url = otpauth_url(&secret, "alice").expect("url");
        assert!(url.starts_with("otpauth://totp/"), "url: {url}");
        let code = current_code(&secret, "alice").expect("code");
        assert!(verify_code(&secret, "alice", &code));
        assert!(!verify_code(&secret, "alice", "000000"));
    }
}
