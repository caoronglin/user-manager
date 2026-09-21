//! Argon2id 密码哈希。参数集中、可版本化，支持未来 rehash。
//!
//! - 永不存储/记录明文密码；只存 PHC 字符串（含参数与盐）。

use argon2::password_hash::{
    rand_core::OsRng, PasswordHash, PasswordHasher, PasswordVerifier, SaltString,
};
use argon2::Argon2;

/// 集中、可版本化的 Argon2id 参数。
pub struct Argon2Params;

impl Argon2Params {
    // 适度默认；可版本化升级并在登录成功时 rehash。
    pub fn argon2() -> Argon2<'static> {
        Argon2::default()
    }
}

pub fn hash_password(password: &str) -> Result<String, argon2::password_hash::Error> {
    let salt = SaltString::generate(&mut OsRng);
    let hash = Argon2Params::argon2().hash_password(password.as_bytes(), &salt)?;
    Ok(hash.to_string())
}

pub fn verify_password(password: &str, phc: &str) -> Result<bool, argon2::password_hash::Error> {
    let parsed = PasswordHash::new(phc)?;
    Ok(Argon2Params::argon2()
        .verify_password(password.as_bytes(), &parsed)
        .is_ok())
}

/// 是否需要按当前参数 rehash（用于登录成功后自动升级旧 hash）。
pub fn needs_rehash(phc: &str) -> bool {
    // 骨架：后续可解析 params 并与当前策略比对。
    phc.is_empty()
}
