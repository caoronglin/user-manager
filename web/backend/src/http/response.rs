//! 统一响应信封（见 plan.md 第 8 节）。
//! 成功：{ ok: true, data, meta: { generated_at } }
//! 错误：{ ok: false, error: { code, message }, meta }（见 crate::error）

use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::Serialize;
use serde_json::json;

pub fn ok<T: Serialize>(data: T) -> Response {
    Json(json!({
        "ok": true,
        "data": data,
        "meta": { "generated_at": now_rfc3339() },
    }))
    .into_response()
}

pub fn now_rfc3339() -> String {
    time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_string())
}
