//! 中间件：request-id、security headers（CSP/HSTS/nosniff/Referrer-Policy/Permissions-Policy）、
//! Origin 校验、CSRF、限流（限流在 auth::rate_limit，按 IP+username 维度）。
//!
//! 关键安全点：
//! - request-id：CSPRNG UUID，进入响应头与 tracing，供跨系统关联；
//! - security headers：对每个响应统一注入；
//! - secret redaction：日志/错误消息不泄密（见 telemetry::redact）。

use std::time::Duration;

use axum::extract::{Request, State};
use axum::http::{header, HeaderValue, Method, StatusCode};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};

use crate::state::SharedState;

pub const REQUEST_ID_HEADER: &str = "x-request-id";

/// 生成并注入 request-id，并记录访问日志（不含敏感头/体）。
pub async fn request_id(
    State(_state): State<SharedState>,
    mut req: Request,
    next: Next,
) -> Response {
    let request_id = uuid::Uuid::new_v4().to_string();
    if let Ok(val) = HeaderValue::from_str(&request_id) {
        req.headers_mut().insert(REQUEST_ID_HEADER, val.clone());
    }
    // 存入扩展，供后续 handler/审计读取。
    req.extensions_mut().insert(RequestId(request_id.clone()));

    let method = req.method().clone();
    let path = req.uri().path().to_string();
    let resp = next.run(req).await;

    tracing::info!(%request_id, %method, %path, status = %resp.status().as_u16(), "request");

    let mut resp = resp;
    if let Ok(val) = HeaderValue::from_str(&request_id) {
        resp.headers_mut().insert(REQUEST_ID_HEADER, val);
    }
    resp
}

#[derive(Clone, Debug)]
pub struct RequestId(pub String);

/// 统一安全响应头。HSTS 仅在 require_tls 时下发。
pub async fn security_headers(
    State(state): State<SharedState>,
    req: Request,
    next: Next,
) -> Response {
    let resp = next.run(req).await;
    let mut resp = resp;
    let headers = resp.headers_mut();

    headers.insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    headers.insert(
        header::REFERRER_POLICY,
        HeaderValue::from_static("no-referrer"),
    );
    headers.insert(
        "permissions-policy",
        HeaderValue::from_static("geolocation=(), microphone=(), camera=()"),
    );
    // CSP：骨架用严格策略；前端资源如需内联需改用 nonce/hash（P5 细化）。
    headers.insert(
        header::CONTENT_SECURITY_POLICY,
        HeaderValue::from_static(
            "default-src 'self'; frame-ancestors 'none'; base-uri 'self'; object-src 'none'",
        ),
    );
    if state.config.require_tls {
        headers.insert(
            header::STRICT_TRANSPORT_SECURITY,
            HeaderValue::from_static("max-age=63072000; includeSubDomains"),
        );
    }
    resp
}

/// Origin 校验 + CSRF（double-submit / token header）。仅对非安全方法强制。
/// SameSite=Strict cookie 作为纵深。
///
/// CSRF token 仅对**已认证会话**的变更请求强制（logout / 会话撤销 / 未来 settings 写）。
/// 登录是预认证引导（此刻尚无 session/token），豁免 token、仍受 rate-limit + 统一 401 +
/// Origin 校验保护——这是明确的登录 CSRF 例外，不是静默放宽特权边界。
pub async fn csrf_origin_guard(
    State(state): State<SharedState>,
    req: Request,
    next: Next,
) -> Response {
    let method = req.method().clone();
    let safe = matches!(method, Method::GET | Method::HEAD | Method::OPTIONS);
    if safe {
        return next.run(req).await;
    }

    // Origin 校验：配置了 allowed_origins 则必须命中。
    if !state.config.allowed_origins.is_empty() {
        let origin = req
            .headers()
            .get(header::ORIGIN)
            .and_then(|v| v.to_str().ok())
            .map(str::to_string);
        match origin {
            Some(ref o) if state.config.allowed_origins.iter().any(|a| a == o) => {}
            _ => return (StatusCode::FORBIDDEN, "bad origin").into_response(),
        }
    }

    // 仅当存在有效会话时才强制 CSRF token（double-submit，与 session 绑定的 token 常量时间比对）。
    if let Some(id) = crate::auth::guard::parse_session_cookie(req.headers()) {
        let id_hash = crate::auth::csrf::sha256_hex(&id);
        if let Some(session) = state.sessions.get(&id_hash) {
            let provided = req
                .headers()
                .get("x-csrf-token")
                .and_then(|v| v.to_str().ok())
                .unwrap_or("");
            if !crate::auth::csrf::constant_time_eq(provided, &session.csrf_token) {
                return (StatusCode::FORBIDDEN, "csrf mismatch").into_response();
            }
        }
    }

    next.run(req).await
}

/// 简易超时包裹示例（P1 仅示范；按路由细化）。
pub fn default_timeout() -> Duration {
    Duration::from_secs(30)
}
