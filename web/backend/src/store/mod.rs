//! Web SQLite schema。仅存 Web 自身数据；
//! **绝不**存明文密码/token/webhook/TOTP secret。

use rusqlite::Connection;

pub mod event_spool;
pub mod notification;
pub mod snapshot;
pub mod snapshot_observer;
pub mod token;
pub mod user;
pub mod wecom;

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

        CREATE TABLE IF NOT EXISTS wecom_deliveries (
            id           TEXT PRIMARY KEY,
            event_id     TEXT NOT NULL,
            channel      TEXT NOT NULL DEFAULT 'wecom',
            attempt      INTEGER NOT NULL,
            started_at   INTEGER NOT NULL,
            finished_at  INTEGER NOT NULL,
            http_status  INTEGER,
            remote_code  TEXT,
            success      INTEGER NOT NULL DEFAULT 0,
            error_class  TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_wecom_deliveries_started
            ON wecom_deliveries(started_at DESC, id DESC);

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

        -- 通知中心 inbox：站内事件（来自 Web 安全事件 / 快照规则 / event spool）。
        CREATE TABLE IF NOT EXISTS notifications (
            id          TEXT PRIMARY KEY,
            event_type  TEXT NOT NULL,
            severity    TEXT NOT NULL,
            title       TEXT NOT NULL,
            summary     TEXT NOT NULL,
            target      TEXT,
            source      TEXT,
            event_id    TEXT,
            read        INTEGER NOT NULL DEFAULT 0,
            created_at  INTEGER NOT NULL
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_notifications_event_id
            ON notifications(event_id) WHERE event_id IS NOT NULL;
        CREATE INDEX IF NOT EXISTS idx_notifications_created
            ON notifications(created_at DESC, id DESC);
        CREATE INDEX IF NOT EXISTS idx_notifications_unread
            ON notifications(created_at DESC, id DESC) WHERE read = 0;
        "#,
    )?;
    Ok(())
}
