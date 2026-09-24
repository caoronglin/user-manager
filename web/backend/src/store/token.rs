//! API Token 存储（hash-only）。明文只在创建响应返回一次；DB 仅存 SHA-256 hash。
//!
//! 能力 allowlist：每个 token 绑定一组 capability（受 KNOWN_CAPS 约束），可过期、可撤销。

use rusqlite::{params, Connection};

use super::notification::{self, NotificationIn};

#[derive(Clone, Debug)]
pub struct TokenRow {
    pub id: String,
    pub name: String,
    pub capabilities: Vec<String>,
    pub created_at: i64,
    pub expires_at: i64,
    pub revoked: bool,
}

pub fn insert_token(
    conn: &Connection,
    id: &str,
    name: &str,
    token_hash: &str,
    capabilities_json: &str,
    expires_at: i64,
) -> Result<(), rusqlite::Error> {
    conn.execute(
        "INSERT INTO api_tokens (id, name, token_hash, capabilities, created_at, expires_at, revoked)\n         VALUES (?1, ?2, ?3, ?4, ?5, ?6, 0)",
        params![id, name, token_hash, capabilities_json, now_unix(), expires_at],
    )?;
    Ok(())
}

pub fn list_tokens(conn: &Connection) -> Vec<TokenRow> {
    let mut stmt = match conn.prepare(
        "SELECT id, name, capabilities, created_at, expires_at, revoked FROM api_tokens ORDER BY created_at DESC",
    ) {
        Ok(s) => s,
        Err(_) => return Vec::new(),
    };
    let rows = stmt.query_map([], |r| {
        let caps_json: String = r.get(2)?;
        Ok(TokenRow {
            id: r.get(0)?,
            name: r.get(1)?,
            capabilities: serde_json::from_str(&caps_json).unwrap_or_default(),
            created_at: r.get(3)?,
            expires_at: r.get(4)?,
            revoked: r.get::<_, i64>(5)? != 0,
        })
    });
    match rows {
        Ok(it) => it.filter_map(Result::ok).collect(),
        Err(_) => Vec::new(),
    }
}

/// 按 hash 查询有效 token：未撤销且未过期。
pub fn find_active_by_hash(conn: &Connection, token_hash: &str, now: i64) -> Option<TokenRow> {
    conn.query_row(
        "SELECT id, name, capabilities, created_at, expires_at, revoked FROM api_tokens\n         WHERE token_hash = ?1 AND revoked = 0 AND expires_at > ?2",
        params![token_hash, now],
        |r| {
            let caps_json: String = r.get(2)?;
            Ok(TokenRow {
                id: r.get(0)?,
                name: r.get(1)?,
                capabilities: serde_json::from_str(&caps_json).unwrap_or_default(),
                created_at: r.get(3)?,
                expires_at: r.get(4)?,
                revoked: r.get::<_, i64>(5)? != 0,
            })
        },
    )
    .ok()
}

pub fn revoke_token(conn: &mut Connection, id: &str) -> Result<bool, rusqlite::Error> {
    let tx = conn.transaction()?;
    let changed = tx.execute(
        "UPDATE api_tokens SET revoked = 1 WHERE id = ?1 AND revoked = 0",
        params![id],
    )?;
    if changed == 1 {
        notification::insert(
            &tx,
            &NotificationIn {
                id: uuid::Uuid::new_v4().to_string(),
                event_type: "security.token_revoked".to_string(),
                severity: "warning".to_string(),
                title: "API token revoked".to_string(),
                summary: "An API token was revoked.".to_string(),
                target: None,
                source: Some("web".to_string()),
                event_id: Some(format!("security.token_revoked:{id}")),
            },
        )?;
    }
    tx.commit()?;
    Ok(changed == 1)
}

fn now_unix() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}
