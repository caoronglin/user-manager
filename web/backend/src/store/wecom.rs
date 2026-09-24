//! WeCom application settings and bounded delivery history.
//!
//! Webhook ciphertext only is accepted by this module; callers encrypt secrets
//! before persistence and never receive ciphertext through the HTTP API.

use rusqlite::{params, Connection};

#[derive(Clone, Debug)]
pub struct Settings {
    pub enabled: bool,
    pub dry_run: bool,
    pub webhook_ciphertext: Option<String>,
    pub events_json: String,
    pub updated_at: i64,
    pub updated_by: String,
    pub version: i64,
}

#[derive(Clone, Debug)]
pub struct Delivery {
    pub id: String,
    pub event_id: String,
    pub attempt: i64,
    pub started_at: i64,
    pub finished_at: i64,
    pub http_status: Option<i64>,
    pub remote_code: Option<String>,
    pub success: bool,
    pub error_class: Option<String>,
}

pub struct SettingsUpdate<'a> {
    pub expected_version: i64,
    pub enabled: bool,
    pub dry_run: bool,
    pub webhook_ciphertext: Option<&'a str>,
    pub events_json: &'a str,
    pub updated_at: i64,
    pub updated_by: &'a str,
}

pub fn get_settings(conn: &Connection) -> Result<Option<Settings>, rusqlite::Error> {
    conn.query_row(
        "SELECT enabled, dry_run, webhook_ciphertext, events_json, updated_at, updated_by, version
         FROM wecom_settings WHERE id = 1",
        [],
        |row| {
            Ok(Settings {
                enabled: row.get::<_, i64>(0)? != 0,
                dry_run: row.get::<_, i64>(1)? != 0,
                webhook_ciphertext: row.get(2)?,
                events_json: row.get(3)?,
                updated_at: row.get(4)?,
                updated_by: row.get(5)?,
                version: row.get(6)?,
            })
        },
    )
    .optional()
}

/// Insert when expected_version is 0, or update only the matching current version.
/// The affected row count is false on an optimistic-lock conflict.
pub fn save_settings(
    conn: &Connection,
    update: &SettingsUpdate<'_>,
) -> Result<bool, rusqlite::Error> {
    if update.expected_version == 0 {
        let inserted = conn.execute(
            "INSERT INTO wecom_settings
               (id, enabled, dry_run, webhook_ciphertext, events_json, updated_at, updated_by, version)
             VALUES (1, ?1, ?2, ?3, ?4, ?5, ?6, 1)
             ON CONFLICT(id) DO NOTHING",
            params![
                update.enabled as i64,
                update.dry_run as i64,
                update.webhook_ciphertext,
                update.events_json,
                update.updated_at,
                update.updated_by,
            ],
        )?;
        return Ok(inserted == 1);
    }

    let updated = conn.execute(
        "UPDATE wecom_settings
         SET enabled = ?1, dry_run = ?2, webhook_ciphertext = ?3, events_json = ?4,
             updated_at = ?5, updated_by = ?6, version = version + 1
         WHERE id = 1 AND version = ?7",
        params![
            update.enabled as i64,
            update.dry_run as i64,
            update.webhook_ciphertext,
            update.events_json,
            update.updated_at,
            update.updated_by,
            update.expected_version,
        ],
    )?;
    Ok(updated == 1)
}

pub fn insert_delivery(conn: &Connection, delivery: &Delivery) -> Result<(), rusqlite::Error> {
    conn.execute(
        "INSERT INTO wecom_deliveries
           (id, event_id, channel, attempt, started_at, finished_at, http_status,
            remote_code, success, error_class)
         VALUES (?1, ?2, 'wecom', ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        params![
            delivery.id,
            delivery.event_id,
            delivery.attempt,
            delivery.started_at,
            delivery.finished_at,
            delivery.http_status,
            delivery.remote_code,
            delivery.success as i64,
            delivery.error_class,
        ],
    )?;
    // Keep history bounded even if test sends are repeated indefinitely.
    conn.execute(
        "DELETE FROM wecom_deliveries WHERE id IN (
           SELECT id FROM wecom_deliveries
           ORDER BY started_at DESC, id DESC LIMIT -1 OFFSET 1000
         )",
        [],
    )?;
    Ok(())
}

pub fn list_deliveries(conn: &Connection, limit: usize) -> Result<Vec<Delivery>, rusqlite::Error> {
    let mut statement = conn.prepare(
        "SELECT id, event_id, attempt, started_at, finished_at, http_status,
                remote_code, success, error_class
         FROM wecom_deliveries ORDER BY started_at DESC, id DESC LIMIT ?1",
    )?;
    let rows = statement.query_map(params![limit.clamp(1, 100) as i64], |row| {
        Ok(Delivery {
            id: row.get(0)?,
            event_id: row.get(1)?,
            attempt: row.get(2)?,
            started_at: row.get(3)?,
            finished_at: row.get(4)?,
            http_status: row.get(5)?,
            remote_code: row.get(6)?,
            success: row.get::<_, i64>(7)? != 0,
            error_class: row.get(8)?,
        })
    })?;
    rows.collect()
}

use rusqlite::OptionalExtension;
