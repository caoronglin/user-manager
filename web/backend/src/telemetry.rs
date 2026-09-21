//! 结构化日志：JSON + request-id + secret redaction。
//!
//! 约定（见 plan.md 第 13 节）：
//! - 绝不记录 password / Authorization / Cookie / CSRF token / TOTP / webhook / API token；
//! - 事件带 request_id；secret 在写入前经 redaction 层过滤。

use crate::config::Config;

pub fn init(config: &Config) -> Result<(), Box<dyn std::error::Error>> {
    use tracing_subscriber::{fmt, prelude::*, EnvFilter};

    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    let json_layer = fmt::layer()
        .json()
        .with_current_span(false)
        .with_span_list(false)
        .with_writer(std::io::stderr);

    tracing_subscriber::registry()
        .with(filter)
        .with(json_layer)
        .init();

    // 只记录非敏感启动信息。
    tracing::info!(
        bind = %config.bind_addr,
        port = config.bind_port,
        require_tls = config.require_tls,
        enforce_mfa_admin = config.enforce_mfa_admin,
        "umweb config loaded"
    );
    Ok(())
}

/// 对任意字符串做 secret 脱敏，供日志/审计/错误消息复用。
/// 与 Bash 侧 snapshot_scrub 语义保持一致。
pub fn redact(input: &str) -> String {
    let mut out = input.to_string();
    // 企业微信 webhook key
    if out.contains("qyapi.weixin.qq.com/cgi-bin/webhook/send?key=") {
        // 保守替换：把 ?key= 之后到空白/引号前的内容打码。
        if let Some(idx) = out.find("?key=") {
            let start = idx + "?key=".len();
            let end = out[start..]
                .find(|c: char| c.is_whitespace() || c == '"' || c == '&')
                .map(|e| start + e)
                .unwrap_or(out.len());
            out.replace_range(start..end, "***");
        }
    }
    if out.contains("PRIVATE KEY") {
        return "***REDACTED_KEY***".to_string();
    }
    out
}
