//! 统一错误类型 → HTTP 响应。错误消息经过 secret 脱敏。

use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde_json::json;

#[derive(Debug)]
pub enum ApiError {
    Unauthorized,
    Forbidden,
    NotFound,
    MethodNotAllowed,
    BadRequest(String),
    RateLimited,
    Internal(String),
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let (status, code, message) = match self {
            ApiError::Unauthorized => (StatusCode::UNAUTHORIZED, "AUTH_REQUIRED", "authentication required".to_string()),
            ApiError::Forbidden => (StatusCode::FORBIDDEN, "FORBIDDEN", "insufficient capability".to_string()),
            ApiError::NotFound => (StatusCode::NOT_FOUND, "NOT_FOUND", "not found".to_string()),
            ApiError::MethodNotAllowed => (StatusCode::METHOD_NOT_ALLOWED, "METHOD_NOT_ALLOWED", "method not allowed".to_string()),
            ApiError::BadRequest(m) => (StatusCode::BAD_REQUEST, "BAD_REQUEST", sanitize(&m)),
            ApiError::RateLimited => (StatusCode::TOO_MANY_REQUESTS, "RATE_LIMITED", "too many requests".to_string()),
            ApiError::Internal(m) => (StatusCode::INTERNAL_SERVER_ERROR, "INTERNAL", sanitize(&m)),
        };

        let body = Json(json!({
            "ok": false,
            "error": { "code": code, "message": message },
        }));
        (status, body).into_response()
    }
}

fn sanitize(s: &str) -> String {
    crate::telemetry::redact(s)
}
