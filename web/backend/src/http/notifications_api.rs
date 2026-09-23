//! P4c 通知中心 inbox API。notifications.read / notifications.manage。
//!
//! - GET  /api/notifications?unread=&type=&limit=&cursor_ts=&cursor_id=
//! - GET  /api/notifications/unread-count
//! - POST /api/notifications/read {id}          （notifications.manage）
//! - POST /api/notifications/read-all           （notifications.manage）

use axum::extract::{Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::auth::guard::authenticate;
use crate::error::ApiError;
use crate::state::SharedState;

fn bad(message: &str) -> ApiError {
    ApiError::BadRequest(message.to_string())
}

fn internal() -> ApiError {
    ApiError::Internal("internal".to_string())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct InboxQuery {
    unread: Option<String>,
    #[serde(rename = "type")]
    event_type: Option<String>,
    limit: Option<usize>,
    cursor_ts: Option<i64>,
    cursor_id: Option<String>,
}

async fn inbox(
    State(state): State<SharedState>,
    headers: HeaderMap,
    Query(query): Query<InboxQuery>,
) -> Result<Response, ApiError> {
    let auth = authenticate(&state, &headers)?;
    auth.require("notifications.read")?;

    let unread_only = match query.unread.as_deref() {
        None | Some("0") | Some("false") => false,
        Some("1") | Some("true") => true,
        Some(_) => return Err(bad("unread must be true, false, 1, or 0")),
    };
    if query
        .event_type
        .as_ref()
        .is_some_and(|event_type| event_type.is_empty() || event_type.len() > 128)
    {
        return Err(bad("type must contain 1 to 128 bytes"));
    }
    let limit = query.limit.unwrap_or(50);
    if !(1..=200).contains(&limit) {
        return Err(bad("limit must be between 1 and 200"));
    }
    let (cursor_created_at, cursor_id) = match (query.cursor_ts, query.cursor_id) {
        (None, None) => (None, None),
        (Some(created_at), Some(id)) if created_at >= 0 && !id.is_empty() && id.len() <= 128 => {
            (Some(created_at), Some(id))
        }
        _ => return Err(bad("cursor_ts and cursor_id must be provided together")),
    };

    let filter = crate::store::notification::ListFilter {
        unread_only,
        event_type: query.event_type,
        limit,
        cursor_created_at,
        cursor_id,
    };
    let conn = state.db.lock().map_err(|_| internal())?;
    let page = crate::store::notification::list(&conn, &filter).map_err(|_| internal())?;
    let unread = crate::store::notification::unread_count(&conn).map_err(|_| internal())?;
    let items: Vec<Value> = page
        .items
        .iter()
        .map(crate::store::notification::to_json)
        .collect();
    let next_cursor = if page.has_more {
        page.items
            .last()
            .map(|item| json!({ "created_at": item.created_at, "id": item.id }))
    } else {
        None
    };

    Ok(Json(json!({
        "ok": true,
        "data": {
            "items": items,
            "unread": unread,
            "next_cursor": next_cursor,
        }
    }))
    .into_response())
}

async fn unread_count(
    State(state): State<SharedState>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let auth = authenticate(&state, &headers)?;
    auth.require("notifications.read")?;
    let conn = state.db.lock().map_err(|_| internal())?;
    let unread = crate::store::notification::unread_count(&conn).map_err(|_| internal())?;
    Ok(Json(json!({ "ok": true, "data": { "unread": unread } })).into_response())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct MarkReadRequest {
    id: String,
}

async fn mark_read(
    State(state): State<SharedState>,
    headers: HeaderMap,
    Json(body): Json<MarkReadRequest>,
) -> Result<Response, ApiError> {
    let auth = authenticate(&state, &headers)?;
    auth.require("notifications.manage")?;
    if body.id.is_empty() || body.id.len() > 128 {
        return Err(bad("id must contain 1 to 128 bytes"));
    }
    let conn = state.db.lock().map_err(|_| internal())?;
    let found = crate::store::notification::mark_read(&conn, &body.id).map_err(|_| internal())?;
    if !found {
        return Err(ApiError::NotFound);
    }
    Ok(StatusCode::NO_CONTENT.into_response())
}

async fn mark_all_read(
    State(state): State<SharedState>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let auth = authenticate(&state, &headers)?;
    auth.require("notifications.manage")?;
    let conn = state.db.lock().map_err(|_| internal())?;
    let updated = crate::store::notification::mark_all_read(&conn).map_err(|_| internal())?;
    Ok(Json(json!({ "ok": true, "data": { "updated": updated } })).into_response())
}

pub fn read_router() -> axum::Router<SharedState> {
    axum::Router::new()
        .route("/api/notifications", get(inbox))
        .route("/api/notifications/unread-count", get(unread_count))
}

pub fn mutating_router() -> axum::Router<SharedState> {
    axum::Router::new()
        .route("/api/notifications/read", post(mark_read))
        .route("/api/notifications/read-all", post(mark_all_read))
}
