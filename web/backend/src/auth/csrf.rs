//! CSRF 与哈希辅助。

use sha2::{Digest, Sha256};

/// SHA-256 hex（用于 session id / csrf token 的 hash 存储与比对）。
pub fn sha256_hex(input: &str) -> String {
    let mut h = Sha256::new();
    h.update(input.as_bytes());
    hex::encode(h.finalize())
}

/// 常量时间比较，避免时序侧信道。
pub fn constant_time_eq(a: &str, b: &str) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff: u8 = 0;
    for (x, y) in a.bytes().zip(b.bytes()) {
        diff |= x ^ y;
    }
    diff == 0
}
