//! Web 用户存储（仅 Web 身份库，与 Linux 用户完全解耦）。
//!
//! - 用户名/角色/Argon2id 密码 hash；
//! - MFA/TOTP secret 加密字段（P4 用 Web master key），此处不读取明文；
//! - 绝不创建/触碰 Linux 账户。

use rusqlite::{params, Connection};

#[derive(Clone, Debug)]
pub struct WebUser {
    pub id: String,
    pub username: String,
    pub role: String,
    pub password_hash: String,
    pub mfa_enabled: bool,
}

pub fn insert_user(
    conn: &Connection,
    id: &str,
    username: &str,
    role: &str,
    password_hash: &str,
) -> Result<(), rusqlite::Error> {
    let now = now_unix();
    conn.execute(
        "INSERT INTO web_users (id, username, role, password_hash, mfa_enabled, created_at, updated_at)\n         VALUES (?1, ?2, ?3, ?4, 0, ?5, ?5)",
        params![id, username, role, password_hash, now],
    )?;
    Ok(())
}

pub fn get_by_username(conn: &Connection, username: &str) -> Option<WebUser> {
    conn.query_row(
        "SELECT id, username, role, password_hash, mfa_enabled FROM web_users WHERE username = ?1",
        params![username],
        row_to_user,
    )
    .ok()
}

pub fn get_by_id(conn: &Connection, id: &str) -> Option<WebUser> {
    conn.query_row(
        "SELECT id, username, role, password_hash, mfa_enabled FROM web_users WHERE id = ?1",
        params![id],
        row_to_user,
    )
    .ok()
}

pub fn list_users(conn: &Connection) -> Vec<WebUser> {
    let mut stmt = match conn.prepare(
        "SELECT id, username, role, password_hash, mfa_enabled FROM web_users ORDER BY username",
    ) {
        Ok(s) => s,
        Err(_) => return Vec::new(),
    };
    let rows = stmt.query_map([], row_to_user);
    match rows {
        Ok(it) => it.filter_map(Result::ok).collect(),
        Err(_) => Vec::new(),
    }
}

pub fn update_role(conn: &Connection, id: &str, role: &str) -> Result<(), rusqlite::Error> {
    conn.execute(
        "UPDATE web_users SET role = ?2, updated_at = ?3 WHERE id = ?1",
        params![id, role, now_unix()],
    )?;
    Ok(())
}

pub fn update_password(
    conn: &Connection,
    id: &str,
    password_hash: &str,
) -> Result<(), rusqlite::Error> {
    conn.execute(
        "UPDATE web_users SET password_hash = ?2, updated_at = ?3 WHERE id = ?1",
        params![id, password_hash, now_unix()],
    )?;
    Ok(())
}

pub fn delete_user(conn: &Connection, id: &str) -> Result<(), rusqlite::Error> {
    conn.execute("DELETE FROM web_users WHERE id = ?1", params![id])?;
    Ok(())
}

/// 保存加密的 TOTP secret（mfa_secret_cipher）；尚未启用。
pub fn set_mfa_secret(conn: &Connection, id: &str, cipher: &str) -> Result<(), rusqlite::Error> {
    conn.execute(
        "UPDATE web_users SET mfa_secret_cipher = ?2, mfa_enabled = 0, updated_at = ?3 WHERE id = ?1",
        params![id, cipher, now_unix()],
    )?;
    Ok(())
}

/// 读取加密的 TOTP secret。
pub fn get_mfa_secret(conn: &Connection, id: &str) -> Option<String> {
    conn.query_row(
        "SELECT mfa_secret_cipher FROM web_users WHERE id = ?1",
        params![id],
        |r| r.get::<_, Option<String>>(0),
    )
    .ok()
    .flatten()
}

/// 验证通过后启用 MFA。
pub fn enable_mfa(conn: &Connection, id: &str) -> Result<(), rusqlite::Error> {
    conn.execute(
        "UPDATE web_users SET mfa_enabled = 1, updated_at = ?2 WHERE id = ?1",
        params![id, now_unix()],
    )?;
    Ok(())
}

/// 停用 MFA 并清空加密 secret。
pub fn disable_mfa(conn: &Connection, id: &str) -> Result<(), rusqlite::Error> {
    conn.execute(
        "UPDATE web_users SET mfa_enabled = 0, mfa_secret_cipher = NULL, updated_at = ?2 WHERE id = ?1",
        params![id, now_unix()],
    )?;
    Ok(())
}

fn row_to_user(row: &rusqlite::Row<'_>) -> rusqlite::Result<WebUser> {
    Ok(WebUser {
        id: row.get(0)?,
        username: row.get(1)?,
        role: row.get(2)?,
        password_hash: row.get(3)?,
        mfa_enabled: row.get::<_, i64>(4)? != 0,
    })
}

pub fn count(conn: &Connection) -> i64 {
    conn.query_row("SELECT COUNT(*) FROM web_users", [], |r| r.get(0))
        .unwrap_or(0)
}

fn now_unix() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}
