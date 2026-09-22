//! P2 只读系统 API：全部来自只读 Snapshot，附 freshness 元数据。
//!
//! 安全边界：每个 handler 用 `authenticate` + `Auth::require(capability)` 默认拒绝；
//! 数据一律来自 SnapshotStore.read（固定 kind 白名单，无任意文件读取、无 shell、无 SSH）。

use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::Json;
use serde_json::{json, Value};

use crate::auth::guard::{authenticate, Auth};
use crate::error::ApiError;
use crate::state::SharedState;
use crate::store::snapshot::SnapshotStore;

fn now_unix() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// 统一读取某 kind 快照，返回 (data, freshness_json)。
fn read_with_freshness(store: &SnapshotStore, kind: &str) -> (Option<Value>, Value) {
    let now = now_unix();
    let fresh = store.freshness(kind, now);
    let data = store.read(kind).map(|e| e.data);
    let freshness_json = serde_json::to_value(&fresh).unwrap_or(Value::Null);
    (data, freshness_json)
}

fn ok_read(data: Option<Value>, freshness: Value) -> Response {
    Json(json!({ "ok": true, "data": data, "meta": { "freshness": freshness } })).into_response()
}

fn filter_users(data: &Option<Value>, username: &str) -> Option<Value> {
    data.as_ref().and_then(|d| {
        d.get("users").and_then(|u| u.as_array()).map(|arr| {
            let one: Vec<Value> = arr
                .iter()
                .filter(|u| u.get("username").and_then(Value::as_str) == Some(username))
                .cloned()
                .collect();
            json!({ "users": one })
        })
    })
}

/// GET /api/users
async fn users(State(state): State<SharedState>, headers: HeaderMap) -> Result<Response, ApiError> {
    let auth: Auth = authenticate(&state, &headers)?;
    auth.require("users.read")?;
    let (data, fresh) = read_with_freshness(&state.snapshots, "users");
    Ok(ok_read(data, fresh))
}

/// GET /api/users/:username
async fn user_detail(
    State(state): State<SharedState>,
    headers: HeaderMap,
    Path(username): Path<String>,
) -> Result<Response, ApiError> {
    let auth = authenticate(&state, &headers)?;
    auth.require("users.read")?;
    let (data, fresh) = read_with_freshness(&state.snapshots, "users");
    Ok(ok_read(filter_users(&data, &username), fresh))
}

/// GET /api/users/:username/quota
async fn user_quota(
    State(state): State<SharedState>,
    headers: HeaderMap,
    Path(username): Path<String>,
) -> Result<Response, ApiError> {
    let auth = authenticate(&state, &headers)?;
    auth.require("quota.read")?;
    let (data, fresh) = read_with_freshness(&state.snapshots, "quota");
    Ok(ok_read(filter_users(&data, &username), fresh))
}

/// GET /api/users/:username/resources
async fn user_resources(
    State(state): State<SharedState>,
    headers: HeaderMap,
    Path(username): Path<String>,
) -> Result<Response, ApiError> {
    let auth = authenticate(&state, &headers)?;
    auth.require("resource.read")?;
    let (data, fresh) = read_with_freshness(&state.snapshots, "resources");
    Ok(ok_read(filter_users(&data, &username), fresh))
}

/// GET /api/resources/summary
async fn resources_summary(
    State(state): State<SharedState>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let auth = authenticate(&state, &headers)?;
    auth.require("resource.read")?;
    let (data, fresh) = read_with_freshness(&state.snapshots, "resources");
    Ok(ok_read(data, fresh))
}

/// GET /api/smb/status
async fn smb_status(
    State(state): State<SharedState>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let auth = authenticate(&state, &headers)?;
    auth.require("smb.read")?;
    let (data, fresh) = read_with_freshness(&state.snapshots, "smb");
    Ok(ok_read(data, fresh))
}
/// GET /api/smb/users
async fn smb_users(
    State(state): State<SharedState>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let auth = authenticate(&state, &headers)?;
    auth.require("smb.read")?;
    let (data, fresh) = read_with_freshness(&state.snapshots, "smb");
    Ok(ok_read(data, fresh))
}
/// GET /api/smb/users/:username
async fn smb_user_detail(
    State(state): State<SharedState>,
    headers: HeaderMap,
    Path(username): Path<String>,
) -> Result<Response, ApiError> {
    let auth = authenticate(&state, &headers)?;
    auth.require("smb.read")?;
    let (data, fresh) = read_with_freshness(&state.snapshots, "smb");
    let exists = data
        .as_ref()
        .and_then(|d| d.get("users").and_then(Value::as_array))
        .map(|a| a.iter().any(|v| v.as_str() == Some(username.as_str())))
        .unwrap_or(false);
    Ok(ok_read(
        Some(json!({ "username": username, "exists": exists })),
        fresh,
    ))
}
/// GET /api/smb/shares
async fn smb_shares(
    State(state): State<SharedState>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let auth = authenticate(&state, &headers)?;
    auth.require("smb.read")?;
    let (data, fresh) = read_with_freshness(&state.snapshots, "smb");
    Ok(ok_read(data, fresh))
}

/// GET /api/hosts
async fn hosts(State(state): State<SharedState>, headers: HeaderMap) -> Result<Response, ApiError> {
    let auth = authenticate(&state, &headers)?;
    auth.require("hosts.read")?;
    let (data, fresh) = read_with_freshness(&state.snapshots, "hosts");
    Ok(ok_read(data, fresh))
}
/// GET /api/hosts/:id
async fn host_detail(
    State(state): State<SharedState>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<Response, ApiError> {
    let auth = authenticate(&state, &headers)?;
    auth.require("hosts.read")?;
    let (data, fresh) = read_with_freshness(&state.snapshots, "hosts");
    let source = data
        .as_ref()
        .and_then(|d| d.get("source").and_then(Value::as_str).map(str::to_string));
    let matched = source.as_deref() == Some("local") && id == "local";
    Ok(ok_read(
        Some(json!({ "id": id, "matched": matched })),
        fresh,
    ))
}
/// GET /api/hosts/:id/gpu
async fn host_gpu(
    State(state): State<SharedState>,
    headers: HeaderMap,
    Path(_id): Path<String>,
) -> Result<Response, ApiError> {
    let auth = authenticate(&state, &headers)?;
    auth.require("gpu.read")?;
    let (data, fresh) = read_with_freshness(&state.snapshots, "gpu");
    Ok(ok_read(data, fresh))
}

/// GET /api/system-summary
async fn system_summary(
    State(state): State<SharedState>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let auth = authenticate(&state, &headers)?;
    auth.require("dashboard.read")?;
    let (data, fresh) = read_with_freshness(&state.snapshots, "system");
    Ok(ok_read(data, fresh))
}

pub fn router() -> axum::Router<SharedState> {
    axum::Router::new()
        .route("/api/users", get(users))
        .route("/api/users/:username", get(user_detail))
        .route("/api/users/:username/quota", get(user_quota))
        .route("/api/users/:username/resources", get(user_resources))
        .route("/api/resources/summary", get(resources_summary))
        .route("/api/smb/status", get(smb_status))
        .route("/api/smb/users", get(smb_users))
        .route("/api/smb/users/:username", get(smb_user_detail))
        .route("/api/smb/shares", get(smb_shares))
        .route("/api/hosts", get(hosts))
        .route("/api/hosts/:id", get(host_detail))
        .route("/api/hosts/:id/gpu", get(host_gpu))
        .route("/api/system-summary", get(system_summary))
}
