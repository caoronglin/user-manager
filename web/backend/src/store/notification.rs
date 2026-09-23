//! 通知中心 inbox 存储。站内事件与投递(delivery)解耦。
//!
//! 事件数据不得包含 secret（见 plan.md §10.7）：调用方负责只放入安全字段。

use rusqlite::{params, params_from_iter, Connection, ToSql};
use serde_json::Value;

#[derive(Clone, Debug)]
pub struct Notification {
    pub id: String,
    pub event_type: String,
    pub severity: String,
    pub title: String,
    pub summary: String,
    pub target: Option<String>,
    pub source: Option<String>,
    pub event_id: Option<String>,
    pub read: bool,
    pub created_at: i64,
}

pub struct NotificationIn {
    pub id: String,
    pub event_type: String,
    pub severity: String,
    pub title: String,
    pub summary: String,
    pub target: Option<String>,
    pub source: Option<String>,
    pub event_id: Option<String>,
}

/// 返回 true 表示插入，false 表示已处理过相同 event_id。
pub fn insert(conn: &Connection, n: &NotificationIn) -> Result<bool, rusqlite::Error> {
    let inserted = conn.execute(
        "INSERT INTO notifications (id, event_type, severity, title, summary, target, source, event_id, read, created_at)\n         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 0, ?9)\n         ON CONFLICT(event_id) WHERE event_id IS NOT NULL DO NOTHING",
        params![
            n.id,
            n.event_type,
            n.severity,
            n.title,
            n.summary,
            n.target,
            n.source,
            n.event_id,
            now_unix()
        ],
    )?;
    Ok(inserted > 0)
}

#[derive(Default)]
pub struct ListFilter {
    pub unread_only: bool,
    pub event_type: Option<String>,
    /// Validated by the HTTP layer to be between 1 and 200.
    pub limit: usize,
    pub cursor_created_at: Option<i64>,
    pub cursor_id: Option<String>,
}

pub struct NotificationPage {
    pub items: Vec<Notification>,
    pub has_more: bool,
}

/// Keyset pagination uses `(created_at DESC, id DESC)` and binds every filter.
pub fn list(conn: &Connection, filter: &ListFilter) -> Result<NotificationPage, rusqlite::Error> {
    let mut sql = String::from(
        "SELECT id, event_type, severity, title, summary, target, source, event_id, read, created_at\n         FROM notifications WHERE 1=1",
    );
    let mut args: Vec<Box<dyn ToSql>> = Vec::new();

    if filter.unread_only {
        sql.push_str(" AND read = 0");
    }
    if let Some(event_type) = filter.event_type.as_ref().filter(|s| !s.is_empty()) {
        args.push(Box::new(event_type.clone()));
        sql.push_str(&format!(" AND event_type = ?{}", args.len()));
    }
    if let (Some(created_at), Some(id)) = (filter.cursor_created_at, filter.cursor_id.as_ref()) {
        args.push(Box::new(created_at));
        let timestamp_param = args.len();
        args.push(Box::new(id.clone()));
        let id_param = args.len();
        sql.push_str(&format!(
            " AND (created_at < ?{timestamp_param} OR (created_at = ?{timestamp_param} AND id < ?{id_param}))"
        ));
    }

    // Fetch one extra row to indicate whether the client can request another page.
    let page_limit = filter.limit.clamp(1, 200);
    args.push(Box::new((page_limit + 1) as i64));
    sql.push_str(&format!(
        " ORDER BY created_at DESC, id DESC LIMIT ?{}",
        args.len()
    ));

    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map(
        params_from_iter(args.iter().map(|arg| arg.as_ref())),
        |row| {
            Ok(Notification {
                id: row.get(0)?,
                event_type: row.get(1)?,
                severity: row.get(2)?,
                title: row.get(3)?,
                summary: row.get(4)?,
                target: row.get(5)?,
                source: row.get(6)?,
                event_id: row.get(7)?,
                read: row.get::<_, i64>(8)? != 0,
                created_at: row.get(9)?,
            })
        },
    )?;
    let mut items = rows.collect::<Result<Vec<_>, _>>()?;
    let has_more = items.len() > page_limit;
    items.truncate(page_limit);

    Ok(NotificationPage { items, has_more })
}

pub fn unread_count(conn: &Connection) -> Result<i64, rusqlite::Error> {
    conn.query_row(
        "SELECT COUNT(*) FROM notifications WHERE read = 0",
        [],
        |row| row.get(0),
    )
}

/// Mark an existing notification as read. Repeating the operation is safe.
pub fn mark_read(conn: &Connection, id: &str) -> Result<bool, rusqlite::Error> {
    Ok(conn.execute(
        "UPDATE notifications SET read = 1 WHERE id = ?1",
        params![id],
    )? > 0)
}

pub fn mark_all_read(conn: &Connection) -> Result<usize, rusqlite::Error> {
    conn.execute("UPDATE notifications SET read = 1 WHERE read = 0", [])
}

pub fn to_json(notification: &Notification) -> Value {
    serde_json::json!({
        "id": notification.id,
        "event_type": notification.event_type,
        "severity": notification.severity,
        "title": notification.title,
        "summary": notification.summary,
        "target": notification.target,
        "source": notification.source,
        "event_id": notification.event_id,
        "read": notification.read,
        "created_at": notification.created_at,
    })
}

fn now_unix() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0)
}
