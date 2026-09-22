//! Web SQLite schema。仅存 Web 自身数据；
//! **绝不**存明文密码/token/webhook/TOTP secret。

use rusqlite::Connection;

pub mod snapshot;
pub mod token;
pub mod user;

pub fn init_schema(conn: &Connection) -> Result<(), rusqlite::Error> {
    conn.execute_batch(
        r#"
        PRAGMA journal_mode = WAL;
        PRAGMA foreign_keys = ON;

        CREATE TABLE IF NOT EXISTS web_users (
            id                TEXT PRIMARY KEY,
            username          TEXT NOT NULL UNIQUE,
            role              TEXT NOT NULL,
            password_hash     TEXT NOT NULL,        -- Argon2id PHC（非明文）
            mfa_secret_cipher BLOB,                 -- 加密存储（Web master key）；非明文
            mfa_enabled       INTEGER NOT NULL DEFAULT 0,
            created_at        INTEGER NOT NULL,
            updated_at        INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS sessions (
            id_hash      TEXT PRIMARY KEY,          -- 仅存 session id 的 hash
            user_id      TEXT NOT NULL,
            csrf_hash    TEXT NOT NULL,
            mfa_done     INTEGER NOT NULL DEFAULT 0,
            created_at   INTEGER NOT NULL,
            expires_at   INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS api_tokens (
            id           TEXT PRIMARY KEY,
            name         TEXT NOT NULL,
            token_hash   TEXT NOT NULL,             -- 仅存 hash；明文只在创建时显示一次
            capabilities TEXT NOT NULL,             -- JSON allowlist
            created_at   INTEGER NOT NULL,
            expires_at   INTEGER NOT NULL,
            revoked      INTEGER NOT NULL DEFAULT 0
        );

        -- wecom_settings：enabled / dry_run / webhook_ciphertext（加密，不存明文）/
        -- events_json / updated_at / updated_by / version（乐观锁）。
        CREATE TABLE IF NOT EXISTS wecom_settings (
            id                 INTEGER PRIMARY KEY CHECK (id = 1),
            enabled            INTEGER NOT NULL DEFAULT 0,
            dry_run            INTEGER NOT NULL DEFAULT 0,
            webhook_ciphertext BLOB,
            events_json        TEXT NOT NULL DEFAULT '[]',
            updated_at         INTEGER NOT NULL,
            updated_by         TEXT NOT NULL,
            version            INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS web_audit (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            request_id   TEXT,
            ts           INTEGER NOT NULL,
            web_user_id  TEXT,
            session_hash TEXT,
            source_ip    TEXT,
            method       TEXT,
            route_name   TEXT,
            capability   TEXT,
            target       TEXT,
            result       TEXT
        );
        "#,
    )?;
    Ok(())
}
