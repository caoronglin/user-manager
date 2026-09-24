//! umweb library crate：暴露模块与运行入口，便于集成测试复用路由/能力等。
pub mod crypto;
pub mod event_spool;

pub mod auth;
pub mod config;
pub mod error;
pub mod http;
pub mod state;
pub mod store;
pub mod telemetry;

use std::net::SocketAddr;

use tokio::net::TcpListener;

use crate::config::Config;
use crate::state::AppState;

/// 运行 Web 服务（非特权观察面）。绝不提权、绝不执行系统写操作。
pub async fn run() -> Result<(), Box<dyn std::error::Error>> {
    let config = Config::from_env()?;
    telemetry::init(&config)?;

    let state = AppState::init(config.clone()).await?;

    // The observer consumes only the fixed, root-owned spool and writes the
    // validated event into Web's own database. It never mutates the spool.
    let spool_db = state.db.clone();
    let spool_key = state.master_key;
    let outbound_gate = state.wecom_test_gate.clone();
    tokio::spawn(async move {
        event_spool::run(spool_db, spool_key, outbound_gate).await;
    });

    let app = http::build_router(state);

    let addr = SocketAddr::new(
        config
            .bind_addr
            .parse()
            .unwrap_or_else(|_| "0.0.0.0".parse().unwrap()),
        config.bind_port,
    );
    let listener = TcpListener::bind(addr).await?;
    tracing::info!(%addr, require_tls = config.require_tls, "umweb listening (non-privileged observation plane)");

    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(termination_signal())
    .await?;

    Ok(())
}

async fn termination_signal() {
    let _ = tokio::signal::ctrl_c().await;
    tracing::info!("termination signal received");
}
