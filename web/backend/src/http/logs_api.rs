//! P3 Logs 只读 API。仅暴露**固定 allowlist** 的日志源，绝不受理任意 path / unit。
//!
//! 安全边界：capability `logs.read`；source 必须命中固定集合；数据来自 logs 快照；
//! 无 shell、无任意文件读取。提供关键词搜索 + 下载（受大小上限）。

use std::collections::HashMap;

use axum::extract::{Query, State};
use axum::http::{HeaderMap, HeaderValue};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::Json;
use serde_json::{json, Value};

use crate::auth::guard::authenticate;
use crate::error::ApiError;
use crate::state::SharedState;

/// 固定日志源 allowlist（对应采集器 collect_logs）。不在此列的 source 一律拒绝。
const ALLOWED_SOURCES: &[&str] = &["boot", "failed-services", "auth-failures"];
const MAX_RETURN_LINES: usize = 500;
const MAX_DOWNLOAD_BYTES: usize = 512 * 1024;

fn read_logs_sources(state: &SharedState) -> Value {
    state
        .snapshots
        .read("logs")
        .and_then(|e| e.data.get("sources").cloned())
        .unwrap_or(Value::Null)
}

fn now_unix() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// GET /api/logs?source=<allowlist> —— 返回该源的行（可带 q 关键词过滤）。
async fn logs_source(
    State(state): State<SharedState>,
    headers: HeaderMap,
    Query(q): Query<HashMap<String, String>>,
) -> Result<Response, ApiError> {
    let auth = authenticate(&state, &headers)?;
    auth.require("logs.read")?;

    let source = q.get("source").map(String::as_str).unwrap_or("");
    if !ALLOWED_SOURCES.contains(&source) {
        return Err(ApiError::BadRequest("unknown log source".to_string()));
    }

    let now = now_unix();
    let fresh = serde_json::to_value(state.snapshots.freshness("logs", now)).unwrap_or(Value::Null);
    let sources = read_logs_sources(&state);
    let mut lines: Vec<String> = sources
        .get(source)
        .and_then(|s| s.get("lines"))
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default();

    if let Some(kw) = q.get("q") {
        if !kw.is_empty() {
            lines.retain(|l| l.contains(kw.as_str()));
        }
    }
    let truncated = lines.len() > MAX_RETURN_LINES; // 仅计数，保留末段
    lines = lines
        .into_iter()
        .rev()
        .take(MAX_RETURN_LINES)
        .rev()
        .collect();

    Ok(Json(json!({
        "ok": true,
        "data": { "source": source, "lines": lines, "truncated": truncated },
        "meta": { "freshness": fresh }
    }))
    .into_response())
}

/// GET /api/logs/download?source=<allowlist> —— 下载当前查询结果文本（受字节上限）。
async fn logs_download(
    State(state): State<SharedState>,
    headers: HeaderMap,
    Query(q): Query<HashMap<String, String>>,
) -> Result<Response, ApiError> {
    let auth = authenticate(&state, &headers)?;
    auth.require("logs.read")?;

    let source = q.get("source").map(String::as_str).unwrap_or("");
    if !ALLOWED_SOURCES.contains(&source) {
        return Err(ApiError::BadRequest("unknown log source".to_string()));
    }
    let sources = read_logs_sources(&state);
    let mut body: Vec<String> = sources
        .get(source)
        .and_then(|s| s.get("lines"))
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default();
    if let Some(kw) = q.get("q") {
        if !kw.is_empty() {
            body.retain(|l| l.contains(kw.as_str()));
        }
    }
    let text = body.join("\n");
    let text = if text.len() > MAX_DOWNLOAD_BYTES {
        text[..MAX_DOWNLOAD_BYTES].to_string()
    } else {
        text
    };

    let mut resp = (axum::http::StatusCode::OK, text).into_response();
    if let Ok(h) = HeaderValue::from_str("text/plain; charset=utf-8") {
        resp.headers_mut()
            .insert(axum::http::header::CONTENT_TYPE, h);
    }
    resp.headers_mut().insert(
        "content-disposition",
        HeaderValue::from_str(&format!("attachment; filename=\"{source}.log\""))
            .unwrap_or_else(|_| HeaderValue::from_static("attachment")),
    );
    Ok(resp)
}

pub fn router() -> axum::Router<SharedState> {
    axum::Router::new()
        .route("/api/logs", get(logs_source))
        .route("/api/logs/download", get(logs_download))
}
