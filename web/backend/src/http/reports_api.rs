//! P3 Reports 只读 API：仅列出来自 reports 快照的报告**元数据索引**（名称/大小/修改时间），
//! 支持 CSV/JSON 导出。capability `reports.read`。
//!
//! 安全边界：不读取报告**内容**（内容可能含敏感用户明细，且需防任意文件读取），
//! 仅暴露快照已产出的元数据索引；无 shell、无任意文件读取。

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

const MAX_EXPORT_ROWS: usize = 1000;

fn now_unix() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn read_reports(state: &SharedState) -> (Vec<Value>, Value) {
    let now = now_unix();
    let fresh =
        serde_json::to_value(state.snapshots.freshness("reports", now)).unwrap_or(Value::Null);
    let items = state
        .snapshots
        .read("reports")
        .and_then(|e| e.data.get("reports").cloned())
        .and_then(|v| v.as_array().cloned())
        .unwrap_or_default();
    (items, fresh)
}

/// GET /api/reports —— 列出来自快照的报告元数据索引。
async fn reports_list(
    State(state): State<SharedState>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let auth = authenticate(&state, &headers)?;
    auth.require("reports.read")?;
    let (items, fresh) = read_reports(&state);
    Ok(Json(json!({
        "ok": true,
        "data": { "reports": items, "count": items_len(&items) },
        "meta": { "freshness": fresh }
    }))
    .into_response())
}

fn items_len(items: &[Value]) -> usize {
    items.len()
}

/// GET /api/reports/export?format=csv|json —— 导出报告索引（仅元数据）。
async fn reports_export(
    State(state): State<SharedState>,
    headers: HeaderMap,
    Query(q): Query<HashMap<String, String>>,
) -> Result<Response, ApiError> {
    let auth = authenticate(&state, &headers)?;
    auth.require("reports.read")?;

    let (items, _fresh) = read_reports(&state);
    let items: Vec<Value> = items.into_iter().take(MAX_EXPORT_ROWS).collect();
    let format = q.get("format").map(String::as_str).unwrap_or("json");

    let (ctype, body): (&str, String) = match format {
        "csv" => {
            let mut s = String::from("name,size_bytes,modified_at\n");
            for it in &items {
                let g = |k: &str| it.get(k).and_then(Value::as_str).unwrap_or("");
                let size = it
                    .get("size_bytes")
                    .map(|v| v.to_string())
                    .unwrap_or_default();
                let mtime = it
                    .get("modified_at")
                    .map(|v| v.to_string())
                    .unwrap_or_default();
                s.push_str(&format!("{},{},{}\n", g("name"), size, mtime));
            }
            ("text/csv; charset=utf-8", s)
        }
        _ => {
            let body = serde_json::to_string(&json!({ "reports": items })).unwrap_or_default();
            ("application/json", body)
        }
    };

    let mut resp = (axum::http::StatusCode::OK, body).into_response();
    if let Ok(h) = HeaderValue::from_str(ctype) {
        resp.headers_mut()
            .insert(axum::http::header::CONTENT_TYPE, h);
    }
    Ok(resp)
}

pub fn router() -> axum::Router<SharedState> {
    axum::Router::new()
        .route("/api/reports", get(reports_list))
        .route("/api/reports/export", get(reports_export))
}
