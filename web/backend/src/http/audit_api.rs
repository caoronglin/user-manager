//! P3 Audit 只读 API：来源仅限 audit-summary 快照；支持过滤、游标分页、CSV/JSON 导出。
//!
//! 安全边界：capability `audit.read`；不接收原始 SQL；过滤/分页全部在内存对快照 JSON 进行；
//! 导出有行数/字节上限；detail 不含敏感字段（快照已 scrub，且不含 details 原文）。

use std::collections::HashMap;

use axum::extract::{Query, State};
use axum::http::{HeaderMap, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::Json;
use serde_json::{json, Value};

use crate::auth::guard::authenticate;
use crate::error::ApiError;
use crate::state::SharedState;

const MAX_LIMIT: usize = 200;
const MAX_EXPORT_ROWS: usize = 1000;
const MAX_EXPORT_BYTES: usize = 512 * 1024;

fn now_unix() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn read_audit_items(state: &SharedState) -> (Vec<Value>, Value) {
    let now = now_unix();
    let fresh = serde_json::to_value(state.snapshots.freshness("audit-summary", now))
        .unwrap_or(Value::Null);
    let items = state
        .snapshots
        .read("audit-summary")
        .and_then(|e| e.data.get("recent").cloned())
        .and_then(|v| v.as_array().cloned())
        .unwrap_or_default();
    (items, fresh)
}

/// item 是否匹配过滤条件。from/to 与 timestamp 做字符串比较（timestamp 为 RFC3339/日期）。
fn matches(item: &Value, f: &HashMap<String, String>) -> bool {
    if let Some(u) = f.get("user") {
        if !u.is_empty() && item.get("user").and_then(Value::as_str) != Some(u.as_str()) {
            return false;
        }
    }
    if let Some(a) = f.get("action") {
        if !a.is_empty() && item.get("action").and_then(Value::as_str) != Some(a.as_str()) {
            return false;
        }
    }
    if let Some(r) = f.get("result") {
        if !r.is_empty() && item.get("result").and_then(Value::as_str) != Some(r.as_str()) {
            return false;
        }
    }
    let ts = item.get("timestamp").and_then(Value::as_str).unwrap_or("");
    if let Some(from) = f.get("from") {
        if !from.is_empty() && ts < from.as_str() {
            return false;
        }
    }
    if let Some(to) = f.get("to") {
        if !to.is_empty() && ts > to.as_str() {
            return false;
        }
    }
    true
}

/// GET /api/audit?user=&action=&result=&from=&to=&limit=&cursor=
async fn audit_list(
    State(state): State<SharedState>,
    headers: HeaderMap,
    Query(q): Query<HashMap<String, String>>,
) -> Result<Response, ApiError> {
    let auth = authenticate(&state, &headers)?;
    auth.require("audit.read")?;

    let (items, fresh) = read_audit_items(&state);
    let filtered: Vec<Value> = items.iter().filter(|it| matches(it, &q)).cloned().collect();

    let cursor: usize = q.get("cursor").and_then(|s| s.parse().ok()).unwrap_or(0);
    let limit: usize = q
        .get("limit")
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(50)
        .clamp(1, MAX_LIMIT);

    let end = (cursor + limit).min(filtered.len());
    let page: Vec<Value> = filtered
        .get(cursor..end)
        .map(|s| s.to_vec())
        .unwrap_or_default();
    let next_cursor = if end < filtered.len() {
        Some(end)
    } else {
        None
    };

    Ok(Json(json!({
        "ok": true,
        "data": { "items": page, "next_cursor": next_cursor, "total_matched": filtered.len() },
        "meta": { "freshness": fresh }
    }))
    .into_response())
}

/// GET /api/audit/export?format=csv|json （同样过滤；受行数/字节上限）。
async fn audit_export(
    State(state): State<SharedState>,
    headers: HeaderMap,
    Query(q): Query<HashMap<String, String>>,
) -> Result<Response, ApiError> {
    let auth = authenticate(&state, &headers)?;
    auth.require("audit.read")?;

    let (items, _fresh) = read_audit_items(&state);
    let filtered: Vec<Value> = items.iter().filter(|it| matches(it, &q)).cloned().collect();
    let truncated = filtered.len() > MAX_EXPORT_ROWS;
    let filtered: Vec<Value> = filtered.into_iter().take(MAX_EXPORT_ROWS).collect();
    let format = q.get("format").map(String::as_str).unwrap_or("json");

    let (ctype, body): (&str, String) = match format {
        "csv" => {
            let mut s = String::from("timestamp,user,action,target,result\n");
            for it in &filtered {
                let g = |k: &str| it.get(k).and_then(Value::as_str).unwrap_or("");
                s.push_str(&format!(
                    "{},{},{},{},{}\n",
                    g("timestamp"),
                    g("user"),
                    g("action"),
                    g("target"),
                    g("result")
                ));
            }
            if s.len() > MAX_EXPORT_BYTES {
                s.truncate(MAX_EXPORT_BYTES);
            }
            ("text/csv; charset=utf-8", s)
        }
        _ => {
            let arr = filtered;
            let body = serde_json::to_string(&json!({ "items": arr })).unwrap_or_default();
            let body = if body.len() > MAX_EXPORT_BYTES {
                body[..MAX_EXPORT_BYTES].to_string()
            } else {
                body
            };
            ("application/json", body)
        }
    };

    let mut resp = (StatusCode::OK, body).into_response();
    if let Ok(h) = HeaderValue::from_str(ctype) {
        resp.headers_mut()
            .insert(axum::http::header::CONTENT_TYPE, h);
    }
    if truncated {
        resp.headers_mut()
            .insert("x-export-truncated", HeaderValue::from_static("true"));
    }
    tracing::info!(event = "audit.export", format = format, user = %auth.user_id, "audit export");
    Ok(resp)
}

pub fn router() -> axum::Router<SharedState> {
    axum::Router::new()
        .route("/api/audit", get(audit_list))
        .route("/api/audit/export", get(audit_export))
}
