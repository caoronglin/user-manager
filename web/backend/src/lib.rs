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
pub mod web_event_delivery;

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

    // Ensure the independent outbox schema exists before accepting requests.
    // Existing inbox rows are never scanned or replayed by this worker.
    if let Err(error) = crate::web_event_delivery::initialize(&state.db) {
        tracing::warn!(error = %error, "native Web event delivery initialization failed");
    }
    let native_db = state.db.clone();
    let native_key = state.master_key;
    let native_outbound_gate = state.wecom_test_gate.clone();
    tokio::spawn(async move {
        crate::web_event_delivery::run(native_db, native_key, native_outbound_gate).await;
    });

    // The snapshot observer reads the validated manifest and persists only
    // freshness transitions in Web's database; it never writes snapshots.
    let snapshot_db = state.db.clone();
    let observer_snapshots =
        crate::store::snapshot::SnapshotStore::new(state.snapshots.dir().to_path_buf());
    tokio::spawn(async move {
        crate::store::snapshot_observer::run(snapshot_db, observer_snapshots).await;
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
