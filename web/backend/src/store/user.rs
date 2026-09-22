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
        |row| {
            Ok(WebUser {
                id: row.get(0)?,
                username: row.get(1)?,
                role: row.get(2)?,
                password_hash: row.get(3)?,
                mfa_enabled: row.get::<_, i64>(4)? != 0,
            })
        },
    )
    .ok()
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
